-- ============================================================================
-- Inbox: input, decision, acknowledgement
-- ============================================================================
-- The inbox is meant to be driven to empty. Today an entry has a `status` of
-- pending/reviewed and nothing else: no record of who thought what, no notion of
-- a terminal decision, and no way for a notification to be cleared by one person
-- without vanishing for everyone.
--
-- Three distinct concepts, deliberately not collapsed into one column:
--
--   INPUT           a per-user suggestion -- "I'd interview them for Fellowship",
--                   "route to Launchpad", "reject". Advisory, many per entry,
--                   editable. Exactly like a note, but structured so agreement
--                   is visible at a glance.
--
--   DECISION        terminal and global. For an application: which funnel the
--                   person enters, or rejection. For a community application:
--                   yes or no. Recorded by any authenticated user once they
--                   judge consensus has been reached -- the database does not
--                   compute consensus, it records the call. Clears the entry
--                   from EVERYONE's inbox.
--
--   ACKNOWLEDGEMENT per-user dismissal, for notifications like intro requests
--                   that need attention but not adjudication. Clears the entry
--                   from YOUR inbox only.
--
-- One form feeds this: an applicant picks Fellowship, Launchpad, both, and
-- optionally the opt-in. Community applicants are a separate stream for people
-- who only want to stay in the loop.
-- ============================================================================

-- 1. Move the placement-only guard to where it belongs ------------------------
-- candidate_program_memberships pinned program_kind to 'placement' so a
-- candidate could not be admitted to Ateneo. Approving a community application
-- now creates exactly such a membership, so the guard has to go -- but the rule
-- it protected is really about PLACEMENTS, which is where it now lives.

ALTER TABLE public.candidate_program_memberships
  DROP CONSTRAINT IF EXISTS candidate_program_memberships_program_is_placement;

ALTER TABLE public.candidate_program_memberships
  DROP COLUMN IF EXISTS program_kind;

-- Re-add the plain foreign key the composite one was standing in for.
ALTER TABLE public.candidate_program_memberships
  ADD CONSTRAINT candidate_program_memberships_program_id_fkey
  FOREIGN KEY (program_id) REFERENCES public.programs(id) ON DELETE CASCADE;

-- A placement may still only be attributed to a placement program. Enforced by
-- trigger rather than the composite-FK idiom used before: that requires a
-- generated column in the key, and Postgres rejects ON DELETE SET NULL on such a
-- constraint -- it cannot null a generated value. Keeping SET NULL matters more
-- here than the elegance, since deleting a program should blank the attribution
-- rather than block the delete.
CREATE OR REPLACE FUNCTION public.assert_placement_program_is_placement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_kind text;
BEGIN
  IF NEW.program_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT kind INTO v_kind FROM public.programs WHERE id = NEW.program_id;

  IF v_kind IS DISTINCT FROM 'placement' THEN
    RAISE EXCEPTION
      'placements may only be attributed to a placement program; % is %',
      NEW.program_id, COALESCE(v_kind, 'missing');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_csp_program_is_placement ON public.candidate_startup_placements;
CREATE TRIGGER trg_csp_program_is_placement
  BEFORE INSERT OR UPDATE OF program_id ON public.candidate_startup_placements
  FOR EACH ROW EXECUTE FUNCTION public.assert_placement_program_is_placement();

-- 2. What the applicant actually asked for -----------------------------------
-- One form, several targets. Stored as program slugs rather than a join table:
-- this is a snapshot of what was requested at submission time and must not
-- change if a program is later renamed or retired.

ALTER TABLE public.inbox_events
  ADD COLUMN IF NOT EXISTS requested_programs text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS wants_optin boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.inbox_events.requested_programs IS
  'Program slugs the applicant selected on the form, e.g. {fellowship,launchpad}. A point-in-time snapshot, deliberately not a foreign key.';

-- Backfill from the event type, the only signal that existed before now.
UPDATE public.inbox_events
SET requested_programs = ARRAY['fellowship']
WHERE event_type = 'fellowship_application' AND requested_programs = '{}';

-- 3. The decision -------------------------------------------------------------

ALTER TABLE public.inbox_events
  ADD COLUMN IF NOT EXISTS decision text
    CHECK (decision IS NULL OR decision IN (
      'fellowship',        -- qualified into the Fellowship funnel
      'launchpad',         -- qualified into the Launchpad funnel
      'community_approved',-- community application accepted
      'rejected'
    )),
  ADD COLUMN IF NOT EXISTS decided_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS decided_at timestamptz,
  -- Which funnel the person was routed into, when the decision was a funnel.
  ADD COLUMN IF NOT EXISTS decision_project_id uuid
    REFERENCES public.projects(project_id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS decision_note text;

-- A decision is all-or-nothing: outcome and timestamp travel together.
ALTER TABLE public.inbox_events
  ADD CONSTRAINT inbox_events_decision_complete
  CHECK (
    (decision IS NULL AND decided_at IS NULL) OR
    (decision IS NOT NULL AND decided_at IS NOT NULL)
  );

CREATE INDEX IF NOT EXISTS idx_inbox_events_decision ON public.inbox_events (decision);
CREATE INDEX IF NOT EXISTS idx_inbox_events_undecided
  ON public.inbox_events (created_at DESC) WHERE decision IS NULL;

-- 4. Input: per-user, advisory ------------------------------------------------

CREATE TABLE IF NOT EXISTS public.inbox_event_inputs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id   uuid NOT NULL REFERENCES public.inbox_events(event_id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  suggestion text NOT NULL CHECK (suggestion IN (
    'fellowship', 'launchpad', 'community_approve', 'reject', 'unsure'
  )),
  note       text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- One standing opinion per person per entry, revisable. A changed mind should
  -- replace the previous view rather than accumulate contradictory rows.
  CONSTRAINT inbox_event_inputs_one_per_user UNIQUE (event_id, user_id)
);

COMMENT ON TABLE public.inbox_event_inputs IS
  'Advisory per-user suggestions on an inbox entry. Informs the decision; does not constitute it.';

CREATE INDEX IF NOT EXISTS idx_inbox_inputs_event ON public.inbox_event_inputs (event_id);
CREATE INDEX IF NOT EXISTS idx_inbox_inputs_user  ON public.inbox_event_inputs (user_id);

DROP TRIGGER IF EXISTS trg_inbox_inputs_touch ON public.inbox_event_inputs;
CREATE TRIGGER trg_inbox_inputs_touch
  BEFORE UPDATE ON public.inbox_event_inputs
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 5. Acknowledgement: per-user dismissal --------------------------------------

CREATE TABLE IF NOT EXISTS public.inbox_event_acknowledgements (
  event_id        uuid NOT NULL REFERENCES public.inbox_events(event_id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  acknowledged_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, user_id)
);

COMMENT ON TABLE public.inbox_event_acknowledgements IS
  'Per-user dismissal of a notification-style entry. Clears it from that user''s inbox only, never anyone else''s.';

-- 6. Recording a decision -----------------------------------------------------
-- Routing a person into a funnel, recording their program membership and
-- closing the entry must not half-happen, so they are one function rather than
-- three round trips from the app.

CREATE OR REPLACE FUNCTION public.decide_inbox_event(
  p_event_id   uuid,
  p_decision   text,
  p_project_id uuid DEFAULT NULL,
  p_note       text DEFAULT NULL
)
RETURNS public.inbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_event      public.inbox_events;
  v_actor      uuid;
  v_program_id uuid;
  v_bucket_id  uuid;
BEGIN
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  SELECT * INTO v_event FROM public.inbox_events WHERE event_id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inbox event % not found', p_event_id;
  END IF;
  IF v_event.decision IS NOT NULL THEN
    RAISE EXCEPTION 'inbox event % already decided as %', p_event_id, v_event.decision;
  END IF;

  -- Qualifying into a funnel needs somewhere to put the person.
  IF p_decision IN ('fellowship', 'launchpad') THEN
    IF p_project_id IS NULL THEN
      RAISE EXCEPTION 'a funnel must be supplied when qualifying someone';
    END IF;
    IF v_event.candidate_id IS NULL THEN
      RAISE EXCEPTION 'inbox event % has no candidate to route', p_event_id;
    END IF;

    -- Land them in the funnel's first column.
    SELECT bucket_id INTO v_bucket_id
    FROM public.project_buckets
    WHERE project_id = p_project_id
    ORDER BY order_index
    LIMIT 1;

    IF v_bucket_id IS NULL THEN
      RAISE EXCEPTION 'funnel % has no buckets to place the candidate in', p_project_id;
    END IF;

    -- The transition trigger records this arrival automatically.
    INSERT INTO public.candidate_project_buckets (candidate_id, project_id, bucket_id)
    VALUES (v_event.candidate_id, p_project_id, v_bucket_id)
    ON CONFLICT (candidate_id, project_id) DO NOTHING;

    SELECT id INTO v_program_id FROM public.programs WHERE slug = p_decision;
  END IF;

  IF p_decision = 'community_approved' THEN
    SELECT id INTO v_program_id
    FROM public.programs WHERE kind = 'community' ORDER BY name LIMIT 1;
  END IF;

  -- Record membership of whichever program the decision implies. Now possible
  -- for community programs too, since the placement-only guard moved.
  IF v_program_id IS NOT NULL AND v_event.candidate_id IS NOT NULL THEN
    INSERT INTO public.candidate_program_memberships (candidate_id, program_id, status)
    VALUES (v_event.candidate_id, v_program_id, 'active')
    ON CONFLICT (candidate_id, program_id) DO NOTHING;
  END IF;

  UPDATE public.inbox_events
  SET decision            = p_decision,
      decided_by          = v_actor,
      decided_at          = now(),
      decision_project_id = p_project_id,
      decision_note       = p_note,
      status              = 'reviewed',
      reviewed_at         = COALESCE(reviewed_at, now()),
      reviewed_by         = COALESCE(reviewed_by, v_actor)
  WHERE event_id = p_event_id
  RETURNING * INTO v_event;

  RETURN v_event;
END;
$$;

COMMENT ON FUNCTION public.decide_inbox_event(uuid, text, uuid, text) IS
  'Records a terminal decision: routes the candidate into a funnel, records program membership, and closes the entry. Atomic.';

-- 7. What is still waiting on me ----------------------------------------------
-- Applications clear globally on a decision; notifications clear per-user on
-- acknowledgement. This view encodes that difference so callers do not have to.

CREATE OR REPLACE VIEW public.inbox_pending_for_user AS
SELECT e.*,
       u.id AS for_user_id,
       CASE
         WHEN e.event_type = 'startup_intro_request' THEN 'notification'
         WHEN e.event_type = 'community_application'  THEN 'community'
         WHEN e.event_type = 'founder_forum_application' THEN 'founder_forum'
         ELSE 'application'
       END AS stream,
       (SELECT count(*) FROM public.inbox_event_inputs i WHERE i.event_id = e.event_id)
         AS input_count,
       (SELECT i.suggestion FROM public.inbox_event_inputs i
         WHERE i.event_id = e.event_id AND i.user_id = u.id) AS my_suggestion
FROM public.inbox_events e
CROSS JOIN auth.users u
WHERE
  CASE
    WHEN e.event_type = 'startup_intro_request' THEN
      NOT EXISTS (
        SELECT 1 FROM public.inbox_event_acknowledgements a
        WHERE a.event_id = e.event_id AND a.user_id = u.id
      )
    ELSE e.decision IS NULL
  END;

ALTER VIEW public.inbox_pending_for_user SET (security_invoker = off);

COMMENT ON VIEW public.inbox_pending_for_user IS
  'Entries still requiring attention, per user. Applications clear globally when decided; notifications clear individually when acknowledged.';

-- 8. RLS and grants -----------------------------------------------------------

ALTER TABLE public.inbox_event_inputs           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inbox_event_acknowledgements ENABLE ROW LEVEL SECURITY;

-- Everyone sees everyone's input -- visible agreement is the point.
CREATE POLICY "authenticated_read_inputs" ON public.inbox_event_inputs
  FOR SELECT TO authenticated USING (true);

-- But you may only write your own.
CREATE POLICY "authenticated_write_own_input" ON public.inbox_event_inputs
  FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE POLICY "authenticated_own_acknowledgements" ON public.inbox_event_acknowledgements
  FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.inbox_event_inputs           TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inbox_event_acknowledgements TO authenticated, service_role;
GRANT SELECT ON public.inbox_pending_for_user TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.decide_inbox_event(uuid, text, uuid, text) TO authenticated, service_role;
