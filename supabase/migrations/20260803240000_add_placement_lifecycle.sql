-- ============================================================================
-- Placement lifecycle and program attribution
-- ============================================================================
-- candidate_startup_placements is the business outcome the whole platform exists
-- to produce, and it is the least-modelled table in the schema:
--
--   candidate_id, startup_id, role_title text, notes text, created_at
--
-- A free-text title and a notes blob. A candidate NOTE carries more structure
-- (it has an author and an avatar). Concretely this means:
--
--   * No program attribution. Which program placed this person is unanswerable,
--     even though it is the primary thing a placement program reports on.
--   * No status. A signed hire and a maybe look identical.
--   * No real dates. created_at is when somebody typed the row, so the
--     `placements` metric in analytics.sql charts data-entry habits, not hiring.
--   * No attribution to the work that produced it -- no link to the intro or the
--     funnel -- so you cannot tell which sourcing effort actually worked.
--   * UNIQUE (candidate_id, startup_id) makes a second placement at the same
--     company impossible. Rehires and second roles are unrepresentable.
--
-- Everything here is additive. Existing rows keep their values and gain NULLs.
-- ============================================================================

-- 1. New columns ------------------------------------------------------------

ALTER TABLE public.candidate_startup_placements
  -- Attribution. Per the agreed model this is the program that admitted the
  -- CANDIDATE -- the one that supplied the talent -- not the startup's program.
  -- Pinned at creation so later membership edits never rewrite history.
  ADD COLUMN IF NOT EXISTS program_id uuid REFERENCES public.programs(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS cohort_id  uuid REFERENCES public.cohorts(id)  ON DELETE SET NULL,

  -- What produced this placement.
  ADD COLUMN IF NOT EXISTS intro_id   uuid REFERENCES public.candidate_startup_intros(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS project_id uuid REFERENCES public.projects(project_id) ON DELETE SET NULL,

  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'placed'
    CHECK (status IN (
      'offered',    -- offer extended, not yet accepted
      'accepted',   -- accepted, not yet started
      'placed',     -- started work
      'completed',  -- finished a fixed-term placement in good standing
      'churned',    -- left early
      'fell_through'-- did not happen after an offer
    )),

  -- The dates that actually matter. created_at stays as the record-entry
  -- timestamp; these describe the placement itself.
  ADD COLUMN IF NOT EXISTS offered_on date,
  ADD COLUMN IF NOT EXISTS started_on date,
  ADD COLUMN IF NOT EXISTS ended_on   date,

  ADD COLUMN IF NOT EXISTS seniority        text,
  ADD COLUMN IF NOT EXISTS employment_type  text
    CHECK (employment_type IS NULL OR employment_type IN
           ('full_time','part_time','contract','internship')),
  ADD COLUMN IF NOT EXISTS salary_amount   numeric(12,2),
  ADD COLUMN IF NOT EXISTS salary_currency text;

COMMENT ON COLUMN public.candidate_startup_placements.program_id IS
  'The program that admitted the candidate (the talent side), pinned at creation. NULL on historic rows with no membership on file.';
COMMENT ON COLUMN public.candidate_startup_placements.started_on IS
  'When the person actually started. created_at is only when the row was entered.';

ALTER TABLE public.candidate_startup_placements
  ADD CONSTRAINT placements_date_order
    CHECK (ended_on IS NULL OR started_on IS NULL OR ended_on >= started_on);

CREATE INDEX IF NOT EXISTS idx_csp_program    ON public.candidate_startup_placements (program_id);
CREATE INDEX IF NOT EXISTS idx_csp_cohort     ON public.candidate_startup_placements (cohort_id);
CREATE INDEX IF NOT EXISTS idx_csp_status     ON public.candidate_startup_placements (status);
CREATE INDEX IF NOT EXISTS idx_csp_started_on ON public.candidate_startup_placements (started_on);
CREATE INDEX IF NOT EXISTS idx_csp_intro      ON public.candidate_startup_placements (intro_id);

-- 2. Allow repeat placements ------------------------------------------------
-- A person can be placed at the same startup twice -- a rehire, or a second role
-- after the first ended. The blanket unique constraint made that impossible.
-- Replaced with a partial index: only one OPEN placement per candidate/startup,
-- while any number of closed ones may coexist.

ALTER TABLE public.candidate_startup_placements
  DROP CONSTRAINT IF EXISTS candidate_startup_placements_unique;

CREATE UNIQUE INDEX IF NOT EXISTS csp_one_open_per_candidate_startup
  ON public.candidate_startup_placements (candidate_id, startup_id)
  WHERE status IN ('offered', 'accepted', 'placed');

-- 3. Pin attribution at creation --------------------------------------------
-- Fills program_id/cohort_id from the candidate's admitting membership when the
-- caller does not supply them, so existing INSERT statements gain attribution
-- with no application change. An explicit value always wins.
-- If the placement references an intro, that intro's attribution takes priority,
-- since it was pinned earlier and is what the funnel reported at the time.

CREATE OR REPLACE FUNCTION public.apply_placement_attribution()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_program uuid;
  v_cohort  uuid;
BEGIN
  IF NEW.program_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.intro_id IS NOT NULL THEN
    SELECT i.program_id, i.cohort_id INTO v_program, v_cohort
    FROM public.candidate_startup_intros i WHERE i.id = NEW.intro_id;
  END IF;

  IF v_program IS NULL THEN
    SELECT m.program_id, m.cohort_id INTO v_program, v_cohort
    FROM public.candidate_admitting_membership(NEW.candidate_id) m;
  END IF;

  NEW.program_id := v_program;
  NEW.cohort_id  := COALESCE(NEW.cohort_id, v_cohort);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_csp_apply_attribution ON public.candidate_startup_placements;
CREATE TRIGGER trg_csp_apply_attribution
  BEFORE INSERT ON public.candidate_startup_placements
  FOR EACH ROW EXECUTE FUNCTION public.apply_placement_attribution();

-- 4. Keep the originating intro in step --------------------------------------
-- A placement is the terminal state of an intro. Marking it here saves the app
-- from having to remember, and keeps intro_funnel_by_program honest.

CREATE OR REPLACE FUNCTION public.sync_intro_on_placement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.intro_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status IN ('accepted', 'placed', 'completed') THEN
    UPDATE public.candidate_startup_intros
    SET status = 'placed', closed_at = COALESCE(closed_at, now())
    WHERE id = NEW.intro_id AND status <> 'placed';
  ELSIF NEW.status = 'fell_through' THEN
    UPDATE public.candidate_startup_intros
    SET status = 'declined', closed_at = COALESCE(closed_at, now())
    WHERE id = NEW.intro_id AND status NOT IN ('declined', 'placed');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_csp_sync_intro ON public.candidate_startup_placements;
CREATE TRIGGER trg_csp_sync_intro
  AFTER INSERT OR UPDATE OF status ON public.candidate_startup_placements
  FOR EACH ROW EXECUTE FUNCTION public.sync_intro_on_placement();

-- 5. Backfill ---------------------------------------------------------------

-- Attribution for existing placements, where the candidate has a membership.
-- Written as correlated subqueries rather than FROM LATERAL, because a LATERAL
-- in an UPDATE's FROM clause may not reference the update target.
UPDATE public.candidate_startup_placements p
SET program_id = (SELECT m.program_id
                  FROM public.candidate_admitting_membership(p.candidate_id) m),
    cohort_id  = COALESCE(p.cohort_id,
                          (SELECT m.cohort_id
                           FROM public.candidate_admitting_membership(p.candidate_id) m))
WHERE p.program_id IS NULL
  AND EXISTS (SELECT 1
              FROM public.candidate_admitting_membership(p.candidate_id) m
              WHERE m.program_id IS NOT NULL);

-- Link placements back to the intro that plausibly produced them: same
-- candidate, same startup, intro sent no later than the placement was recorded.
-- Most recent such intro wins; no match simply leaves NULL.
UPDATE public.candidate_startup_placements p
SET intro_id = (
  SELECT i.id
  FROM public.candidate_startup_intros i
  WHERE i.candidate_id = p.candidate_id
    AND i.startup_id   = p.startup_id
    AND i.sent_at     <= p.created_at
  ORDER BY i.sent_at DESC
  LIMIT 1
)
WHERE p.intro_id IS NULL AND p.startup_id IS NOT NULL;

-- Those intros did produce a hire, so reflect it rather than leaving them 'sent'.
UPDATE public.candidate_startup_intros i
SET status = 'placed', closed_at = COALESCE(i.closed_at, now())
FROM public.candidate_startup_placements p
WHERE p.intro_id = i.id AND i.status <> 'placed';

-- started_on is unknown for historic rows; created_at is the only signal there
-- is. Recorded as a date so it is visibly an approximation, not a real event.
UPDATE public.candidate_startup_placements
SET started_on = created_at::date
WHERE started_on IS NULL AND status = 'placed';

-- 6. Reporting view ---------------------------------------------------------

CREATE OR REPLACE VIEW public.placements_by_program AS
SELECT pr.id    AS program_id,
       pr.name  AS program_name,
       co.id    AS cohort_id,
       co.name  AS cohort_name,
       date_trunc('month', COALESCE(p.started_on, p.created_at::date))::date AS month,
       count(*)                                              AS placements,
       count(*) FILTER (WHERE p.status = 'placed')           AS active_placements,
       count(*) FILTER (WHERE p.status = 'churned')          AS churned,
       count(*) FILTER (WHERE p.status = 'fell_through')     AS fell_through,
       count(DISTINCT p.candidate_id)                        AS people_placed,
       count(DISTINCT p.startup_id)                          AS startups_hiring
FROM public.candidate_startup_placements p
LEFT JOIN public.programs pr ON pr.id = p.program_id
LEFT JOIN public.cohorts  co ON co.id = p.cohort_id
GROUP BY pr.id, pr.name, co.id, co.name, 5;

ALTER VIEW public.placements_by_program SET (security_invoker = on);

COMMENT ON VIEW public.placements_by_program IS
  'Placements per program and cohort by month of actual start date, not record-entry date.';

GRANT SELECT ON public.placements_by_program TO authenticated, service_role;
