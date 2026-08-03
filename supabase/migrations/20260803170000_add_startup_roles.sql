-- ============================================================================
-- Startup roles: the demand side
-- ============================================================================
-- Signal has a rich, AI-enriched model of SUPPLY -- candidates, sources,
-- summaries, availability, tags. Its model of DEMAND is a single column:
--
--   startups.hiring_page_url text
--
-- A URL. There is no concept of a role or opening anywhere in the schema.
-- Placements point at a COMPANY, not at a JOB. So:
--
--   * "Acme needs two backend engineers by Q3" is not expressible.
--   * Open headcount across the portfolio cannot be totalled.
--   * Candidates cannot be matched against requirements, because requirements
--     are not data.
--   * A startup that is quietly underserved is invisible.
--
-- For a two-sided matching business this is the largest structural gap: the
-- matching engine has everything it needs about people and almost nothing about
-- the jobs they are being matched to.
--
-- Entirely additive. hiring_page_url is left in place and untouched.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.startup_roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  startup_id  uuid NOT NULL REFERENCES public.startups(id) ON DELETE CASCADE,

  title       text NOT NULL CHECK (length(trim(title)) > 0),
  description text,

  -- What the role actually needs, in a shape that can be filtered and matched
  -- rather than read by a human.
  seniority   text CHECK (seniority IS NULL OR seniority IN
                ('intern','junior','mid','senior','staff','principal','lead','exec')),
  discipline  text,                                  -- engineering, design, sales...
  tech_stack  text[] NOT NULL DEFAULT '{}',          -- mirrors startups.tech_stack
  skills      text[] NOT NULL DEFAULT '{}',

  employment_type text CHECK (employment_type IS NULL OR employment_type IN
                     ('full_time','part_time','contract','internship')),
  location        text,
  remote_friendly boolean,

  salary_min      numeric(12,2),
  salary_max      numeric(12,2),
  salary_currency text,

  -- How many people are wanted, and how many have been hired against it. The
  -- pair is what makes "still open" a fact rather than an opinion.
  headcount        integer NOT NULL DEFAULT 1 CHECK (headcount > 0),
  headcount_filled integer NOT NULL DEFAULT 0 CHECK (headcount_filled >= 0),

  status      text NOT NULL DEFAULT 'open'
              CHECK (status IN ('draft','open','paused','filled','cancelled')),

  opened_on   date NOT NULL DEFAULT current_date,
  target_by   date,
  closed_on   date,

  priority    text CHECK (priority IS NULL OR priority IN ('low','normal','high','urgent')),
  notes       text,

  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT startup_roles_salary_order
    CHECK (salary_max IS NULL OR salary_min IS NULL OR salary_max >= salary_min),
  CONSTRAINT startup_roles_closed_after_opened
    CHECK (closed_on IS NULL OR closed_on >= opened_on)
);

COMMENT ON TABLE public.startup_roles IS
  'An opening at a startup. The demand side of matching: previously the only representation of demand was startups.hiring_page_url.';
COMMENT ON COLUMN public.startup_roles.headcount_filled IS
  'Maintained automatically from placements that reference this role.';

CREATE INDEX IF NOT EXISTS idx_startup_roles_startup    ON public.startup_roles (startup_id);
CREATE INDEX IF NOT EXISTS idx_startup_roles_status     ON public.startup_roles (status);
CREATE INDEX IF NOT EXISTS idx_startup_roles_seniority  ON public.startup_roles (seniority);
CREATE INDEX IF NOT EXISTS idx_startup_roles_opened_on  ON public.startup_roles (opened_on);
-- GIN indexes so matching on stack/skills is a real query, not a table scan.
CREATE INDEX IF NOT EXISTS idx_startup_roles_tech_stack ON public.startup_roles USING gin (tech_stack);
CREATE INDEX IF NOT EXISTS idx_startup_roles_skills     ON public.startup_roles USING gin (skills);

DROP TRIGGER IF EXISTS trg_startup_roles_touch_updated_at ON public.startup_roles;
CREATE TRIGGER trg_startup_roles_touch_updated_at
  BEFORE UPDATE ON public.startup_roles
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- Connect the two sides -----------------------------------------------------
-- Optional on both, so nothing existing breaks: an intro or placement may still
-- reference only a company, exactly as today.

ALTER TABLE public.candidate_startup_placements
  ADD COLUMN IF NOT EXISTS role_id uuid REFERENCES public.startup_roles(id) ON DELETE SET NULL;

ALTER TABLE public.candidate_startup_intros
  ADD COLUMN IF NOT EXISTS role_id uuid REFERENCES public.startup_roles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_csp_role    ON public.candidate_startup_placements (role_id);
CREATE INDEX IF NOT EXISTS idx_intros_role ON public.candidate_startup_intros (role_id);

COMMENT ON COLUMN public.candidate_startup_placements.role_id IS
  'The opening this placement filled. NULL is valid: role_title remains for placements not tied to a tracked opening.';

-- Keep headcount_filled honest ----------------------------------------------
-- Recomputed from placements rather than incremented, so it is correct after any
-- sequence of inserts, status changes, re-pointing or deletes.

CREATE OR REPLACE FUNCTION public.refresh_role_headcount()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_roles uuid[];
  v_role  uuid;
BEGIN
  v_roles := ARRAY(
    SELECT DISTINCT r FROM unnest(ARRAY[
      CASE WHEN TG_OP <> 'INSERT' THEN OLD.role_id END,
      CASE WHEN TG_OP <> 'DELETE' THEN NEW.role_id END
    ]) AS r WHERE r IS NOT NULL
  );

  FOREACH v_role IN ARRAY v_roles LOOP
    UPDATE public.startup_roles sr
    SET headcount_filled = (
          SELECT count(*)
          FROM public.candidate_startup_placements p
          WHERE p.role_id = v_role
            AND p.status IN ('accepted','placed','completed')
        )
    WHERE sr.id = v_role;

    -- Auto-close a role once it is fully staffed, and reopen it if a placement
    -- is withdrawn. Never overrides a deliberate pause or cancellation.
    UPDATE public.startup_roles sr
    SET status    = CASE WHEN sr.headcount_filled >= sr.headcount THEN 'filled' ELSE 'open' END,
        closed_on = CASE WHEN sr.headcount_filled >= sr.headcount
                         THEN COALESCE(sr.closed_on, current_date) ELSE NULL END
    WHERE sr.id = v_role AND sr.status IN ('open','filled');
  END LOOP;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_csp_refresh_role_headcount ON public.candidate_startup_placements;
CREATE TRIGGER trg_csp_refresh_role_headcount
  AFTER INSERT OR UPDATE OF role_id, status OR DELETE
  ON public.candidate_startup_placements
  FOR EACH ROW EXECUTE FUNCTION public.refresh_role_headcount();

-- Open demand ---------------------------------------------------------------
-- The question that could not be asked: who needs people, and how badly.

CREATE OR REPLACE VIEW public.open_startup_demand AS
SELECT s.id   AS startup_id,
       s.name AS startup_name,
       s.slug AS startup_slug,
       count(r.id)                                   AS open_roles,
       sum(r.headcount - r.headcount_filled)         AS open_headcount,
       min(r.target_by) FILTER (WHERE r.target_by IS NOT NULL) AS soonest_target,
       count(*) FILTER (WHERE r.priority IN ('high','urgent')) AS urgent_roles,
       array_agg(DISTINCT r.discipline) FILTER (WHERE r.discipline IS NOT NULL) AS disciplines
FROM public.startups s
JOIN public.startup_roles r
  ON r.startup_id = s.id
 AND r.status = 'open'
 AND r.headcount_filled < r.headcount
GROUP BY s.id, s.name, s.slug;

ALTER VIEW public.open_startup_demand SET (security_invoker = on);

COMMENT ON VIEW public.open_startup_demand IS
  'Unfilled headcount per startup. Answers which portfolio companies are underserved.';

-- RLS and grants ------------------------------------------------------------

ALTER TABLE public.startup_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_full_access" ON public.startup_roles
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.startup_roles TO authenticated, service_role;
GRANT SELECT ON public.open_startup_demand TO authenticated, service_role;
