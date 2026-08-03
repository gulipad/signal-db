-- ============================================================================
-- Funnel transition history
-- ============================================================================
-- `candidate_project_buckets` stores only the CURRENT bucket, and the app moves
-- a candidate with an in-place `UPDATE ... SET bucket_id = ...`. Each move
-- therefore destroys the previous state, and the funnel has no memory:
-- conversion between stages, time-in-stage, and where candidates stall are all
-- unanswerable. `analytics.sql` documents the consequence itself --
-- `funnel_moves` counts assignments that have ever moved, not moves, and the
-- `bucket_count` snapshot admits it cannot be reconstructed for past days.
--
-- This records every transition as an immutable event.
--
-- Deliberately implemented as a TRIGGER rather than an application change: the
-- app keeps issuing exactly the same UPDATE it does today and history accrues
-- underneath it. Nothing has to ship in lockstep, and any other writer (SQL
-- editor, MCP client, a future service) is captured too.
-- ============================================================================

-- 1. The event log ----------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.candidate_bucket_transitions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id   uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,
  project_id     uuid NOT NULL REFERENCES public.projects(project_id) ON DELETE CASCADE,

  -- NULL from_bucket_id  => the candidate entered the funnel
  -- NULL to_bucket_id    => the candidate was removed from the funnel
  -- Both set             => an ordinary move between stages
  from_bucket_id uuid REFERENCES public.project_buckets(bucket_id) ON DELETE SET NULL,
  to_bucket_id   uuid REFERENCES public.project_buckets(bucket_id) ON DELETE SET NULL,

  -- The candidate_project_buckets row this came from. Not a foreign key: the
  -- assignment may be deleted while its history must survive.
  assignment_id  uuid,

  -- auth.uid() is NULL for service-role writes and backfilled rows.
  actor_id       uuid REFERENCES auth.users(id),

  occurred_at    timestamptz NOT NULL DEFAULT now(),

  -- 'trigger' for live moves, 'backfill' for rows reconstructed below, so
  -- analytics can exclude synthesised history when it needs precision.
  source         text NOT NULL DEFAULT 'trigger'
                 CHECK (source IN ('trigger', 'backfill')),

  CONSTRAINT candidate_bucket_transitions_not_noop
    CHECK (from_bucket_id IS DISTINCT FROM to_bucket_id)
);

COMMENT ON TABLE public.candidate_bucket_transitions IS
  'Immutable log of candidate movement through project buckets. Written by trigger on candidate_project_buckets; never updated.';

CREATE INDEX IF NOT EXISTS idx_cbt_candidate     ON public.candidate_bucket_transitions (candidate_id);
CREATE INDEX IF NOT EXISTS idx_cbt_project       ON public.candidate_bucket_transitions (project_id);
CREATE INDEX IF NOT EXISTS idx_cbt_occurred_at   ON public.candidate_bucket_transitions (occurred_at);
CREATE INDEX IF NOT EXISTS idx_cbt_to_bucket     ON public.candidate_bucket_transitions (to_bucket_id);
-- Serves the per-assignment window functions used by the duration view.
CREATE INDEX IF NOT EXISTS idx_cbt_assignment_time
  ON public.candidate_bucket_transitions (assignment_id, occurred_at);

-- 2. Trigger ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.record_bucket_transition()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_actor uuid;
BEGIN
  -- auth.uid() throws if no JWT claims are present (plain psql, cron, seeds).
  BEGIN
    v_actor := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_actor := NULL;
  END;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.candidate_bucket_transitions
      (candidate_id, project_id, from_bucket_id, to_bucket_id, assignment_id, actor_id, occurred_at)
    VALUES
      (NEW.candidate_id, NEW.project_id, NULL, NEW.bucket_id, NEW.id, v_actor,
       COALESCE(NEW.created_at, now()));
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Only a genuine stage change is an event; touching other columns is not.
    IF NEW.bucket_id IS DISTINCT FROM OLD.bucket_id THEN
      INSERT INTO public.candidate_bucket_transitions
        (candidate_id, project_id, from_bucket_id, to_bucket_id, assignment_id, actor_id, occurred_at)
      VALUES
        (NEW.candidate_id, NEW.project_id, OLD.bucket_id, NEW.bucket_id, NEW.id, v_actor, now());
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO public.candidate_bucket_transitions
      (candidate_id, project_id, from_bucket_id, to_bucket_id, assignment_id, actor_id, occurred_at)
    VALUES
      (OLD.candidate_id, OLD.project_id, OLD.bucket_id, NULL, OLD.id, v_actor, now());
    RETURN OLD;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_record_bucket_transition ON public.candidate_project_buckets;
CREATE TRIGGER trg_record_bucket_transition
  AFTER INSERT OR UPDATE OR DELETE ON public.candidate_project_buckets
  FOR EACH ROW EXECUTE FUNCTION public.record_bucket_transition();

-- 3. Backfill ---------------------------------------------------------------
-- Reconstructs what the current rows still imply. This is necessarily partial:
-- an in-place UPDATE leaves no trace of where a candidate came from, so a moved
-- assignment yields an entry event and a move whose origin is unknown (NULL).
-- Marked source='backfill' so it is distinguishable from real history.

-- A never-moved assignment still sits where it entered, so its entry event is
-- exact. A moved assignment has lost its origin to the in-place UPDATE, so only
-- the move is recorded -- an entry row would be NULL -> NULL, which is both
-- meaningless and rejected by the no-op CHECK above.

INSERT INTO public.candidate_bucket_transitions
  (candidate_id, project_id, from_bucket_id, to_bucket_id, assignment_id, occurred_at, source)
SELECT cpb.candidate_id, cpb.project_id, NULL, cpb.bucket_id, cpb.id,
       COALESCE(cpb.created_at, now()), 'backfill'
FROM public.candidate_project_buckets cpb
WHERE (cpb.updated_at IS NULL OR cpb.updated_at = cpb.created_at)
  AND cpb.bucket_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.candidate_bucket_transitions t WHERE t.assignment_id = cpb.id
  );

INSERT INTO public.candidate_bucket_transitions
  (candidate_id, project_id, from_bucket_id, to_bucket_id, assignment_id, occurred_at, source)
SELECT cpb.candidate_id, cpb.project_id, NULL, cpb.bucket_id, cpb.id, cpb.updated_at, 'backfill'
FROM public.candidate_project_buckets cpb
WHERE cpb.updated_at IS NOT NULL
  AND cpb.updated_at <> cpb.created_at
  AND cpb.bucket_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.candidate_bucket_transitions t
    WHERE t.assignment_id = cpb.id AND t.occurred_at = cpb.updated_at
  );

-- 4. Time-in-stage view -----------------------------------------------------
-- The question the funnel could never answer. One row per stage occupancy,
-- with its duration; `ended_at IS NULL` means the candidate sits there now.

CREATE OR REPLACE VIEW public.candidate_bucket_stage_durations AS
SELECT t.id                AS transition_id,
       t.candidate_id,
       t.project_id,
       t.to_bucket_id      AS bucket_id,
       pb.name             AS bucket_name,
       t.occurred_at       AS entered_at,
       LEAD(t.occurred_at) OVER w AS ended_at,
       COALESCE(LEAD(t.occurred_at) OVER w, now()) - t.occurred_at AS duration,
       LEAD(t.occurred_at) OVER w IS NULL AS is_current,
       t.source
FROM public.candidate_bucket_transitions t
LEFT JOIN public.project_buckets pb ON pb.bucket_id = t.to_bucket_id
WHERE t.to_bucket_id IS NOT NULL
WINDOW w AS (PARTITION BY t.assignment_id ORDER BY t.occurred_at);

COMMENT ON VIEW public.candidate_bucket_stage_durations IS
  'One row per stage occupancy with its duration. ended_at IS NULL means the candidate is currently in that bucket.';

ALTER VIEW public.candidate_bucket_stage_durations SET (security_invoker = on);

-- 5. Grants -----------------------------------------------------------------

ALTER TABLE public.candidate_bucket_transitions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_read_transitions" ON public.candidate_bucket_transitions
  FOR SELECT TO authenticated USING (true);

-- Insert-only for authenticated: history must not be edited. The trigger is
-- SECURITY DEFINER so it writes regardless of these policies.
CREATE POLICY "authenticated_insert_transitions" ON public.candidate_bucket_transitions
  FOR INSERT TO authenticated WITH CHECK (true);

GRANT SELECT, INSERT ON public.candidate_bucket_transitions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.candidate_bucket_transitions TO service_role;
GRANT SELECT ON public.candidate_bucket_stage_durations TO authenticated, service_role;
