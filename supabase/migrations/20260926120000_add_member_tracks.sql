-- ============================================================================
-- MEMBER TRACKS
--
-- Replaces funnels/buckets/program memberships as the way Exponential tracks
-- people. A member can be in several tracks at once:
--
--   community   in or out, no stages
--   launchpad   invited > opted_in > interview_invited > interviewed > startup_evaluation > accepted | rejected
--   fellowship  invited > interview_invited > interviewed > startup_evaluation > accepted | rejected
--
-- interview_invited may repeat within a spell (each re-invite is logged).
--
-- Archived is a flag on the candidate, exclusive with every track: archiving
-- closes all open spells, and no spell can open while archived. It is undone by
-- unarchive_candidate (manual review or a new application).
--
-- Model:
--   candidate_track_spells  one row per time someone is considered for a track.
--                           Rejected from Fellowship closes the spell; being
--                           reconsidered opens a new one. At most one open spell
--                           per (candidate, track).
--   candidate_track_events  immutable log of stages. Every event belongs to a
--                           spell, so "which stage was this activity at, at time
--                           T" is a plain query on occurred_at.
--   candidate_archive_log   immutable log of archive / unarchive.
--
-- Writes go through apply_member_actions / archive_candidate /
-- unarchive_candidate only. One UI action (e.g. "invite to community +
-- launchpad") is one call sharing a batch_id, which the email activity that
-- follows records in its metadata.
--
-- Legacy tables (projects, project_buckets, candidate_project_buckets,
-- candidate_program_memberships) are untouched here and retired later.
-- ============================================================================

BEGIN;
-- ----------------------------------------------------------------------------
-- 0. assert_staff()
--
-- Same definition as 20260908170000_guard_security_definer_rpcs.sql, which
-- has not been applied to production yet. Defined here too so the RPCs below
-- don't depend on it; CREATE OR REPLACE keeps the two compatible.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_staff()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := NULLIF(current_setting('request.jwt.claims', true), '')::json->>'role';
BEGIN
  -- No JWT: direct SQL session (postgres, migrations, MCP). Allowed.
  IF v_role IS NULL THEN RETURN; END IF;
  -- Server-side callers with the secret key. Allowed.
  IF v_role = 'service_role' THEN RETURN; END IF;
  -- Signed-in users must be on the staff list.
  IF v_role = 'authenticated' AND public.is_staff() THEN RETURN; END IF;

  RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION public.assert_staff() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_staff() TO authenticated, service_role;
-- ----------------------------------------------------------------------------
-- 1. Archive flag
-- ----------------------------------------------------------------------------

ALTER TABLE public.candidates
  ADD COLUMN IF NOT EXISTS archived_at     timestamptz,
  ADD COLUMN IF NOT EXISTS archived_reason text;
COMMENT ON COLUMN public.candidates.archived_at IS
  'Set while the candidate is not considered for Exponential. Exclusive with open track spells. Maintained by archive_candidate / unarchive_candidate.';
CREATE INDEX IF NOT EXISTS idx_candidates_archived
  ON public.candidates (archived_at) WHERE archived_at IS NOT NULL;
CREATE TABLE IF NOT EXISTS public.candidate_archive_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,
  action       text NOT NULL CHECK (action IN ('archived', 'unarchived')),
  reason       text,
  actor_id     uuid REFERENCES auth.users(id),
  occurred_at  timestamptz NOT NULL DEFAULT now(),
  batch_id     uuid NOT NULL DEFAULT gen_random_uuid(),
  source       text NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'backfill'))
);
CREATE INDEX IF NOT EXISTS idx_cal_candidate_time
  ON public.candidate_archive_log (candidate_id, occurred_at);
-- ----------------------------------------------------------------------------
-- 2. Spells and events
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.candidate_track_spells (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,
  track        text NOT NULL CHECK (track IN ('community', 'launchpad', 'fellowship')),
  opened_at    timestamptz NOT NULL DEFAULT now(),
  closed_at    timestamptz,
  close_reason text CHECK (close_reason IN ('rejected', 'left', 'archived', 'removed')),
  source       text NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'backfill')),
  CONSTRAINT cts_closed_after_opened CHECK (closed_at IS NULL OR closed_at >= opened_at),
  CONSTRAINT cts_close_complete CHECK ((closed_at IS NULL) = (close_reason IS NULL))
);
COMMENT ON TABLE public.candidate_track_spells IS
  'One row per period a candidate is in a track. Closed spells are history; a new consideration opens a new spell.';
CREATE UNIQUE INDEX IF NOT EXISTS cts_one_open_per_track
  ON public.candidate_track_spells (candidate_id, track) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_cts_track_open
  ON public.candidate_track_spells (track) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_cts_candidate
  ON public.candidate_track_spells (candidate_id);
CREATE TABLE IF NOT EXISTS public.candidate_track_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Tiebreak for events with the same occurred_at (e.g. backfilled rows).
  seq          bigint GENERATED ALWAYS AS IDENTITY,
  spell_id     uuid NOT NULL REFERENCES public.candidate_track_spells(id) ON DELETE CASCADE,
  candidate_id uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,
  track        text NOT NULL,
  stage        text NOT NULL,
  -- clock_timestamp, not now(): events written in one transaction must still order.
  occurred_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_id     uuid REFERENCES auth.users(id),
  batch_id     uuid NOT NULL DEFAULT gen_random_uuid(),
  note         text,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  source       text NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'backfill')),
  CONSTRAINT cte_stage_valid_for_track CHECK (
    (track = 'community'  AND stage IN ('joined', 'left')) OR
    (track = 'launchpad'  AND stage IN ('invited', 'opted_in', 'interview_invited', 'interviewed',
                                        'startup_evaluation', 'accepted', 'rejected')) OR
    (track = 'fellowship' AND stage IN ('invited', 'interview_invited', 'interviewed',
                                        'startup_evaluation', 'accepted', 'rejected'))
  )
);
COMMENT ON TABLE public.candidate_track_events IS
  'Immutable stage log. The current stage of a spell is its latest event. batch_id groups the events of one UI action and is copied into the email_sent activity it triggers.';
CREATE INDEX IF NOT EXISTS idx_cte_spell_time     ON public.candidate_track_events (spell_id, occurred_at, seq);
CREATE INDEX IF NOT EXISTS idx_cte_candidate_time ON public.candidate_track_events (candidate_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_cte_batch          ON public.candidate_track_events (batch_id);
-- Spells may not open for an archived candidate.
CREATE OR REPLACE FUNCTION public.assert_candidate_not_archived()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.closed_at IS NULL AND EXISTS (
    SELECT 1 FROM public.candidates
    WHERE candidate_id = NEW.candidate_id AND archived_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'candidate % is archived; unarchive before adding them to %',
      NEW.candidate_id, NEW.track;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_cts_not_archived ON public.candidate_track_spells;
CREATE TRIGGER trg_cts_not_archived
  BEFORE INSERT ON public.candidate_track_spells
  FOR EACH ROW EXECUTE FUNCTION public.assert_candidate_not_archived();
-- ----------------------------------------------------------------------------
-- 3. apply_member_actions
--
-- p_actions: [{"track": "launchpad", "stage": "invited"}, ...]
--   community  stage 'joined' opens a spell (no-op if already in), 'left' closes it.
--   launchpad / fellowship  opens a spell if none is open, records the stage,
--     and 'rejected' closes the spell. 'invited' also adds the candidate to
--     the community.
-- Returns the events written. All share one batch_id.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_member_actions(
  p_candidate_id uuid,
  p_actions      jsonb,
  p_note         text DEFAULT NULL,
  p_metadata     jsonb DEFAULT '{}'::jsonb,
  p_batch_id     uuid DEFAULT NULL
)
RETURNS SETOF public.candidate_track_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor  uuid;
  v_batch  uuid := COALESCE(p_batch_id, gen_random_uuid());
  v_action jsonb;
  v_track  text;
  v_stage  text;
  v_spell  uuid;
  v_event  public.candidate_track_events;
BEGIN
  PERFORM public.assert_staff();
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  IF jsonb_typeof(p_actions) <> 'array' OR jsonb_array_length(p_actions) = 0 THEN
    RAISE EXCEPTION 'p_actions must be a non-empty array';
  END IF;

  -- Serialize concurrent actions on the same candidate.
  PERFORM 1 FROM public.candidates WHERE candidate_id = p_candidate_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'candidate % not found', p_candidate_id;
  END IF;

  -- Inviting to a program implies community membership.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_actions) a
    WHERE a->>'track' IN ('launchpad', 'fellowship') AND a->>'stage' = 'invited'
  ) AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_actions) a WHERE a->>'track' = 'community'
  ) THEN
    p_actions := jsonb_build_array(jsonb_build_object('track', 'community', 'stage', 'joined'))
                 || p_actions;
  END IF;

  FOR v_action IN SELECT * FROM jsonb_array_elements(p_actions) LOOP
    v_track := v_action->>'track';
    v_stage := v_action->>'stage';

    SELECT id INTO v_spell
    FROM public.candidate_track_spells
    WHERE candidate_id = p_candidate_id AND track = v_track AND closed_at IS NULL;

    IF v_track = 'community' AND v_stage = 'joined' AND v_spell IS NOT NULL THEN
      CONTINUE;  -- already a member
    END IF;

    IF v_spell IS NULL THEN
      IF v_stage IN ('left', 'rejected') THEN
        RAISE EXCEPTION 'candidate % is not in %; cannot mark %', p_candidate_id, v_track, v_stage;
      END IF;
      INSERT INTO public.candidate_track_spells (candidate_id, track)
      VALUES (p_candidate_id, v_track)
      RETURNING id INTO v_spell;
    END IF;

    INSERT INTO public.candidate_track_events
      (spell_id, candidate_id, track, stage, actor_id, batch_id, note, metadata)
    VALUES
      (v_spell, p_candidate_id, v_track, v_stage, v_actor, v_batch, p_note, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING * INTO v_event;
    RETURN NEXT v_event;

    IF v_stage IN ('rejected', 'left') THEN
      UPDATE public.candidate_track_spells
      SET closed_at = v_event.occurred_at,
          close_reason = CASE v_stage WHEN 'rejected' THEN 'rejected' ELSE 'left' END
      WHERE id = v_spell;
    END IF;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_member_actions(uuid, jsonb, text, jsonb, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.apply_member_actions(uuid, jsonb, text, jsonb, uuid) TO authenticated, service_role;
-- ----------------------------------------------------------------------------
-- 4. archive / unarchive
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.archive_candidate(
  p_candidate_id uuid,
  p_reason       text DEFAULT NULL,
  p_batch_id     uuid DEFAULT NULL
)
RETURNS public.candidates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor uuid;
  v_now   timestamptz := now();
  v_row   public.candidates;
BEGIN
  PERFORM public.assert_staff();
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  SELECT * INTO v_row FROM public.candidates WHERE candidate_id = p_candidate_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'candidate % not found', p_candidate_id;
  END IF;
  IF v_row.archived_at IS NOT NULL THEN
    RETURN v_row;
  END IF;

  UPDATE public.candidate_track_spells
  SET closed_at = v_now, close_reason = 'archived'
  WHERE candidate_id = p_candidate_id AND closed_at IS NULL;

  INSERT INTO public.candidate_archive_log (candidate_id, action, reason, actor_id, occurred_at, batch_id)
  VALUES (p_candidate_id, 'archived', p_reason, v_actor, v_now, COALESCE(p_batch_id, gen_random_uuid()));

  UPDATE public.candidates
  SET archived_at = v_now, archived_reason = p_reason
  WHERE candidate_id = p_candidate_id
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$;
CREATE OR REPLACE FUNCTION public.unarchive_candidate(
  p_candidate_id uuid,
  p_reason       text DEFAULT NULL
)
RETURNS public.candidates
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor uuid;
  v_row   public.candidates;
BEGIN
  PERFORM public.assert_staff();
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  SELECT * INTO v_row FROM public.candidates WHERE candidate_id = p_candidate_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'candidate % not found', p_candidate_id;
  END IF;
  IF v_row.archived_at IS NULL THEN
    RETURN v_row;
  END IF;

  INSERT INTO public.candidate_archive_log (candidate_id, action, reason, actor_id)
  VALUES (p_candidate_id, 'unarchived', p_reason, v_actor);

  UPDATE public.candidates
  SET archived_at = NULL, archived_reason = NULL
  WHERE candidate_id = p_candidate_id
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$;
REVOKE ALL ON FUNCTION public.archive_candidate(uuid, text, uuid) FROM public, anon;
REVOKE ALL ON FUNCTION public.unarchive_candidate(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.archive_candidate(uuid, text, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unarchive_candidate(uuid, text) TO authenticated, service_role;
-- ----------------------------------------------------------------------------
-- 5. Read models
-- ----------------------------------------------------------------------------

-- Open spells with their current stage and who they belong to. Feeds the
-- community list and the program kanbans.
-- interview_count: interview invites in this spell. The Fellowship invite is
-- itself the first interview invite; every interview_invited adds one.
CREATE OR REPLACE VIEW public.candidate_open_tracks AS
SELECT s.id AS spell_id,
       s.candidate_id,
       s.track,
       s.opened_at,
       e.stage,
       e.occurred_at AS stage_at,
       (SELECT count(*) FROM public.candidate_track_events i
        WHERE i.spell_id = s.id
          AND (i.stage = 'interview_invited'
               OR (s.track = 'fellowship' AND i.stage = 'invited')))::int AS interview_count,
       c.first_name,
       c.last_name,
       c.email
FROM public.candidate_track_spells s
JOIN public.candidates c ON c.candidate_id = s.candidate_id
LEFT JOIN LATERAL (
  SELECT stage, occurred_at FROM public.candidate_track_events
  WHERE spell_id = s.id
  ORDER BY occurred_at DESC, seq DESC LIMIT 1
) e ON true
WHERE s.closed_at IS NULL;
ALTER VIEW public.candidate_open_tracks SET (security_invoker = on);
-- Current state: one row per candidate with any spell or an archive flag.
CREATE OR REPLACE VIEW public.candidate_member_state AS
SELECT c.candidate_id,
       c.first_name,
       c.last_name,
       c.email,
       c.archived_at,
       bool_or(o.track = 'community')                               AS in_community,
       max(o.opened_at) FILTER (WHERE o.track = 'community')        AS community_since,
       max(o.spell_id::text) FILTER (WHERE o.track = 'launchpad')::uuid  AS launchpad_spell_id,
       max(o.stage)    FILTER (WHERE o.track = 'launchpad')         AS launchpad_stage,
       max(o.stage_at) FILTER (WHERE o.track = 'launchpad')         AS launchpad_stage_at,
       max(o.spell_id::text) FILTER (WHERE o.track = 'fellowship')::uuid AS fellowship_spell_id,
       max(o.stage)    FILTER (WHERE o.track = 'fellowship')        AS fellowship_stage,
       max(o.stage_at) FILTER (WHERE o.track = 'fellowship')        AS fellowship_stage_at
FROM public.candidates c
LEFT JOIN public.candidate_open_tracks o ON o.candidate_id = c.candidate_id
WHERE c.archived_at IS NOT NULL OR o.candidate_id IS NOT NULL
GROUP BY c.candidate_id, c.first_name, c.last_name, c.email, c.archived_at;
ALTER VIEW public.candidate_member_state SET (security_invoker = on);
-- State as of any moment: which spells were open and at which stage.
CREATE OR REPLACE FUNCTION public.candidate_tracks_at(p_at timestamptz)
RETURNS TABLE (candidate_id uuid, track text, spell_id uuid, stage text, stage_at timestamptz)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT s.candidate_id, s.track, s.id, e.stage, e.occurred_at
  FROM public.candidate_track_spells s
  LEFT JOIN LATERAL (
    SELECT stage, occurred_at FROM public.candidate_track_events
    WHERE spell_id = s.id AND occurred_at <= p_at
    ORDER BY occurred_at DESC, seq DESC LIMIT 1
  ) e ON true
  WHERE s.opened_at <= p_at
    AND (s.closed_at IS NULL OR s.closed_at > p_at);
$$;
REVOKE ALL ON FUNCTION public.candidate_tracks_at(timestamptz) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.candidate_tracks_at(timestamptz) TO authenticated, service_role;
-- ----------------------------------------------------------------------------
-- 6. Email templates per action
--
-- Each inbox / candidate action opens the template with its action_key for
-- preview and editing before sending. launchpad_opted_in is the only one sent
-- without preview (the candidate triggers it by opting in).
-- ----------------------------------------------------------------------------

ALTER TABLE public.email_templates
  ADD COLUMN IF NOT EXISTS action_key text;
ALTER TABLE public.email_templates
  DROP CONSTRAINT IF EXISTS email_templates_action_key_check;
ALTER TABLE public.email_templates
  ADD CONSTRAINT email_templates_action_key_check CHECK (action_key IS NULL OR action_key IN (
    'archive_generic',              -- archive: generic rejection
    'archive_too_old',              -- archive: too senior / too old for the program
    'archive_no_spanish_ties',      -- archive: no ties to Spain
    'community_invite',
    'launchpad_invite',             -- launchpad invite with opt-in link
    'launchpad_invite_interview',   -- launchpad invite + interview scheduling
    'launchpad_opted_in',           -- instructions, sent automatically on opt-in
    'fellowship_invite',            -- fellowship invite + interview scheduling
    'interview_invite'              -- repeat interview invite from the candidate view
  ));
CREATE UNIQUE INDEX IF NOT EXISTS email_templates_action_key_key
  ON public.email_templates (action_key) WHERE action_key IS NOT NULL;
-- ----------------------------------------------------------------------------
-- 7. RLS: staff read, writes only through the RPCs above
-- ----------------------------------------------------------------------------

ALTER TABLE public.candidate_track_spells ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.candidate_track_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.candidate_archive_log  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.candidate_track_spells, public.candidate_track_events,
              public.candidate_archive_log FROM anon, authenticated;
GRANT SELECT ON public.candidate_track_spells, public.candidate_track_events,
                public.candidate_archive_log TO authenticated;
GRANT ALL ON public.candidate_track_spells, public.candidate_track_events,
             public.candidate_archive_log TO service_role;
REVOKE ALL ON public.candidate_member_state, public.candidate_open_tracks FROM anon;
GRANT SELECT ON public.candidate_member_state, public.candidate_open_tracks TO authenticated, service_role;
DROP POLICY IF EXISTS staff_read ON public.candidate_track_spells;
CREATE POLICY staff_read ON public.candidate_track_spells
  FOR SELECT TO authenticated USING (public.is_staff());
DROP POLICY IF EXISTS staff_read ON public.candidate_track_events;
CREATE POLICY staff_read ON public.candidate_track_events
  FOR SELECT TO authenticated USING (public.is_staff());
DROP POLICY IF EXISTS staff_read ON public.candidate_archive_log;
CREATE POLICY staff_read ON public.candidate_archive_log
  FOR SELECT TO authenticated USING (public.is_staff());
COMMIT;
