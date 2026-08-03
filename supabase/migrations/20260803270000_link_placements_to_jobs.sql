-- ============================================================================
-- Connect placements to the existing job board
-- ============================================================================
-- An earlier draft of this work added a `startup_roles` table to model the
-- demand side, on the belief that the only representation of demand was
-- `startups.hiring_page_url`. That was wrong: production already has a live job
-- board -- `jobs` (with 9 rows), `job_applications` (5), `job_saves`, `job_tags`
-- -- which the migration set simply never described. `jobs` already carries
-- startup_id, title, required_skills[], nice_to_have_skills[], salary and equity
-- bands, experience_level, status, published_at and closes_at.
--
-- So rather than introduce a competing table, point placements at the one that
-- exists.
--
-- Only placements carry job_id. An intro is company-level -- "meet this
-- candidate" -- and is not made against a specific posting; a placement is
-- someone actually taking a named role. Putting job_id on intros would invite
-- an attribution that the workflow never establishes.
--
-- The column is nullable: a placement may still reference only a company, and
-- `role_title` remains for placements not tied to a tracked opening.
-- ============================================================================

ALTER TABLE public.candidate_startup_placements
  ADD COLUMN IF NOT EXISTS job_id uuid REFERENCES public.jobs(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_csp_job ON public.candidate_startup_placements (job_id);

COMMENT ON COLUMN public.candidate_startup_placements.job_id IS
  'The opening this placement filled, from the job board. NULL is valid for placements not tied to a tracked posting.';

-- Open demand, expressed against the real job board rather than a parallel one.
-- `jobs` has no headcount column -- one row is one opening -- so demand is a
-- count of open postings, less those already filled by a recorded placement.
CREATE OR REPLACE VIEW public.open_startup_demand AS
SELECT s.id   AS startup_id,
       s.name AS startup_name,
       s.slug AS startup_slug,
       count(j.id)                                             AS open_roles,
       min(j.closes_at)                                        AS soonest_close,
       count(*) FILTER (WHERE j.is_featured)                    AS featured_roles,
       array_agg(DISTINCT j.experience_level)
         FILTER (WHERE j.experience_level IS NOT NULL)          AS experience_levels
FROM public.startups s
JOIN public.jobs j
  ON j.startup_id = s.id
 AND j.status = 'published'
 AND NOT EXISTS (
       SELECT 1 FROM public.candidate_startup_placements p
       WHERE p.job_id = j.id AND p.status IN ('accepted','placed','completed')
     )
GROUP BY s.id, s.name, s.slug;

ALTER VIEW public.open_startup_demand SET (security_invoker = on);

COMMENT ON VIEW public.open_startup_demand IS
  'Unfilled published openings per startup, from the job board. Answers which portfolio companies are underserved.';

GRANT SELECT ON public.open_startup_demand TO authenticated, service_role;
