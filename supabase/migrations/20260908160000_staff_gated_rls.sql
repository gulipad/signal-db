-- ============================================================================
-- STAFF-GATED RLS
--
-- Problem: every RLS policy on the internal tables is `authenticated_full_access`
-- with USING (true). Supabase issues one kind of session token per project, so
-- anyone who signs in through the community site (16 accounts today, 14 of them
-- candidates and community members) holds an `authenticated` token that can read
-- and write candidates, contacts, inbox_events, notes, and the rest by calling
-- the REST API directly. The signal UI's staff allow-list lives only in app code.
--
-- Fix:
--   1. A `staff` table and an `is_staff()` function the database can check.
--   2. Replace USING (true) with USING (is_staff()) on every internal table.
--   3. Rebuild the two SECURITY DEFINER views that read auth.users so they read
--      `staff` instead and run with invoker rights (closes the advisor findings).
--   4. Revoke leftover anon grants on internal tables.
--
-- Unaffected: service_role bypasses RLS, so the website, the MCP server, and the
-- REST-based skills keep working. Community tables (posts, comments, jobs,
-- profiles, ...) keep their own policies and are not touched.
--
-- Verified before writing (2026-09-08): all `authenticated` traffic against the
-- internal tables since 2026-06-27 matches the signal UI; no community-app query
-- shape touches them.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Staff table + is_staff()
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.staff (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email        text NOT NULL,
  display_name text,
  added_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.staff IS
  'Users allowed to operate the internal signal UI. RLS on internal tables checks membership here via is_staff(). Add a row to grant access, delete it to revoke.';

-- Default privileges hand every new table to anon/authenticated. Take them back
-- and grant only what the views below need.
REVOKE ALL ON public.staff FROM anon, authenticated;
GRANT SELECT ON public.staff TO authenticated;
GRANT ALL    ON public.staff TO service_role;

-- SECURITY DEFINER so the check bypasses RLS on `staff` itself (no recursion)
-- and can be called from any policy. STABLE lets the planner evaluate it once
-- per statement.
CREATE OR REPLACE FUNCTION public.is_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.staff WHERE user_id = auth.uid());
$$;

REVOKE ALL ON FUNCTION public.is_staff() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.is_staff() TO authenticated, service_role;

ALTER TABLE public.staff ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_read ON public.staff;
CREATE POLICY staff_read ON public.staff
  FOR SELECT TO authenticated
  USING (public.is_staff());

-- Seed: the two people who operate the app today.
INSERT INTO public.staff (user_id, email, display_name)
SELECT u.id,
       u.email,
       COALESCE(u.raw_user_meta_data->>'user_name', u.raw_user_meta_data->>'full_name')
FROM auth.users u
WHERE u.id IN (
  '5235a5b8-0185-440e-883d-54ee0b3abd88',  -- gulipad
  '44a01f04-f23d-4e3b-95e8-19426d17acba'   -- dumenac
)
ON CONFLICT (user_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. Replace authenticated_full_access with staff_full_access
--    (29 tables, the full set carrying that policy as of 2026-09-08)
-- ----------------------------------------------------------------------------

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'candidate_activities',
    'candidate_availability',
    'candidate_notes',
    'candidate_program_memberships',
    'candidate_project_buckets',
    'candidate_rejection_reasons',
    'candidate_startup_intros',
    'candidate_startup_placements',
    'candidate_summaries',
    'candidate_tags',
    'candidates',
    'cohorts',
    'column_email_associations',
    'contacts',
    'email_templates',
    'founder_forum_applications',
    'founder_forum_members',
    'inbox_events',
    'programs',
    'project_buckets',
    'projects',
    'public_profiles',
    'rejection_reasons',
    'source_data',
    'sources',
    'startup_programs',
    'startups',
    'tags',
    'testimonials'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS authenticated_full_access ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS staff_full_access ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY staff_full_access ON public.%I FOR ALL TO authenticated USING (public.is_staff()) WITH CHECK (public.is_staff())',
      t
    );
  END LOOP;
END $$;

-- Tables with bespoke authenticated policies: same idea, keep their shape.

-- candidate_bucket_transitions: read all, insert only (append-only log)
DROP POLICY IF EXISTS authenticated_read_transitions   ON public.candidate_bucket_transitions;
DROP POLICY IF EXISTS authenticated_insert_transitions ON public.candidate_bucket_transitions;
DROP POLICY IF EXISTS staff_read_transitions   ON public.candidate_bucket_transitions;
DROP POLICY IF EXISTS staff_insert_transitions ON public.candidate_bucket_transitions;
CREATE POLICY staff_read_transitions ON public.candidate_bucket_transitions
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY staff_insert_transitions ON public.candidate_bucket_transitions
  FOR INSERT TO authenticated WITH CHECK (public.is_staff());

-- inbox_event_inputs: staff read everything, write only their own row
DROP POLICY IF EXISTS authenticated_read_inputs      ON public.inbox_event_inputs;
DROP POLICY IF EXISTS authenticated_write_own_input  ON public.inbox_event_inputs;
DROP POLICY IF EXISTS staff_read_inputs      ON public.inbox_event_inputs;
DROP POLICY IF EXISTS staff_write_own_input  ON public.inbox_event_inputs;
CREATE POLICY staff_read_inputs ON public.inbox_event_inputs
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY staff_write_own_input ON public.inbox_event_inputs
  FOR ALL TO authenticated
  USING (public.is_staff() AND user_id = auth.uid())
  WITH CHECK (public.is_staff() AND user_id = auth.uid());

-- inbox_event_acknowledgements: staff read everything (the pending view needs
-- other people's acks to compute per-user queues), write only their own row
DROP POLICY IF EXISTS authenticated_own_acknowledgements ON public.inbox_event_acknowledgements;
DROP POLICY IF EXISTS staff_read_acknowledgements      ON public.inbox_event_acknowledgements;
DROP POLICY IF EXISTS staff_write_own_acknowledgement  ON public.inbox_event_acknowledgements;
CREATE POLICY staff_read_acknowledgements ON public.inbox_event_acknowledgements
  FOR SELECT TO authenticated USING (public.is_staff());
CREATE POLICY staff_write_own_acknowledgement ON public.inbox_event_acknowledgements
  FOR ALL TO authenticated
  USING (public.is_staff() AND user_id = auth.uid())
  WITH CHECK (public.is_staff() AND user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 3. Rebuild the two views without auth.users, with invoker rights.
--    DROP + CREATE (not CREATE OR REPLACE) because `email` changes type from
--    varchar to text. Column names and order are unchanged so the UI is unaffected.
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS public.team_activity_by_user;
CREATE VIEW public.team_activity_by_user
WITH (security_invoker = on) AS
WITH reviews AS (
  SELECT reviewed_by AS user_id,
         count(*) AS inbox_reviews,
         avg(reviewed_at - created_at) AS avg_review_time
  FROM public.inbox_events
  WHERE reviewed_by IS NOT NULL
    AND reviewed_at IS NOT NULL
    AND reviewed_at >= created_at
  GROUP BY reviewed_by
), notes AS (
  SELECT created_by_user_id AS user_id, count(*) AS notes_written
  FROM public.candidate_notes
  WHERE created_by_user_id IS NOT NULL
  GROUP BY created_by_user_id
), acts AS (
  SELECT actor_id AS user_id,
         count(*) FILTER (WHERE activity_type = 'email_sent') AS emails_sent,
         count(*) FILTER (WHERE activity_type LIKE '%intro')  AS intros_made,
         count(*) AS activities
  FROM public.candidate_activities
  WHERE actor_id IS NOT NULL
  GROUP BY actor_id
), moves AS (
  SELECT actor_id AS user_id, count(*) AS funnel_moves
  FROM public.candidate_bucket_transitions
  WHERE actor_id IS NOT NULL AND from_bucket_id IS NOT NULL
  GROUP BY actor_id
)
SELECT s.user_id,
       s.email,
       COALESCE(s.display_name, p.username, p.name) AS display_name,
       COALESCE(r.inbox_reviews, 0) AS inbox_reviews,
       r.avg_review_time,
       COALESCE(n.notes_written, 0) AS notes_written,
       COALESCE(a.emails_sent, 0)   AS emails_sent,
       COALESCE(a.intros_made, 0)   AS intros_made,
       COALESCE(m.funnel_moves, 0)  AS funnel_moves,
       COALESCE(a.activities, 0)    AS total_activities
FROM public.staff s
LEFT JOIN public.profiles p ON p.id = s.user_id
LEFT JOIN reviews r ON r.user_id = s.user_id
LEFT JOIN notes   n ON n.user_id = s.user_id
LEFT JOIN acts    a ON a.user_id = s.user_id
LEFT JOIN moves   m ON m.user_id = s.user_id;

COMMENT ON VIEW public.team_activity_by_user IS
  'Per-person throughput across inbox reviews, notes, emails, intros and funnel moves. One row per staff member.';

REVOKE ALL ON public.team_activity_by_user FROM anon, authenticated;
GRANT SELECT ON public.team_activity_by_user TO authenticated, service_role;


DROP VIEW IF EXISTS public.inbox_pending_for_user;
CREATE VIEW public.inbox_pending_for_user
WITH (security_invoker = on) AS
SELECT e.event_id,
       e.event_type,
       e.candidate_id,
       e.startup_id,
       e.status,
       e.priority,
       e.metadata,
       e.created_at,
       e.updated_at,
       e.reviewed_at,
       e.reviewed_by,
       e.founder_forum_application_id,
       e.requested_programs,
       e.wants_optin,
       e.decision,
       e.decided_by,
       e.decided_at,
       e.decision_project_id,
       e.decision_note,
       s.user_id AS for_user_id,
       CASE
         WHEN e.event_type = 'startup_intro_request'     THEN 'notification'
         WHEN e.event_type = 'community_application'     THEN 'community'
         WHEN e.event_type = 'founder_forum_application' THEN 'founder_forum'
         ELSE 'application'
       END AS stream,
       (SELECT count(*) FROM public.inbox_event_inputs i WHERE i.event_id = e.event_id) AS input_count,
       (SELECT i.suggestion FROM public.inbox_event_inputs i
         WHERE i.event_id = e.event_id AND i.user_id = s.user_id) AS my_suggestion
FROM public.inbox_events e
CROSS JOIN public.staff s
WHERE CASE
        WHEN e.event_type = 'startup_intro_request' THEN NOT EXISTS (
          SELECT 1 FROM public.inbox_event_acknowledgements a
          WHERE a.event_id = e.event_id AND a.user_id = s.user_id
        )
        ELSE e.decision IS NULL
      END;

COMMENT ON VIEW public.inbox_pending_for_user IS
  'Entries still requiring attention, per staff member. Applications clear globally when decided; notifications clear individually when acknowledged.';

REVOKE ALL ON public.inbox_pending_for_user FROM anon, authenticated;
GRANT SELECT ON public.inbox_pending_for_user TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Leftover anon grants on internal objects. RLS already denies anon on all
--    of these (no anon policy exists), so this is defence in depth.
-- ----------------------------------------------------------------------------

REVOKE ALL ON TABLE
  public.analytics_daily,
  public.candidate_bucket_transitions,
  public.candidate_program_memberships,
  public.candidate_startup_intros,
  public.cohorts,
  public.founder_forum_applications,
  public.founder_forum_members,
  public.inbox_event_acknowledgements,
  public.inbox_event_inputs
FROM anon;

REVOKE ALL ON
  public.candidate_bucket_stage_durations,
  public.candidate_program_membership_details,
  public.intro_funnel_by_program,
  public.open_startup_demand,
  public.placements_by_program
FROM anon;

COMMIT;

-- ============================================================================
-- Rollback sketch (manual): drop the staff_* policies and recreate
-- authenticated_full_access USING (true) WITH CHECK (true) on each table above;
-- restore the two views from the previous definition; DROP FUNCTION is_staff();
-- DROP TABLE staff.
-- ============================================================================
