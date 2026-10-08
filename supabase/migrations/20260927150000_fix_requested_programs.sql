-- ============================================================================
-- FIX REQUESTED PROGRAMS ON FELLOWSHIP APPLICATIONS
--
-- 20260803280000_add_inbox_decisions set requested_programs = {fellowship} on
-- every fellowship_application as a placeholder, whatever the applicant
-- ticked. The backfill in 20260926140000 only recovered rows that were still
-- empty, so the placeholders stayed: applicants who ticked Launchpad, or both,
-- showed as "wants Fellowship" only.
--
-- Set every fellowship application's programs from the program_preferences
-- stored with it (the application source nearest in time for the candidate,
-- as in the backfill), including an empty list when they ticked neither.
-- Rows without stored preferences are left alone. Re-running is a no-op.
-- ============================================================================

BEGIN;
UPDATE public.inbox_events e
SET requested_programs = sub.programs
FROM (
  SELECT DISTINCT ON (e2.event_id)
         e2.event_id,
         ARRAY(
           SELECT p FROM unnest(ARRAY['fellowship', 'launchpad']) AS p
           WHERE (sd.json_summary->'program_preferences'->>p)::boolean
         ) AS programs
  FROM public.inbox_events e2
  JOIN public.sources s
    ON s.candidate_id = e2.candidate_id
   AND s.source_type = 'application'
   AND s.source_identifier ILIKE '%Fellowship%'
  JOIN public.source_data sd ON sd.source_id = s.source_id
  WHERE e2.event_type = 'fellowship_application'
    AND sd.json_summary ? 'program_preferences'
  ORDER BY e2.event_id, abs(extract(epoch FROM s.created_at - e2.created_at))
) sub
WHERE e.event_id = sub.event_id
  AND e.requested_programs IS DISTINCT FROM sub.programs;
COMMIT;
