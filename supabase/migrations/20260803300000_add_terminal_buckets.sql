-- ============================================================================
-- Mark terminal funnel stages
-- ============================================================================
-- `is_rejection_column` already marks the stages nobody moves on from because
-- they were turned down. But a funnel has a positive terminal stage too --
-- "Fellow" is where someone lands when they succeed, and they are no more
-- "waiting" there than someone in Rejected.
--
-- Treating either as an ordinary stage distorts every duration on the page: the
-- elapsed time measures how long ago an outcome was reached, not how long
-- somebody is being kept waiting.
--
-- is_terminal is the general property; is_rejection_column stays as the sign of
-- the outcome. Terminal-negative and terminal-positive both stop the clock, but
-- only one of them is bad news.
-- ============================================================================

ALTER TABLE public.project_buckets
  ADD COLUMN IF NOT EXISTS is_terminal boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.project_buckets.is_terminal IS
  'Nobody in this stage is expected to move again. Rejection columns are terminal; so is the success stage a funnel ends in. Durations are not reported for terminal stages.';

-- Every rejection column is terminal by definition.
UPDATE public.project_buckets
SET is_terminal = true
WHERE is_rejection_column AND NOT is_terminal;

-- Known positive terminal stages. Name matching is a one-time backfill, not a
-- rule -- from here it is set explicitly when a bucket is created.
UPDATE public.project_buckets
SET is_terminal = true
WHERE NOT is_terminal
  AND lower(trim(name)) IN ('fellow', 'fellows', 'placed', 'hired');

CREATE INDEX IF NOT EXISTS idx_project_buckets_terminal
  ON public.project_buckets (project_id) WHERE is_terminal;
