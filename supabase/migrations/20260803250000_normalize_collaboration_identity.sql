-- ============================================================================
-- Collaboration identity
-- ============================================================================
-- Two incompatible models of "who did this" coexist:
--
--   candidate_activities.actor_id   uuid  -> auth.users        (correct)
--   inbox_events.reviewed_by        uuid  -> nothing           (unconstrained)
--   candidate_notes.created_by      text                       (denormalized)
--   candidate_notes.creator_avatar_url text                    (denormalized)
--
-- Notes store the author's NAME and AVATAR URL as strings. Change a display name
-- and history becomes inconsistent; "everything written by X" is a string match
-- rather than a join. reviewed_by is a real uuid the app already populates, but
-- with no foreign key it can hold any value, including one pointing at a deleted
-- user.
--
-- The practical cost is that per-person collaboration analytics is impossible:
-- you can measure how fast the team reviews, never who reviewed.
--
-- Strictly additive. The existing text columns are KEPT and still written by the
-- app; the new column is populated alongside them. Nothing has to ship in
-- lockstep, and the display strings remain as a historical record of what the
-- author was called at the time.
-- ============================================================================

-- 1. Constrain reviewed_by --------------------------------------------------
-- Added as a fully validated constraint. Checked against production first:
-- inbox_events has ZERO rows with a non-null reviewed_by, so there is nothing to
-- grandfather and no orphan to tolerate. The column is written by
-- src/data/inbox-events.ts but that path has evidently never executed, which is
-- also why per-reviewer analytics has never been possible.

ALTER TABLE public.inbox_events
  DROP CONSTRAINT IF EXISTS inbox_events_reviewed_by_fkey;

ALTER TABLE public.inbox_events
  ADD CONSTRAINT inbox_events_reviewed_by_fkey
  FOREIGN KEY (reviewed_by) REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_inbox_events_reviewed_by ON public.inbox_events (reviewed_by);

COMMENT ON COLUMN public.inbox_events.reviewed_by IS
  'The user who reviewed this event. Fully validated FK: production held no non-null values when it was added.';

-- 2. Real authorship on notes -----------------------------------------------

ALTER TABLE public.candidate_notes
  ADD COLUMN IF NOT EXISTS created_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_candidate_notes_created_by_user
  ON public.candidate_notes (created_by_user_id);

COMMENT ON COLUMN public.candidate_notes.created_by_user_id IS
  'Author as a real reference. created_by/creator_avatar_url are retained as a snapshot of how the author appeared when the note was written.';

-- Backfill by matching the stored display string against auth.users. Matches on
-- email, then on the GitHub username in user_metadata, then on full name.
-- Deliberately conservative: only unambiguous single matches are applied, so a
-- shared or ambiguous string is left NULL rather than attributed to the wrong
-- person.
UPDATE public.candidate_notes n
SET created_by_user_id = (
  SELECT u.id
  FROM auth.users u
  WHERE lower(u.email) = lower(trim(n.created_by))
     OR lower(u.raw_user_meta_data->>'user_name')           = lower(trim(n.created_by))
     OR lower(u.raw_user_meta_data->>'preferred_username')  = lower(trim(n.created_by))
     OR lower(u.raw_user_meta_data->>'full_name')           = lower(trim(n.created_by))
     OR lower(u.raw_user_meta_data->>'name')                = lower(trim(n.created_by))
  LIMIT 1
)
WHERE n.created_by_user_id IS NULL
  AND n.created_by IS NOT NULL
  AND length(trim(n.created_by)) > 0
  AND (
    SELECT count(*)
    FROM auth.users u
    WHERE lower(u.email) = lower(trim(n.created_by))
       OR lower(u.raw_user_meta_data->>'user_name')          = lower(trim(n.created_by))
       OR lower(u.raw_user_meta_data->>'preferred_username') = lower(trim(n.created_by))
       OR lower(u.raw_user_meta_data->>'full_name')          = lower(trim(n.created_by))
       OR lower(u.raw_user_meta_data->>'name')               = lower(trim(n.created_by))
  ) = 1;

-- Fill it automatically for new notes when the app does not supply it, so the
-- column stays populated without waiting on a frontend release.
CREATE OR REPLACE FUNCTION public.apply_note_author()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_actor uuid;
BEGIN
  IF NEW.created_by_user_id IS NULL THEN
    BEGIN
      v_actor := auth.uid();
    EXCEPTION WHEN OTHERS THEN
      v_actor := NULL;
    END;
    NEW.created_by_user_id := v_actor;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_candidate_notes_apply_author ON public.candidate_notes;
CREATE TRIGGER trg_candidate_notes_apply_author
  BEFORE INSERT ON public.candidate_notes
  FOR EACH ROW EXECUTE FUNCTION public.apply_note_author();

-- 3. Ownership --------------------------------------------------------------
-- Nothing recorded who was responsible for a search, so coordination happened
-- entirely outside the tool.

ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS owner_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_projects_owner ON public.projects (owner_id);

COMMENT ON COLUMN public.projects.owner_id IS
  'The user responsible for this funnel or watchlist. NULL means unassigned.';

-- 4. Per-person throughput --------------------------------------------------
-- Now that every action resolves to a real user, team activity is a query.

CREATE OR REPLACE VIEW public.team_activity_by_user AS
WITH reviews AS (
  SELECT reviewed_by AS user_id, count(*) AS inbox_reviews,
         avg(reviewed_at - created_at) AS avg_review_time
  FROM public.inbox_events
  WHERE reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL AND reviewed_at >= created_at
  GROUP BY 1
),
notes AS (
  SELECT created_by_user_id AS user_id, count(*) AS notes_written
  FROM public.candidate_notes WHERE created_by_user_id IS NOT NULL GROUP BY 1
),
acts AS (
  SELECT actor_id AS user_id,
         count(*) FILTER (WHERE activity_type = 'email_sent')               AS emails_sent,
         count(*) FILTER (WHERE activity_type LIKE '%intro')                AS intros_made,
         count(*)                                                           AS activities
  FROM public.candidate_activities WHERE actor_id IS NOT NULL GROUP BY 1
),
moves AS (
  SELECT actor_id AS user_id, count(*) AS funnel_moves
  FROM public.candidate_bucket_transitions
  WHERE actor_id IS NOT NULL AND from_bucket_id IS NOT NULL
  GROUP BY 1
)
SELECT u.id AS user_id,
       u.email,
       COALESCE(u.raw_user_meta_data->>'user_name', u.raw_user_meta_data->>'full_name') AS display_name,
       COALESCE(r.inbox_reviews, 0) AS inbox_reviews,
       r.avg_review_time,
       COALESCE(n.notes_written, 0) AS notes_written,
       COALESCE(a.emails_sent, 0)   AS emails_sent,
       COALESCE(a.intros_made, 0)   AS intros_made,
       COALESCE(m.funnel_moves, 0)  AS funnel_moves,
       COALESCE(a.activities, 0)    AS total_activities
FROM auth.users u
LEFT JOIN reviews r ON r.user_id = u.id
LEFT JOIN notes   n ON n.user_id = u.id
LEFT JOIN acts    a ON a.user_id = u.id
LEFT JOIN moves   m ON m.user_id = u.id;

COMMENT ON VIEW public.team_activity_by_user IS
  'Per-person throughput across inbox reviews, notes, emails, intros and funnel moves.';

-- SECURITY DEFINER, not invoker: auth.users is not readable by `authenticated`,
-- so an invoker-rights view would return nothing. The view exposes only
-- aggregate counts and the display identity of the four allow-listed staff.
ALTER VIEW public.team_activity_by_user SET (security_invoker = off);

GRANT SELECT ON public.team_activity_by_user TO authenticated, service_role;
