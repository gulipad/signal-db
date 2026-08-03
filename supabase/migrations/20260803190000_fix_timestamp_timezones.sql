-- ============================================================================
-- Make timestamp columns timezone-aware
-- ============================================================================
-- The schema mixes `timestamp` and `timestamptz`. Everything from the March 2025
-- initial migration used `TIMESTAMP DEFAULT NOW()` (naive); everything added
-- since uses `timestamptz`. That inconsistency silently corrupts the analytics.
--
-- analytics.sql buckets every metric with the same expression:
--
--   (created_at at time zone 'Europe/Madrid')::date
--
-- but that operator means OPPOSITE things depending on the column type:
--
--   naive      -> interprets the value AS Madrid local time and converts to UTC
--   timestamptz-> converts the instant TO Madrid local time
--
-- Demonstrated on this database:
--
--   '2026-08-03 00:30:00'::timestamp    at time zone 'Europe/Madrid'
--     -> 2026-08-02 22:30:00+00   (day = Aug 2)   <-- shifted BACKWARD, wrong day
--   '2026-08-03 00:30:00+00'::timestamptz at time zone 'Europe/Madrid'
--     -> 2026-08-03 02:30:00      (day = Aug 3)   <-- correct
--
-- So metrics sourced from naive columns are shifted the wrong way and land
-- activity in the first hours of UTC on the PREVIOUS day:
--
--   intros_sent, emails_sent   <- candidate_activities.activity_timestamp (naive)
--   new_candidates             <- candidates.created_at                   (naive)
--
-- while applications, reviews_completed, review_time_hours, funnel_additions,
-- funnel_moves and placements are correct. The dashboard therefore plots two
-- different definitions of "day" on the same axis.
--
-- ---------------------------------------------------------------------------
-- THIS IS THE ONE MIGRATION IN THE STACK THAT NEEDS APPLICATION REVIEW.
-- ---------------------------------------------------------------------------
-- The stored instants are preserved exactly (see the USING clause), but the JSON
-- PostgREST returns changes shape:
--
--   before: "2026-08-03T13:54:10.806859"
--   after:  "2026-08-03T13:54:10.806859+00:00"
--
-- JavaScript parses both, but NOT identically: `new Date()` treats a bare string
-- as LOCAL time and an offset string as absolute. For a browser outside UTC,
-- displayed times will shift by the offset -- which is the pre-existing bug being
-- corrected, not a new one. Values were always UTC; the app was rendering them as
-- if they were local. Verify date rendering on candidate and source views before
-- merging.
-- ============================================================================

-- `public_bucket_candidates` selects candidates.created_at and orders by
-- sources.created_at, and Postgres refuses to alter a column a view depends on.
-- It is dropped here and recreated verbatim at the end of the migration, with
-- security_invoker and grants restored exactly as the lockdown migration left
-- them. Captured from pg_get_viewdef on the current schema.
DROP VIEW IF EXISTS public.public_bucket_candidates;

-- All existing values were written by now() on a UTC server, so they are UTC
-- instants that merely lost their label. `AT TIME ZONE 'UTC'` re-attaches it
-- without moving anything.

ALTER TABLE public.candidates
  ALTER COLUMN created_at TYPE timestamptz USING created_at AT TIME ZONE 'UTC',
  ALTER COLUMN updated_at TYPE timestamptz USING updated_at AT TIME ZONE 'UTC';

ALTER TABLE public.candidate_activities
  ALTER COLUMN activity_timestamp TYPE timestamptz USING activity_timestamp AT TIME ZONE 'UTC',
  ALTER COLUMN created_at         TYPE timestamptz USING created_at         AT TIME ZONE 'UTC';

ALTER TABLE public.candidate_summaries
  ALTER COLUMN created_at   TYPE timestamptz USING created_at   AT TIME ZONE 'UTC',
  ALTER COLUMN generated_at TYPE timestamptz USING generated_at AT TIME ZONE 'UTC';

ALTER TABLE public.sources
  ALTER COLUMN created_at      TYPE timestamptz USING created_at      AT TIME ZONE 'UTC',
  ALTER COLUMN updated_at      TYPE timestamptz USING updated_at      AT TIME ZONE 'UTC',
  ALTER COLUMN last_scraped_at TYPE timestamptz USING last_scraped_at AT TIME ZONE 'UTC';

ALTER TABLE public.source_data
  ALTER COLUMN created_at       TYPE timestamptz USING created_at       AT TIME ZONE 'UTC',
  ALTER COLUMN scrape_timestamp TYPE timestamptz USING scrape_timestamp AT TIME ZONE 'UTC';

-- The superseded first-generation bucket tables. Converted for consistency so a
-- future reader is not misled into copying the old pattern; they are unreferenced
-- by application code.
--
-- Guarded, because these tables exist ONLY on databases built from this migration
-- set. They were dropped from the hosted project by hand and no migration records
-- it, so `to_regclass` returns NULL there and an unguarded ALTER would abort the
-- whole migration. Verified against production: both are absent.
DO $$
BEGIN
  IF to_regclass('public.buckets') IS NOT NULL THEN
    ALTER TABLE public.buckets
      ALTER COLUMN created_at TYPE timestamptz USING created_at AT TIME ZONE 'UTC';
  END IF;

  IF to_regclass('public.candidate_buckets') IS NOT NULL THEN
    ALTER TABLE public.candidate_buckets
      ALTER COLUMN assigned_at TYPE timestamptz USING assigned_at AT TIME ZONE 'UTC',
      ALTER COLUMN updated_at  TYPE timestamptz USING updated_at  AT TIME ZONE 'UTC';
  END IF;
END $$;

-- Defaults are re-asserted so new rows carry an instant rather than a naive
-- local reading. now() already returns timestamptz; the old columns were
-- implicitly downcasting it.
ALTER TABLE public.candidates          ALTER COLUMN created_at         SET DEFAULT now();
ALTER TABLE public.candidates          ALTER COLUMN updated_at         SET DEFAULT now();
ALTER TABLE public.candidate_activities ALTER COLUMN activity_timestamp SET DEFAULT now();
ALTER TABLE public.candidate_activities ALTER COLUMN created_at         SET DEFAULT now();
ALTER TABLE public.sources             ALTER COLUMN created_at         SET DEFAULT now();
ALTER TABLE public.sources             ALTER COLUMN updated_at         SET DEFAULT now();
ALTER TABLE public.source_data         ALTER COLUMN created_at         SET DEFAULT now();
ALTER TABLE public.candidate_summaries ALTER COLUMN created_at         SET DEFAULT now();

-- Recreate the view -----------------------------------------------------------
-- Identical to the definition dropped above. security_invoker and the anon
-- revoke from 20260208120000_lockdown_rls_policies.sql are reapplied so this
-- migration does not quietly widen public access.

CREATE VIEW public.public_bucket_candidates AS
 WITH latest_successful_sources AS (
         SELECT DISTINCT ON (s.candidate_id, s.source_type) s.candidate_id,
            s.source_type,
            s.source_identifier
           FROM sources s
             JOIN source_data sd ON s.source_id = sd.source_id
          WHERE sd.success = true AND (s.source_type = ANY (ARRAY['linkedin'::source_type_enum, 'github'::source_type_enum, 'personal_website'::source_type_enum]))
          ORDER BY s.candidate_id, s.source_type, s.created_at DESC
        ), candidate_social_links AS (
         SELECT latest_successful_sources.candidate_id,
            max(
                CASE
                    WHEN latest_successful_sources.source_type = 'linkedin'::source_type_enum THEN latest_successful_sources.source_identifier
                    ELSE NULL::character varying
                END::text) AS linkedin_identifier,
            max(
                CASE
                    WHEN latest_successful_sources.source_type = 'github'::source_type_enum THEN latest_successful_sources.source_identifier
                    ELSE NULL::character varying
                END::text) AS github_identifier,
            max(
                CASE
                    WHEN latest_successful_sources.source_type = 'personal_website'::source_type_enum THEN latest_successful_sources.source_identifier
                    ELSE NULL::character varying
                END::text) AS website_url
           FROM latest_successful_sources
          GROUP BY latest_successful_sources.candidate_id
        )
 SELECT pb.project_id,
    pb.bucket_id,
    p.name AS project_name,
    pb.name AS bucket_name,
    pb.public_description,
    c.candidate_id,
    c.first_name,
    c.last_name,
    c.email,
    c.candidate_slug,
    c.created_at,
    pp.tldr,
    pp.tags,
    csl.linkedin_identifier,
    csl.github_identifier,
    csl.website_url
   FROM project_buckets pb
     JOIN projects p ON pb.project_id = p.project_id
     JOIN candidate_project_buckets cpb ON pb.bucket_id = cpb.bucket_id
     JOIN candidates c ON cpb.candidate_id = c.candidate_id
     JOIN public_profiles pp ON c.candidate_id = pp.candidate_id AND pp.is_visible = true
     LEFT JOIN candidate_social_links csl ON c.candidate_id = csl.candidate_id
  WHERE pb.is_public = true;

ALTER VIEW public.public_bucket_candidates SET (security_invoker = on);

REVOKE ALL ON TABLE public.public_bucket_candidates FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.public_bucket_candidates TO authenticated, service_role;
