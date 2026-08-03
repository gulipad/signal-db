-- ============================================================================
-- Intros as a first-class entity
-- ============================================================================
-- A placement is the END of the funnel. The step before it is the intro: we put
-- a candidate in front of a startup, and some fraction of those become hires.
-- Today an intro is only a row in `candidate_activities` with a jsonb blob:
--
--   activityMetadata.startup_id   = startup_id        -- jsonb, NOT a foreign key
--   activityMetadata.startup_name = startup.name      -- denormalized
--   activityMetadata.program_names = programNames     -- denormalized text!
--
-- Three consequences:
--
--   1. No referential integrity. Delete a startup and the intro keeps a dangling
--      uuid inside jsonb. Joining needs (metadata->>'startup_id')::uuid.
--   2. Program attribution is already being captured -- but as a NAME STRING,
--      which cannot be joined, counted reliably, or renamed safely.
--   3. No status. An intro is fire-and-forget: there is no record of whether the
--      startup replied, interviewed, made an offer, or passed. So the single most
--      important number in a placement program -- intro -> placement conversion --
--      cannot be computed at all.
--
-- This models the intro properly while leaving the activity log intact: the app
-- keeps writing candidate_activities exactly as it does today, and a trigger
-- projects those writes into this table. Nothing has to ship in lockstep.
-- ============================================================================

-- 1. Fix the CHECK constraint that silently drops independent intros ---------
-- src/app/api/candidates/[candidateId]/intro-email/route.ts writes
-- 'candidate_independent_intro' when there is no startup_id, but that value is
-- absent from the allowed list, so the INSERT violates the constraint. It is
-- wrapped in a try/catch, so the failure is swallowed and the activity is never
-- recorded -- independent intros are missing from the timeline and undercounted
-- in analytics.

ALTER TABLE public.candidate_activities
  DROP CONSTRAINT IF EXISTS candidate_activities_activity_type_check;

ALTER TABLE public.candidate_activities
  ADD CONSTRAINT candidate_activities_activity_type_check
  CHECK (activity_type IN (
    'bucket_assignment',
    'availability_change',
    'source_update',
    'email_sent',
    'candidate_startup_intro',
    'candidate_independent_intro'  -- was missing; writes were failing silently
  ));

-- 2. The intro table --------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.candidate_startup_intros (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,

  -- A real foreign key rather than a uuid buried in jsonb. Nullable because an
  -- "independent" intro goes to a requester who is not a startup on file.
  startup_id   uuid REFERENCES public.startups(id) ON DELETE SET NULL,

  -- Program attribution, pinned at creation. This is the program that admitted
  -- the CANDIDATE -- the one that supplied the talent -- not the startup's.
  program_id   uuid REFERENCES public.programs(id) ON DELETE SET NULL,
  cohort_id    uuid REFERENCES public.cohorts(id)  ON DELETE SET NULL,

  -- Which funnel produced this intro, so sourcing effort can be attributed.
  project_id   uuid REFERENCES public.projects(project_id) ON DELETE SET NULL,

  intro_type   text NOT NULL DEFAULT 'startup'
               CHECK (intro_type IN ('startup', 'independent')),

  -- The pipeline this whole PR exists to make measurable.
  status       text NOT NULL DEFAULT 'sent'
               CHECK (status IN (
                 'sent',         -- intro email went out
                 'responded',    -- the startup replied
                 'interviewing', -- conversations underway
                 'offer',        -- an offer was made
                 'placed',       -- became a placement
                 'declined',     -- the startup passed
                 'withdrawn',    -- the candidate withdrew
                 'no_response'   -- went cold
               )),

  sent_at      timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  closed_at    timestamptz,

  -- Denormalized contact snapshot: who it actually went to at the time.
  contact_id   uuid REFERENCES public.contacts(id) ON DELETE SET NULL,
  to_emails    text[] NOT NULL DEFAULT '{}',
  cc_emails    text[] NOT NULL DEFAULT '{}',
  subject      text,

  -- Provenance back to the activity row this was projected from, so the
  -- backfill is idempotent and the timeline stays the source of narrative.
  activity_id  uuid UNIQUE,
  email_id     text,
  notes        text,

  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT intros_startup_type_consistent CHECK (
    (intro_type = 'startup'     AND startup_id IS NOT NULL) OR
    (intro_type = 'independent' AND startup_id IS NULL)
  ),
  CONSTRAINT intros_responded_after_sent CHECK (responded_at IS NULL OR responded_at >= sent_at),
  CONSTRAINT intros_closed_after_sent    CHECK (closed_at    IS NULL OR closed_at    >= sent_at)
);

COMMENT ON TABLE public.candidate_startup_intros IS
  'An introduction of a candidate to a startup. The step between funnel and placement. Projected from candidate_activities by trigger; program_id is the candidate''s admitting program, pinned at creation.';

CREATE INDEX IF NOT EXISTS idx_intros_candidate ON public.candidate_startup_intros (candidate_id);
CREATE INDEX IF NOT EXISTS idx_intros_startup   ON public.candidate_startup_intros (startup_id);
CREATE INDEX IF NOT EXISTS idx_intros_program   ON public.candidate_startup_intros (program_id);
CREATE INDEX IF NOT EXISTS idx_intros_cohort    ON public.candidate_startup_intros (cohort_id);
CREATE INDEX IF NOT EXISTS idx_intros_status    ON public.candidate_startup_intros (status);
CREATE INDEX IF NOT EXISTS idx_intros_sent_at   ON public.candidate_startup_intros (sent_at);

DROP TRIGGER IF EXISTS trg_intros_touch_updated_at ON public.candidate_startup_intros;
CREATE TRIGGER trg_intros_touch_updated_at
  BEFORE UPDATE ON public.candidate_startup_intros
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 3. Resolve the admitting program ------------------------------------------
-- Shared with the placement migration. Returns the candidate's placement-program
-- membership, preferring an active one, then the most recent.

CREATE OR REPLACE FUNCTION public.candidate_admitting_membership(p_candidate_id uuid)
RETURNS TABLE (program_id uuid, cohort_id uuid)
LANGUAGE sql
STABLE
AS $$
  SELECT m.program_id, m.cohort_id
  FROM public.candidate_program_memberships m
  WHERE m.candidate_id = p_candidate_id
  ORDER BY (m.status = 'active') DESC, m.joined_at DESC
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.candidate_admitting_membership(uuid) IS
  'The program/cohort a candidate was admitted to, preferring an active membership then the most recent. Used to pin attribution on intros and placements at creation time.';

-- 4. Project activity writes into the intro table ---------------------------
-- The app keeps writing candidate_activities unchanged; this mirrors those
-- writes so the new table is populated without any application release.

CREATE OR REPLACE FUNCTION public.project_intro_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_startup_id uuid;
  v_contact_id uuid;
  v_program_id uuid;
  v_cohort_id  uuid;
  v_type       text;
BEGIN
  IF NEW.activity_type NOT IN ('candidate_startup_intro', 'candidate_independent_intro') THEN
    RETURN NEW;
  END IF;

  -- jsonb values may be absent or malformed; never let that break the write.
  BEGIN
    v_startup_id := NULLIF(NEW.metadata->>'startup_id', '')::uuid;
  EXCEPTION WHEN OTHERS THEN v_startup_id := NULL;
  END;
  BEGIN
    v_contact_id := NULLIF(NEW.metadata->>'primary_contact_id', '')::uuid;
  EXCEPTION WHEN OTHERS THEN v_contact_id := NULL;
  END;

  -- Only reference a startup that actually exists, so the FK cannot fail.
  IF v_startup_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.startups s WHERE s.id = v_startup_id) THEN
    v_startup_id := NULL;
  END IF;
  IF v_contact_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.contacts c WHERE c.id = v_contact_id) THEN
    v_contact_id := NULL;
  END IF;

  v_type := CASE WHEN v_startup_id IS NOT NULL THEN 'startup' ELSE 'independent' END;

  SELECT m.program_id, m.cohort_id INTO v_program_id, v_cohort_id
  FROM public.candidate_admitting_membership(NEW.candidate_id) m;

  INSERT INTO public.candidate_startup_intros (
    candidate_id, startup_id, program_id, cohort_id, project_id,
    intro_type, sent_at, contact_id, subject, activity_id, email_id,
    to_emails, cc_emails
  )
  VALUES (
    NEW.candidate_id, v_startup_id, v_program_id, v_cohort_id, NEW.project_id,
    v_type, COALESCE(NEW.activity_timestamp, now()), v_contact_id,
    NEW.metadata->>'email_subject', NEW.activity_id, NEW.metadata->>'email_id',
    COALESCE(ARRAY(SELECT jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(NEW.metadata->'to_emails') = 'array'
           THEN NEW.metadata->'to_emails' ELSE '[]'::jsonb END)), '{}'),
    COALESCE(ARRAY(SELECT jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(NEW.metadata->'cc_emails') = 'array'
           THEN NEW.metadata->'cc_emails' ELSE '[]'::jsonb END)), '{}')
  )
  ON CONFLICT (activity_id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_intro_activity ON public.candidate_activities;
CREATE TRIGGER trg_project_intro_activity
  AFTER INSERT ON public.candidate_activities
  FOR EACH ROW EXECUTE FUNCTION public.project_intro_activity();

-- 5. Backfill from existing activity rows -----------------------------------

INSERT INTO public.candidate_startup_intros (
  candidate_id, startup_id, program_id, cohort_id, project_id,
  intro_type, sent_at, subject, activity_id, email_id, status
)
SELECT a.candidate_id,
       s.id,
       m.program_id,
       m.cohort_id,
       a.project_id,
       CASE WHEN s.id IS NOT NULL THEN 'startup' ELSE 'independent' END,
       COALESCE(a.activity_timestamp, a.created_at, now()),
       a.metadata->>'email_subject',
       a.activity_id,
       a.metadata->>'email_id',
       -- Historic intros have no recorded outcome. 'sent' is the honest value;
       -- the placement migration promotes those that produced a hire.
       'sent'
FROM public.candidate_activities a
LEFT JOIN public.startups s
  ON s.id = CASE
              WHEN a.metadata->>'startup_id' ~ '^[0-9a-fA-F-]{36}$'
              THEN (a.metadata->>'startup_id')::uuid
            END
LEFT JOIN LATERAL public.candidate_admitting_membership(a.candidate_id) m ON true
WHERE a.activity_type IN ('candidate_startup_intro', 'candidate_independent_intro')
  AND NOT EXISTS (
    SELECT 1 FROM public.candidate_startup_intros i WHERE i.activity_id = a.activity_id
  );

-- 6. Conversion view --------------------------------------------------------
-- The number a placement program lives by, now computable.

CREATE OR REPLACE VIEW public.intro_funnel_by_program AS
SELECT p.id   AS program_id,
       p.name AS program_name,
       c.id   AS cohort_id,
       c.name AS cohort_name,
       count(*)                                            AS intros_sent,
       count(*) FILTER (WHERE i.status <> 'sent')           AS intros_progressed,
       count(*) FILTER (WHERE i.status = 'placed')          AS intros_placed,
       count(*) FILTER (WHERE i.status IN ('declined','no_response','withdrawn')) AS intros_lost,
       round(
         100.0 * count(*) FILTER (WHERE i.status = 'placed')
         / NULLIF(count(*), 0), 1
       ) AS placement_rate_pct,
       avg(i.responded_at - i.sent_at) FILTER (WHERE i.responded_at IS NOT NULL)
         AS avg_time_to_response
FROM public.candidate_startup_intros i
LEFT JOIN public.programs p ON p.id = i.program_id
LEFT JOIN public.cohorts  c ON c.id = i.cohort_id
GROUP BY p.id, p.name, c.id, c.name;

ALTER VIEW public.intro_funnel_by_program SET (security_invoker = on);

COMMENT ON VIEW public.intro_funnel_by_program IS
  'Intro-to-placement conversion per program and cohort. The core metric of a placement program.';

-- 7. RLS and grants ---------------------------------------------------------

ALTER TABLE public.candidate_startup_intros ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_full_access" ON public.candidate_startup_intros
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.candidate_startup_intros TO authenticated, service_role;
GRANT SELECT ON public.intro_funnel_by_program TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.candidate_admitting_membership(uuid) TO authenticated, service_role;
