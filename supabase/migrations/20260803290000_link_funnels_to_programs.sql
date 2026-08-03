-- ============================================================================
-- Link each funnel to a program
-- ============================================================================
-- Funnels and programs have been unrelated: a project of kind='funnel' is where
-- candidates move through stages, and a program is what they were admitted to,
-- but nothing connected them. So "which funnels belong to Fellowship" had no
-- answer, and a placement's program attribution could not be cross-checked
-- against the funnel the person actually came through.
--
-- Nullable on purpose. Watchlists are not program work, and an existing funnel
-- may legitimately not map to one -- forcing a value would mean guessing.
-- ============================================================================

ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS program_id uuid
    REFERENCES public.programs(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_projects_program ON public.projects (program_id);

COMMENT ON COLUMN public.projects.program_id IS
  'The program this funnel serves. NULL is valid: watchlists are not program work, and a funnel may not map to one.';

-- Backfill only what is unambiguous: a funnel whose name contains a program's
-- name. Anything else is left NULL rather than guessed -- "Cohort #01" could
-- belong to either placement program and only a human knows which.
UPDATE public.projects p
SET program_id = prog.id
FROM public.programs prog
WHERE p.program_id IS NULL
  AND p.kind = 'funnel'
  AND prog.kind = 'placement'
  AND lower(p.name) LIKE '%' || lower(prog.name) || '%';
