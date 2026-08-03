-- ============================================================================
-- Baseline: the schema as it exists in production
-- ============================================================================
-- Generated verbatim with `supabase db dump --linked` against project
-- fgvloiinjfnpwiitnkiz on 2026-08-03. Read-only against production.
--
-- Contents match production exactly: 48 tables, 99 indexes, 101 policies,
-- 32 functions, 25 triggers (emitted as CREATE OR REPLACE TRIGGER), 2 enums.
--
-- WHY THIS REPLACES THE PREVIOUS 40 MIGRATIONS (moved to supabase/archive/):
--
-- Those files never built production. Production's migration history table held
-- only THREE records -- 20260208154236, 20260213175042, 20260213175056 -- none of
-- which match any filename in the repo. The schema was shaped by hand through the
-- dashboard and the migrations were written afterwards to describe it, so they
-- drifted in both directions:
--
--   * 22 tables existed in production that no migration created, including an
--     entire job board (jobs, job_applications, job_saves, job_tags) and a
--     community/forum app (posts, comments, votes, communities, community_*).
--   * 2 tables the migrations DID create -- buckets, candidate_buckets -- had been
--     dropped from production by hand, with no migration recording it.
--   * analytics_daily and refresh_analytics_daily existed only in production,
--     applied by hand from signal/supabase/analytics.sql.
--
-- The consequence was that `supabase db reset` could not build a working database
-- at all (it aborted at 20250326180000), so local development ran against a
-- schema that was never the real one.
--
-- From here, this file is the origin. New work goes in migrations dated after it.
-- ============================================================================



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgsodium";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."project_kind_enum" AS ENUM (
    'funnel',
    'watchlist'
);


ALTER TYPE "public"."project_kind_enum" OWNER TO "postgres";


CREATE TYPE "public"."source_type_enum" AS ENUM (
    'linkedin',
    'github',
    'personal_website',
    'application',
    'other',
    'twitter'
);


ALTER TYPE "public"."source_type_enum" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_to_default_bucket"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  default_bucket_id UUID;
BEGIN
  -- Get the default bucket ID
  SELECT bucket_id INTO default_bucket_id FROM Buckets WHERE is_default = TRUE LIMIT 1;
  
  -- If a default bucket exists, assign the new candidate to it
  IF default_bucket_id IS NOT NULL THEN
    INSERT INTO Candidate_Buckets (candidate_id, bucket_id)
    VALUES (NEW.candidate_id, default_bucket_id);
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."assign_to_default_bucket"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."candidate_slug_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.candidate_slug IS NULL THEN
    NEW.candidate_slug := generate_candidate_slug(NEW.first_name, NEW.last_name, NEW.candidate_id);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."candidate_slug_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_candidate"("p_candidate_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    DELETE FROM public.candidate_activities
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate notes
    DELETE FROM public.candidate_notes
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate tags
    DELETE FROM public.candidate_tags
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate project buckets
    DELETE FROM public.candidate_project_buckets
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate summaries
    DELETE FROM public.candidate_summaries
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate availability
    DELETE FROM public.candidate_availability
    WHERE candidate_id = p_candidate_id;

    -- Delete source data (must be deleted before sources)
    DELETE FROM public.source_data
    WHERE source_id IN (
        SELECT source_id 
        FROM public.sources 
        WHERE candidate_id = p_candidate_id
    );

    -- Delete candidate sources
    DELETE FROM public.sources
    WHERE candidate_id = p_candidate_id;

    -- Finally delete the candidate
    DELETE FROM public.candidates
    WHERE candidate_id = p_candidate_id;
END;
$$;


ALTER FUNCTION "public"."delete_candidate"("p_candidate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_candidate_slug"("first_name" "text", "last_name" "text", "candidate_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $_$
DECLARE
  base_slug TEXT;
  final_slug TEXT;
  counter INTEGER := 1;
BEGIN
  -- Create base slug from name (or use candidate_id prefix if no name)
  IF first_name IS NOT NULL OR last_name IS NOT NULL THEN
    -- First unaccent the names to convert accented characters to their ASCII equivalents
    base_slug := LOWER(
      REGEXP_REPLACE(
        UNACCENT(COALESCE(first_name, '')) || '-' || UNACCENT(COALESCE(last_name, '')),
        '[^a-zA-Z0-9]', '-', 'g'
      )
    );
    -- Remove consecutive dashes and trim
    base_slug := REGEXP_REPLACE(base_slug, '-+', '-', 'g');
    base_slug := REGEXP_REPLACE(base_slug, '^-|-$', '', 'g');
  ELSE
    -- Fallback to using candidate_id prefix if no name available
    base_slug := 'candidate-' || SUBSTRING(candidate_id::TEXT, 1, 8);
  END IF;
  
  -- Check if the slug already exists and append counter if needed
  final_slug := base_slug;
  WHILE EXISTS (SELECT 1 FROM public.candidates WHERE candidate_slug = final_slug) LOOP
    counter := counter + 1;
    final_slug := base_slug || '-' || counter::TEXT;
  END LOOP;
  
  RETURN final_slug;
END;
$_$;


ALTER FUNCTION "public"."generate_candidate_slug"("first_name" "text", "last_name" "text", "candidate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_slug"("title" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN LOWER(
        REGEXP_REPLACE(
            REGEXP_REPLACE(
                TRIM(title),
                '[^a-zA-Z0-9\s-]', '', 'g'
            ),
            '\s+', '-', 'g'
        )
    );
END;
$$;


ALTER FUNCTION "public"."generate_slug"("title" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_community_type"("p_community_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_type TEXT;
BEGIN
    SELECT type INTO v_type FROM communities WHERE id = p_community_id;
    RETURN v_type;
END;
$$;


ALTER FUNCTION "public"."get_community_type"("p_community_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_roles"("user_id" "uuid") RETURNS TABLE("role_name" "text", "display_name" "text", "assigned_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT r.name, r.display_name, ur.assigned_at
  FROM user_roles ur
  JOIN roles r ON ur.role_id = r.id
  WHERE ur.user_id = user_id
    AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
  ORDER BY ur.assigned_at;
END;
$$;


ALTER FUNCTION "public"."get_user_roles"("user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  INSERT INTO public.profiles (id, email, role)
  VALUES (NEW.id, NEW.email, 'user')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_job_application_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE jobs 
  SET application_count = application_count + 1 
  WHERE id = NEW.job_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."increment_job_application_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_community_admin"("community_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM community_memberships
        WHERE community_id = community_uuid
        AND user_id = auth.uid()
        AND role = 'admin'
    );
END;
$$;


ALTER FUNCTION "public"."is_community_admin"("community_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_community_admin"("p_community_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM community_memberships
        WHERE community_id = p_community_id
        AND user_id = p_user_id
        AND role = 'admin'
    );
END;
$$;


ALTER FUNCTION "public"."is_community_admin"("p_community_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_community_member"("p_community_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM community_memberships
        WHERE community_id = p_community_id
        AND user_id = p_user_id
    );
END;
$$;


ALTER FUNCTION "public"."is_community_member"("p_community_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_community_moderator"("community_uuid" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM community_memberships
        WHERE community_id = community_uuid
        AND user_id = auth.uid()
        AND role IN ('moderator', 'admin')
    );
END;
$$;


ALTER FUNCTION "public"."is_community_moderator"("community_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_community_moderator"("p_community_id" "uuid", "p_user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM community_memberships
        WHERE community_id = p_community_id
        AND user_id = p_user_id
        AND role IN ('moderator', 'admin')
    );
END;
$$;


ALTER FUNCTION "public"."is_community_moderator"("p_community_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_user_banned"("p_user_id" "uuid", "p_community_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    ban_record RECORD;
BEGIN
    SELECT * INTO ban_record
    FROM community_bans
    WHERE user_id = p_user_id
    AND community_id = p_community_id
    LIMIT 1;
    
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    
    -- Check if permanent ban
    IF ban_record.is_permanent THEN
        RETURN TRUE;
    END IF;
    
    -- Check if temporary ban has expired
    IF ban_record.expires_at IS NOT NULL AND ban_record.expires_at < NOW() THEN
        -- Ban has expired, delete it
        DELETE FROM community_bans WHERE id = ban_record.id;
        RETURN FALSE;
    END IF;
    
    RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."is_user_banned"("p_user_id" "uuid", "p_community_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_analytics_daily"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Las series se recalculan enteras desde las tablas fuente. Los snapshots
  -- bucket_count de dias anteriores NO se pueden reconstruir: se conservan
  -- como historico y solo se recalcula el del dia actual.
  delete from public.analytics_daily
  where metric <> 'bucket_count'
     or metric_date = (now() at time zone 'Europe/Madrid')::date;

  -- Aplicaciones recibidas por tipo (inbox_events)
  insert into public.analytics_daily (metric_date, metric, dimension, value)
  select (created_at at time zone 'Europe/Madrid')::date,
         'applications', event_type, count(*)
  from public.inbox_events
  group by 1, 3;

  -- Intros de fellows a startups
  insert into public.analytics_daily (metric_date, metric, value)
  select (activity_timestamp at time zone 'Europe/Madrid')::date,
         'intros_sent', count(*)
  from public.candidate_activities
  where activity_type = 'candidate_startup_intro'
  group by 1;

  -- Emails enviados
  insert into public.analytics_daily (metric_date, metric, value)
  select (activity_timestamp at time zone 'Europe/Madrid')::date,
         'emails_sent', count(*)
  from public.candidate_activities
  where activity_type = 'email_sent'
  group by 1;

  -- Placements
  insert into public.analytics_daily (metric_date, metric, value)
  select (created_at at time zone 'Europe/Madrid')::date,
         'placements', count(*)
  from public.candidate_startup_placements
  group by 1;

  -- Candidatos nuevos
  insert into public.analytics_daily (metric_date, metric, value)
  select (created_at at time zone 'Europe/Madrid')::date,
         'new_candidates', count(*)
  from public.candidates
  group by 1;

  -- Eventos revisados y tiempo medio de revision (por dia de revision)
  insert into public.analytics_daily (metric_date, metric, value)
  select (reviewed_at at time zone 'Europe/Madrid')::date,
         'reviews_completed', count(*)
  from public.inbox_events
  where reviewed_at is not null and reviewed_at >= created_at
  group by 1;

  insert into public.analytics_daily (metric_date, metric, value)
  select (reviewed_at at time zone 'Europe/Madrid')::date,
         'review_time_hours',
         round(avg(extract(epoch from (reviewed_at - created_at)) / 3600.0)::numeric, 2)
  from public.inbox_events
  where reviewed_at is not null and reviewed_at >= created_at
  group by 1;

  -- Candidatos anyadidos a cada funnel
  insert into public.analytics_daily (metric_date, metric, dimension, value)
  select (cpb.created_at at time zone 'Europe/Madrid')::date,
         'funnel_additions', p.name, count(*)
  from public.candidate_project_buckets cpb
  join public.projects p on p.project_id = cpb.project_id
  where p.kind = 'funnel'
  group by 1, 3;

  -- Movimientos en el funnel (proxy: el UPDATE de bucket es in-place, asi que
  -- solo sobrevive el ultimo movimiento de cada asignacion)
  insert into public.analytics_daily (metric_date, metric, dimension, value)
  select (cpb.updated_at at time zone 'Europe/Madrid')::date,
         'funnel_moves', p.name, count(*)
  from public.candidate_project_buckets cpb
  join public.projects p on p.project_id = cpb.project_id
  where p.kind = 'funnel'
    and cpb.updated_at is not null
    and cpb.updated_at <> cpb.created_at
  group by 1, 3;

  -- Snapshot de distribucion actual por bucket (solo funnels), con fecha del
  -- dia del run. Los sets de dias anteriores se conservan como historico.
  insert into public.analytics_daily (metric_date, metric, dimension, value, meta)
  select (now() at time zone 'Europe/Madrid')::date,
         'bucket_count',
         p.name || '|' || pb.name,
         count(cpb.id),
         jsonb_build_object(
           'project_id', p.project_id,
           'bucket_id', pb.bucket_id,
           'order_index', pb.order_index,
           'is_rejection_column', pb.is_rejection_column
         )
  from public.project_buckets pb
  join public.projects p on p.project_id = pb.project_id
  left join public.candidate_project_buckets cpb on cpb.bucket_id = pb.bucket_id
  where p.kind = 'funnel'
  group by p.project_id, p.name, pb.bucket_id, pb.name, pb.order_index, pb.is_rejection_column;
end;
$$;


ALTER FUNCTION "public"."refresh_analytics_daily"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_job_published_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.status = 'published' AND OLD.status != 'published' AND NEW.published_at IS NULL THEN
    NEW.published_at = NOW();
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_job_published_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_comment_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE posts SET comment_count = comment_count + 1 WHERE id = NEW.post_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE posts SET comment_count = comment_count - 1 WHERE id = OLD.post_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_comment_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_community_member_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE communities 
        SET member_count = member_count + 1,
            updated_at = NOW()
        WHERE id = NEW.community_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE communities 
        SET member_count = GREATEST(member_count - 1, 0),
            updated_at = NOW()
        WHERE id = OLD.community_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_community_member_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_community_post_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.community_id IS NOT NULL THEN
        UPDATE communities 
        SET post_count = post_count + 1,
            updated_at = NOW()
        WHERE id = NEW.community_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' AND OLD.community_id IS NOT NULL THEN
        UPDATE communities 
        SET post_count = GREATEST(post_count - 1, 0),
            updated_at = NOW()
        WHERE id = OLD.community_id;
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Handle community change
        IF OLD.community_id IS DISTINCT FROM NEW.community_id THEN
            IF OLD.community_id IS NOT NULL THEN
                UPDATE communities 
                SET post_count = GREATEST(post_count - 1, 0),
                    updated_at = NOW()
                WHERE id = OLD.community_id;
            END IF;
            IF NEW.community_id IS NOT NULL THEN
                UPDATE communities 
                SET post_count = post_count + 1,
                    updated_at = NOW()
                WHERE id = NEW.community_id;
            END IF;
        END IF;
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_community_post_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_inbox_events_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_inbox_events_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_post_comment_count"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE posts 
        SET comment_count = comment_count + 1
        WHERE id = NEW.post_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE posts 
        SET comment_count = GREATEST(comment_count - 1, 0)
        WHERE id = OLD.post_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."update_post_comment_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_post_score"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Only update if this is a post vote (not a comment vote)
  IF COALESCE(NEW.post_id, OLD.post_id) IS NOT NULL THEN
    UPDATE posts
    SET score = upvotes - downvotes
    WHERE id = COALESCE(NEW.post_id, OLD.post_id);
  END IF;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;


ALTER FUNCTION "public"."update_post_score"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_public_profiles_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_public_profiles_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_push_tokens_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_push_tokens_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_roles_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_roles_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_karma"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  author_user_id UUID;
  karma_change INTEGER;
BEGIN
  IF NEW.post_id IS NOT NULL THEN
    SELECT author_id INTO author_user_id FROM posts WHERE id = NEW.post_id;
  ELSIF NEW.comment_id IS NOT NULL THEN
    SELECT author_id INTO author_user_id FROM comments WHERE id = NEW.comment_id;
  END IF;

  IF author_user_id IS NOT NULL THEN
    karma_change := CASE WHEN NEW.vote_type = 'upvote' THEN 1 ELSE 0 END;
    UPDATE profiles
    SET karma = GREATEST(0, karma + karma_change)
    WHERE id = author_user_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_user_karma"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_karma_on_vote_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  author_user_id UUID;
  old_karma_change INTEGER;
  new_karma_change INTEGER;
  net_karma_change INTEGER;
BEGIN
  IF COALESCE(NEW.post_id, OLD.post_id) IS NOT NULL THEN
    SELECT author_id INTO author_user_id FROM posts WHERE id = COALESCE(NEW.post_id, OLD.post_id);
  ELSIF COALESCE(NEW.comment_id, OLD.comment_id) IS NOT NULL THEN
    SELECT author_id INTO author_user_id FROM comments WHERE id = COALESCE(NEW.comment_id, OLD.comment_id);
  END IF;

  IF author_user_id IS NOT NULL THEN
    old_karma_change := CASE WHEN OLD.vote_type = 'upvote' THEN 1 ELSE 0 END;
    new_karma_change := CASE WHEN NEW.vote_type = 'upvote' THEN 1 ELSE 0 END;
    net_karma_change := new_karma_change - old_karma_change;
    UPDATE profiles
    SET karma = GREATEST(0, karma + net_karma_change)
    WHERE id = author_user_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_user_karma_on_vote_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_karma_on_vote_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  author_user_id UUID;
  karma_change INTEGER;
BEGIN
  IF OLD.post_id IS NOT NULL THEN
    SELECT author_id INTO author_user_id FROM posts WHERE id = OLD.post_id;
  ELSIF OLD.comment_id IS NOT NULL THEN
    SELECT author_id INTO author_user_id FROM comments WHERE id = OLD.comment_id;
  END IF;

  IF author_user_id IS NOT NULL THEN
    karma_change := CASE WHEN OLD.vote_type = 'upvote' THEN -1 ELSE 0 END;
    UPDATE profiles
    SET karma = GREATEST(0, karma + karma_change)
    WHERE id = author_user_id;
  END IF;

  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."update_user_karma_on_vote_delete"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_has_role"("user_id" "uuid", "role_name" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN roles r ON ur.role_id = r.id
    WHERE ur.user_id = user_id
      AND r.name = role_name
      AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
  );
END;
$$;


ALTER FUNCTION "public"."user_has_role"("user_id" "uuid", "role_name" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."analytics_daily" (
    "metric_date" "date" NOT NULL,
    "metric" "text" NOT NULL,
    "dimension" "text" DEFAULT ''::"text" NOT NULL,
    "value" numeric DEFAULT 0 NOT NULL,
    "meta" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."analytics_daily" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_activities" (
    "activity_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "activity_type" "text" NOT NULL,
    "activity_timestamp" timestamp without time zone DEFAULT "now"() NOT NULL,
    "actor_id" "uuid",
    "metadata" "jsonb",
    "project_id" "uuid",
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "candidate_activities_activity_type_check" CHECK (("activity_type" = ANY (ARRAY['bucket_assignment'::"text", 'availability_change'::"text", 'source_update'::"text", 'email_sent'::"text", 'candidate_startup_intro'::"text"])))
);


ALTER TABLE "public"."candidate_activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_availability" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "available_from" "date" NOT NULL,
    "unavailability_reason" character varying(20),
    "reason_details" "text",
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "created_by" "text",
    CONSTRAINT "candidate_availability_unavailability_reason_check" CHECK ((("unavailability_reason")::"text" = ANY ((ARRAY['STUDYING'::character varying, 'CURRENT_JOB'::character varying, 'OTHER'::character varying])::"text"[])))
);


ALTER TABLE "public"."candidate_availability" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "text",
    "creator_avatar_url" "text"
);


ALTER TABLE "public"."candidate_notes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."candidate_notes"."created_by" IS 'GitHub username of the user who created the note.';



COMMENT ON COLUMN "public"."candidate_notes"."creator_avatar_url" IS 'URL of the GitHub avatar of the user who created the note.';



CREATE TABLE IF NOT EXISTS "public"."candidate_project_buckets" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "bucket_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."candidate_project_buckets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_rejection_reasons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "bucket_id" "uuid" NOT NULL,
    "reason_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."candidate_rejection_reasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_startup_placements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "startup_id" "uuid" NOT NULL,
    "role_title" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."candidate_startup_placements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_summaries" (
    "candidate_summary_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid",
    "generated_at" timestamp without time zone NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "success" boolean DEFAULT true,
    "sources_used" "jsonb",
    "recommended_tags" "jsonb",
    "json_summary" "jsonb",
    "analysis_version" "text"
);


ALTER TABLE "public"."candidate_summaries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidate_tags" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."candidate_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."candidates" (
    "candidate_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "first_name" character varying(128),
    "last_name" character varying(128),
    "email" character varying(255),
    "phone" character varying(20),
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "launchpad_optin" boolean DEFAULT false,
    "candidate_slug" "text"
);


ALTER TABLE "public"."candidates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."column_email_associations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_bucket_id" "uuid" NOT NULL,
    "email_template_id" "uuid" NOT NULL,
    "order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."column_email_associations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "parent_id" "uuid",
    "content" "text" NOT NULL,
    "upvotes" integer DEFAULT 0,
    "downvotes" integer DEFAULT 0,
    "score" integer DEFAULT 0,
    "depth" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_removed" boolean DEFAULT false NOT NULL,
    "removed_by" "uuid",
    "removed_at" timestamp with time zone,
    "removal_reason" "text"
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."communities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "icon_url" "text",
    "banner_url" "text",
    "theme_color" "text" DEFAULT '#6366f1'::"text",
    "type" "text" DEFAULT 'public'::"text" NOT NULL,
    "is_nsfw" boolean DEFAULT false NOT NULL,
    "requires_auth" boolean DEFAULT false NOT NULL,
    "member_count" integer DEFAULT 0 NOT NULL,
    "post_count" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "communities_type_check" CHECK (("type" = ANY (ARRAY['public'::"text", 'restricted'::"text", 'private'::"text"])))
);


ALTER TABLE "public"."communities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_bans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "community_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "banned_by" "uuid",
    "reason" "text",
    "is_permanent" boolean DEFAULT true NOT NULL,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."community_bans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_flairs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "community_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" DEFAULT '#6366f1'::"text" NOT NULL,
    "background_color" "text" DEFAULT '#e0e7ff'::"text",
    "is_user_selectable" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."community_flairs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_memberships" (
    "user_id" "uuid" NOT NULL,
    "community_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text" NOT NULL,
    "notify_posts" boolean DEFAULT false NOT NULL,
    "notify_comments" boolean DEFAULT false NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "community_memberships_role_check" CHECK (("role" = ANY (ARRAY['member'::"text", 'moderator'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."community_memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_mod_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "community_id" "uuid" NOT NULL,
    "moderator_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "reason" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "community_mod_actions_action_type_check" CHECK (("action_type" = ANY (ARRAY['remove_post'::"text", 'restore_post'::"text", 'lock_post'::"text", 'unlock_post'::"text", 'pin_post'::"text", 'unpin_post'::"text", 'remove_comment'::"text", 'restore_comment'::"text", 'ban_user'::"text", 'unban_user'::"text", 'add_moderator'::"text", 'remove_moderator'::"text", 'update_settings'::"text"]))),
    CONSTRAINT "community_mod_actions_target_type_check" CHECK (("target_type" = ANY (ARRAY['post'::"text", 'comment'::"text", 'user'::"text", 'community'::"text"])))
);


ALTER TABLE "public"."community_mod_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."community_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "community_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."community_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contacts" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "startup_id" "uuid" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text",
    "role" "text",
    "phone" "text",
    "linkedin_id" "text",
    "is_primary" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contacts_email_check" CHECK (("email" ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'::"text")),
    CONSTRAINT "contacts_first_name_check" CHECK (("length"(TRIM(BOTH FROM "first_name")) > 0)),
    CONSTRAINT "contacts_last_name_check" CHECK (("length"(TRIM(BOTH FROM "last_name")) > 0))
);


ALTER TABLE "public"."contacts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."email_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" character varying(255) NOT NULL,
    "subject" "text" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."email_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "api_id" "text" NOT NULL,
    "name" "text",
    "url" "text",
    "cover_url" "text",
    "start_at" timestamp with time zone,
    "end_at" timestamp with time zone,
    "timezone" "text",
    "data" "jsonb" NOT NULL,
    "scraped_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."feature_banners" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message" "text" NOT NULL,
    "is_enabled" boolean DEFAULT false,
    "start_at" timestamp with time zone,
    "end_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."feature_banners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fellows" (
    "id" "uuid" NOT NULL,
    "cohort" "text",
    "cohort_start_date" "date",
    "cohort_end_date" "date",
    "specialization" "text",
    "current_company" "text",
    "linkedin_url" "text",
    "github_url" "text",
    "portfolio_url" "text",
    "status" "text" DEFAULT 'active'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "fellows_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'graduated'::"text", 'alumni'::"text"])))
);


ALTER TABLE "public"."fellows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."founder_forum_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "member_id" "uuid" NOT NULL,
    "startup_id" "uuid",
    "role" "text" NOT NULL,
    "title" "text" NOT NULL,
    "company_website" "text" NOT NULL,
    "capital_raised" "text" NOT NULL,
    "revenue_range" "text" NOT NULL,
    "investor_websites" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "referred_by" "text",
    "discovery_channel" "text",
    "status" "text" DEFAULT 'applied'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "founder_forum_applications_capital_raised_check" CHECK (("capital_raised" = ANY (ARRAY['Bootstrapped'::"text", '<1M€'::"text", '1-5M€'::"text", '5-10M€'::"text", '10-50M€'::"text", '+50M€'::"text"]))),
    CONSTRAINT "founder_forum_applications_discovery_channel_check" CHECK (("discovery_channel" = ANY (ARRAY['LinkedIn'::"text", 'Boca a boca'::"text", 'Búsqueda'::"text", 'Twitter'::"text", 'Reddit'::"text", 'ChatGPT & otros'::"text"]))),
    CONSTRAINT "founder_forum_applications_revenue_range_check" CHECK (("revenue_range" = ANY (ARRAY['Pre-revenue'::"text", '<1M€'::"text", '1-5M€'::"text", '5-10M€'::"text", '10-50M€'::"text", '+50M€'::"text"]))),
    CONSTRAINT "founder_forum_applications_role_check" CHECK (("role" = ANY (ARRAY['Fundador'::"text", 'Co-fundador'::"text", 'Otro'::"text"]))),
    CONSTRAINT "founder_forum_applications_status_check" CHECK (("status" = ANY (ARRAY['applied'::"text", 'accepted'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."founder_forum_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."founder_forum_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "phone_country_code" "text" NOT NULL,
    "phone_dial_code" "text" NOT NULL,
    "phone_local_number" "text" NOT NULL,
    "phone_full" "text" NOT NULL,
    "linkedin" "text" NOT NULL,
    "twitter" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."founder_forum_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hero_pill" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "text" "text" NOT NULL,
    "url" "text" NOT NULL,
    "image" "text",
    "active" boolean DEFAULT true NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hero_pill" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inbox_events" (
    "event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "candidate_id" "uuid",
    "startup_id" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "priority" integer DEFAULT 0,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "founder_forum_application_id" "uuid",
    CONSTRAINT "inbox_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['fellowship_application'::"text", 'community_application'::"text", 'startup_intro_request'::"text", 'manual_addition'::"text", 'founder_forum_application'::"text"]))),
    CONSTRAINT "inbox_events_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'reviewed'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."inbox_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "applicant_id" "uuid" NOT NULL,
    "cover_letter" "text",
    "resume_url" "text",
    "portfolio_url" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "internal_notes" "text",
    "applied_at" timestamp with time zone DEFAULT "now"(),
    "reviewed_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "job_applications_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'reviewing'::"text", 'shortlisted'::"text", 'interviewing'::"text", 'offered'::"text", 'accepted'::"text", 'rejected'::"text", 'withdrawn'::"text"])))
);


ALTER TABLE "public"."job_applications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_saves" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "saved_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."job_saves" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."job_tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "tag_id" "uuid" NOT NULL
);


ALTER TABLE "public"."job_tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jobs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "posted_by" "uuid" NOT NULL,
    "startup_id" "uuid",
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "job_type" "text" NOT NULL,
    "location_type" "text" NOT NULL,
    "location" "text",
    "salary_min" integer,
    "salary_max" integer,
    "salary_currency" "text" DEFAULT 'USD'::"text",
    "equity_min" numeric(5,2),
    "equity_max" numeric(5,2),
    "experience_level" "text",
    "required_skills" "text"[],
    "nice_to_have_skills" "text"[],
    "application_url" "text",
    "application_email" "text",
    "allow_internal_applications" boolean DEFAULT true,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "is_featured" boolean DEFAULT false NOT NULL,
    "view_count" integer DEFAULT 0,
    "application_count" integer DEFAULT 0,
    "published_at" timestamp with time zone,
    "closes_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "feature_level" smallint DEFAULT 0 NOT NULL,
    CONSTRAINT "jobs_experience_level_check" CHECK (("experience_level" = ANY (ARRAY['entry'::"text", 'mid'::"text", 'senior'::"text", 'lead'::"text", 'executive'::"text"]))),
    CONSTRAINT "jobs_feature_level_check" CHECK ((("feature_level" >= 0) AND ("feature_level" <= 5))),
    CONSTRAINT "jobs_job_type_check" CHECK (("job_type" = ANY (ARRAY['full_time'::"text", 'part_time'::"text", 'contract'::"text", 'internship'::"text", 'freelance'::"text"]))),
    CONSTRAINT "jobs_location_type_check" CHECK (("location_type" = ANY (ARRAY['remote'::"text", 'onsite'::"text", 'hybrid'::"text"]))),
    CONSTRAINT "jobs_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'closed'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "content" "text",
    "url" "text",
    "post_type" "text" DEFAULT 'text'::"text",
    "upvotes" integer DEFAULT 0,
    "downvotes" integer DEFAULT 0,
    "score" integer DEFAULT 0,
    "comment_count" integer DEFAULT 0,
    "featured" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "community_id" "uuid",
    "flair_id" "uuid",
    "slug" "text",
    "is_pinned" boolean DEFAULT false NOT NULL,
    "is_removed" boolean DEFAULT false NOT NULL,
    "removed_by" "uuid",
    "removed_at" timestamp with time zone,
    "removal_reason" "text",
    CONSTRAINT "posts_post_type_check" CHECK (("post_type" = ANY (ARRAY['text'::"text", 'link'::"text", 'ask'::"text"])))
);


ALTER TABLE "public"."posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "username" "text",
    "bio" "text",
    "avatar_url" "text",
    "role" "text" DEFAULT 'user'::"text" NOT NULL,
    "startup_id" "uuid",
    "karma" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "name" "text",
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['user'::"text", 'fellow'::"text", 'startup'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."programs" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "programs_name_check" CHECK (("length"(TRIM(BOTH FROM "name")) > 0))
);


ALTER TABLE "public"."programs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_buckets" (
    "bucket_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "order_index" integer NOT NULL,
    "color" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_rejection_column" boolean DEFAULT false NOT NULL,
    "public_description" "text",
    "is_public" boolean DEFAULT false,
    "public_password" "text"
);


ALTER TABLE "public"."project_buckets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."projects" (
    "project_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "order_index" integer DEFAULT 0 NOT NULL,
    "is_deprecated" boolean DEFAULT false NOT NULL,
    "kind" "public"."project_kind_enum" DEFAULT 'funnel'::"public"."project_kind_enum" NOT NULL
);


ALTER TABLE "public"."projects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."public_profiles" (
    "profile_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid" NOT NULL,
    "is_visible" boolean DEFAULT false NOT NULL,
    "tldr" "text",
    "tags" "jsonb" DEFAULT '[]'::"jsonb",
    "projects" "jsonb" DEFAULT '[]'::"jsonb",
    "additional_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "referrals" "jsonb" DEFAULT '[]'::"jsonb"
);


ALTER TABLE "public"."public_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."source_data" (
    "data_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_id" "uuid",
    "json_summary" "jsonb" NOT NULL,
    "scrape_timestamp" timestamp without time zone NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "success" boolean
);


ALTER TABLE "public"."source_data" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sources" (
    "source_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "candidate_id" "uuid",
    "source_type" "public"."source_type_enum" NOT NULL,
    "source_identifier" character varying(255) NOT NULL,
    "last_scraped_at" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."sources" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_bucket_candidates" WITH ("security_invoker"='on') AS
 WITH "latest_successful_sources" AS (
         SELECT DISTINCT ON ("s"."candidate_id", "s"."source_type") "s"."candidate_id",
            "s"."source_type",
            "s"."source_identifier"
           FROM ("public"."sources" "s"
             JOIN "public"."source_data" "sd" ON (("s"."source_id" = "sd"."source_id")))
          WHERE (("sd"."success" = true) AND ("s"."source_type" = ANY (ARRAY['linkedin'::"public"."source_type_enum", 'github'::"public"."source_type_enum", 'personal_website'::"public"."source_type_enum"])))
          ORDER BY "s"."candidate_id", "s"."source_type", "s"."created_at" DESC
        ), "candidate_social_links" AS (
         SELECT "latest_successful_sources"."candidate_id",
            "max"((
                CASE
                    WHEN ("latest_successful_sources"."source_type" = 'linkedin'::"public"."source_type_enum") THEN "latest_successful_sources"."source_identifier"
                    ELSE NULL::character varying
                END)::"text") AS "linkedin_identifier",
            "max"((
                CASE
                    WHEN ("latest_successful_sources"."source_type" = 'github'::"public"."source_type_enum") THEN "latest_successful_sources"."source_identifier"
                    ELSE NULL::character varying
                END)::"text") AS "github_identifier",
            "max"((
                CASE
                    WHEN ("latest_successful_sources"."source_type" = 'personal_website'::"public"."source_type_enum") THEN "latest_successful_sources"."source_identifier"
                    ELSE NULL::character varying
                END)::"text") AS "website_url"
           FROM "latest_successful_sources"
          GROUP BY "latest_successful_sources"."candidate_id"
        )
 SELECT "pb"."project_id",
    "pb"."bucket_id",
    "p"."name" AS "project_name",
    "pb"."name" AS "bucket_name",
    "pb"."public_description",
    "c"."candidate_id",
    "c"."first_name",
    "c"."last_name",
    "c"."email",
    "c"."candidate_slug",
    "c"."created_at",
    "pp"."tldr",
    "pp"."tags",
    "csl"."linkedin_identifier",
    "csl"."github_identifier",
    "csl"."website_url"
   FROM ((((("public"."project_buckets" "pb"
     JOIN "public"."projects" "p" ON (("pb"."project_id" = "p"."project_id")))
     JOIN "public"."candidate_project_buckets" "cpb" ON (("pb"."bucket_id" = "cpb"."bucket_id")))
     JOIN "public"."candidates" "c" ON (("cpb"."candidate_id" = "c"."candidate_id")))
     JOIN "public"."public_profiles" "pp" ON ((("c"."candidate_id" = "pp"."candidate_id") AND ("pp"."is_visible" = true))))
     LEFT JOIN "candidate_social_links" "csl" ON (("c"."candidate_id" = "csl"."candidate_id")))
  WHERE ("pb"."is_public" = true);


ALTER TABLE "public"."public_bucket_candidates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "device_id" "text",
    "platform" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "push_tokens_platform_check" CHECK (("platform" = ANY (ARRAY['ios'::"text", 'android'::"text"])))
);


ALTER TABLE "public"."push_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rejection_reasons" (
    "reason_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."rejection_reasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "is_system_role" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."startup_programs" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "startup_id" "uuid" NOT NULL,
    "program_id" "uuid" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'active'::"text",
    CONSTRAINT "startup_programs_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'graduated'::"text", 'dropped'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."startup_programs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."startups" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "hq_city" "text",
    "hq_country" "text",
    "remote_friendly" boolean DEFAULT true,
    "founded_year" smallint,
    "funding_stage" "text",
    "total_funding_usd" numeric(14,2),
    "employees_min" smallint,
    "employees_max" smallint,
    "website_url" "text",
    "hiring_page_url" "text",
    "logo_url" "text",
    "tldr" "text",
    "long_description" "text",
    "industry_tags" "text"[] DEFAULT '{}'::"text"[],
    "tech_stack" "text"[] DEFAULT '{}'::"text"[],
    "visible" boolean DEFAULT true,
    "last_contacted_at" timestamp with time zone,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "opportunity" "text",
    "export_to_website" boolean DEFAULT true,
    "hq_latitude" double precision,
    "hq_longitude" double precision,
    CONSTRAINT "startups_check" CHECK (("employees_max" >= "employees_min")),
    CONSTRAINT "startups_employees_min_check" CHECK (("employees_min" >= 0)),
    CONSTRAINT "startups_founded_year_check" CHECK ((("founded_year" > 1800) AND (("founded_year")::numeric <= (EXTRACT(year FROM CURRENT_DATE) + (1)::numeric)))),
    CONSTRAINT "startups_funding_stage_check" CHECK (("funding_stage" = ANY (ARRAY['pre-seed'::"text", 'seed'::"text", 'series-a'::"text", 'series-b'::"text", 'series-c'::"text", 'series-d'::"text", 'growth'::"text", 'ipo'::"text", 'acquired'::"text"]))),
    CONSTRAINT "startups_tldr_check" CHECK (("length"("tldr") <= 500)),
    CONSTRAINT "startups_total_funding_usd_check" CHECK (("total_funding_usd" >= (0)::numeric))
);


ALTER TABLE "public"."startups" OWNER TO "postgres";


COMMENT ON COLUMN "public"."startups"."opportunity" IS 'Type of program opportunity (e.g., fellowship, baby_fellowship)';



COMMENT ON COLUMN "public"."startups"."export_to_website" IS 'Whether this startup should be exported to the public website';



CREATE TABLE IF NOT EXISTS "public"."tags" (
    "tag_id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "name" character varying NOT NULL,
    "color" character varying,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_role" boolean DEFAULT false,
    "role_prompt" "text"
);


ALTER TABLE "public"."tags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."testimonials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "testimonial_type" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "role" "text" NOT NULL,
    "company" "text" NOT NULL,
    "company_website" "text",
    "avatar" "text",
    "quote_english" "text",
    "quote_spanish" "text",
    "website" "text",
    "linkedin_slug" "text",
    "x_slug" "text",
    "github_slug" "text",
    "display_order" integer DEFAULT 0 NOT NULL,
    "published" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "testimonials_testimonial_type_check" CHECK (("testimonial_type" = ANY (ARRAY['community_member'::"text", 'fellow'::"text", 'industry_leader'::"text"])))
);


ALTER TABLE "public"."testimonials" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "assigned_by" "uuid",
    "assigned_at" timestamp with time zone DEFAULT "now"(),
    "expires_at" timestamp with time zone,
    "metadata" "jsonb"
);


ALTER TABLE "public"."user_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."votes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "post_id" "uuid",
    "comment_id" "uuid",
    "vote_type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "votes_check" CHECK (((("post_id" IS NOT NULL) AND ("comment_id" IS NULL)) OR (("post_id" IS NULL) AND ("comment_id" IS NOT NULL)))),
    CONSTRAINT "votes_vote_type_check" CHECK (("vote_type" = ANY (ARRAY['upvote'::"text", 'downvote'::"text"])))
);


ALTER TABLE "public"."votes" OWNER TO "postgres";


ALTER TABLE ONLY "public"."analytics_daily"
    ADD CONSTRAINT "analytics_daily_pkey" PRIMARY KEY ("metric_date", "metric", "dimension");



ALTER TABLE ONLY "public"."candidate_activities"
    ADD CONSTRAINT "candidate_activities_pkey" PRIMARY KEY ("activity_id");



ALTER TABLE ONLY "public"."candidate_availability"
    ADD CONSTRAINT "candidate_availability_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_notes"
    ADD CONSTRAINT "candidate_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_project_buckets"
    ADD CONSTRAINT "candidate_project_buckets_candidate_id_project_id_key" UNIQUE ("candidate_id", "project_id");



ALTER TABLE ONLY "public"."candidate_project_buckets"
    ADD CONSTRAINT "candidate_project_buckets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_rejection_reasons"
    ADD CONSTRAINT "candidate_rejection_reasons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_startup_placements"
    ADD CONSTRAINT "candidate_startup_placements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_startup_placements"
    ADD CONSTRAINT "candidate_startup_placements_unique" UNIQUE ("candidate_id", "startup_id");



ALTER TABLE ONLY "public"."candidate_summaries"
    ADD CONSTRAINT "candidate_summaries_pkey" PRIMARY KEY ("candidate_summary_id");



ALTER TABLE ONLY "public"."candidate_tags"
    ADD CONSTRAINT "candidate_tags_candidate_id_tag_id_key" UNIQUE ("candidate_id", "tag_id");



ALTER TABLE ONLY "public"."candidate_tags"
    ADD CONSTRAINT "candidate_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidates"
    ADD CONSTRAINT "candidates_candidate_slug_key" UNIQUE ("candidate_slug");



ALTER TABLE ONLY "public"."candidates"
    ADD CONSTRAINT "candidates_pkey" PRIMARY KEY ("candidate_id");



ALTER TABLE ONLY "public"."column_email_associations"
    ADD CONSTRAINT "column_email_associations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."column_email_associations"
    ADD CONSTRAINT "column_email_associations_project_bucket_id_email_template__key" UNIQUE ("project_bucket_id", "email_template_id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."communities"
    ADD CONSTRAINT "communities_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."communities"
    ADD CONSTRAINT "communities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_bans"
    ADD CONSTRAINT "community_bans_community_id_user_id_key" UNIQUE ("community_id", "user_id");



ALTER TABLE ONLY "public"."community_bans"
    ADD CONSTRAINT "community_bans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_flairs"
    ADD CONSTRAINT "community_flairs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_memberships"
    ADD CONSTRAINT "community_memberships_pkey" PRIMARY KEY ("user_id", "community_id");



ALTER TABLE ONLY "public"."community_mod_actions"
    ADD CONSTRAINT "community_mod_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."community_rules"
    ADD CONSTRAINT "community_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."email_templates"
    ADD CONSTRAINT "email_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("api_id");



ALTER TABLE ONLY "public"."feature_banners"
    ADD CONSTRAINT "feature_banners_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fellows"
    ADD CONSTRAINT "fellows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."founder_forum_applications"
    ADD CONSTRAINT "founder_forum_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."founder_forum_members"
    ADD CONSTRAINT "founder_forum_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hero_pill"
    ADD CONSTRAINT "hero_pill_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inbox_events"
    ADD CONSTRAINT "inbox_events_pkey" PRIMARY KEY ("event_id");



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_job_id_applicant_id_key" UNIQUE ("job_id", "applicant_id");



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_saves"
    ADD CONSTRAINT "job_saves_job_id_user_id_key" UNIQUE ("job_id", "user_id");



ALTER TABLE ONLY "public"."job_saves"
    ADD CONSTRAINT "job_saves_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_tags"
    ADD CONSTRAINT "job_tags_job_id_tag_id_key" UNIQUE ("job_id", "tag_id");



ALTER TABLE ONLY "public"."job_tags"
    ADD CONSTRAINT "job_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_buckets"
    ADD CONSTRAINT "project_buckets_pkey" PRIMARY KEY ("bucket_id");



ALTER TABLE ONLY "public"."project_buckets"
    ADD CONSTRAINT "project_buckets_project_id_name_key" UNIQUE ("project_id", "name");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("project_id");



ALTER TABLE ONLY "public"."public_profiles"
    ADD CONSTRAINT "public_profiles_candidate_id_key" UNIQUE ("candidate_id");



ALTER TABLE ONLY "public"."public_profiles"
    ADD CONSTRAINT "public_profiles_pkey" PRIMARY KEY ("profile_id");



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_user_id_token_key" UNIQUE ("user_id", "token");



ALTER TABLE ONLY "public"."rejection_reasons"
    ADD CONSTRAINT "rejection_reasons_pkey" PRIMARY KEY ("reason_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."source_data"
    ADD CONSTRAINT "source_data_pkey" PRIMARY KEY ("data_id");



ALTER TABLE ONLY "public"."sources"
    ADD CONSTRAINT "sources_pkey" PRIMARY KEY ("source_id");



ALTER TABLE ONLY "public"."startup_programs"
    ADD CONSTRAINT "startup_programs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."startup_programs"
    ADD CONSTRAINT "startup_programs_startup_id_program_id_key" UNIQUE ("startup_id", "program_id");



ALTER TABLE ONLY "public"."startups"
    ADD CONSTRAINT "startups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."startups"
    ADD CONSTRAINT "startups_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."tags"
    ADD CONSTRAINT "tags_pkey" PRIMARY KEY ("tag_id");



ALTER TABLE ONLY "public"."testimonials"
    ADD CONSTRAINT "testimonials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."candidate_rejection_reasons"
    ADD CONSTRAINT "unique_candidate_bucket_reason" UNIQUE ("candidate_id", "bucket_id", "reason_id");



ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "unique_primary_contact" EXCLUDE USING "btree" ("startup_id" WITH =) WHERE (("is_primary" = true));



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_role_id_key" UNIQUE ("user_id", "role_id");



ALTER TABLE ONLY "public"."votes"
    ADD CONSTRAINT "votes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."votes"
    ADD CONSTRAINT "votes_user_id_comment_id_key" UNIQUE ("user_id", "comment_id");



ALTER TABLE ONLY "public"."votes"
    ADD CONSTRAINT "votes_user_id_post_id_key" UNIQUE ("user_id", "post_id");



CREATE INDEX "analytics_daily_metric_date_idx" ON "public"."analytics_daily" USING "btree" ("metric", "metric_date");



CREATE INDEX "events_start_at_idx" ON "public"."events" USING "btree" ("start_at");



CREATE INDEX "idx_candidate_activities_candidate_id" ON "public"."candidate_activities" USING "btree" ("candidate_id");



CREATE INDEX "idx_candidate_activities_timestamp" ON "public"."candidate_activities" USING "btree" ("activity_timestamp");



CREATE INDEX "idx_candidate_activities_type" ON "public"."candidate_activities" USING "btree" ("activity_type");



CREATE INDEX "idx_candidate_project_buckets_bucket_id" ON "public"."candidate_project_buckets" USING "btree" ("bucket_id");



CREATE INDEX "idx_candidate_project_buckets_candidate_bucket" ON "public"."candidate_project_buckets" USING "btree" ("candidate_id", "bucket_id");



CREATE INDEX "idx_candidate_project_buckets_candidate_id" ON "public"."candidate_project_buckets" USING "btree" ("candidate_id");



CREATE INDEX "idx_candidate_project_buckets_project_id" ON "public"."candidate_project_buckets" USING "btree" ("project_id");



CREATE INDEX "idx_candidate_slug" ON "public"."candidates" USING "btree" ("candidate_slug");



CREATE INDEX "idx_comments_author" ON "public"."comments" USING "btree" ("author_id");



CREATE INDEX "idx_comments_created" ON "public"."comments" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_comments_parent" ON "public"."comments" USING "btree" ("parent_id");



CREATE INDEX "idx_comments_post" ON "public"."comments" USING "btree" ("post_id");



CREATE INDEX "idx_communities_member_count" ON "public"."communities" USING "btree" ("member_count" DESC);



CREATE INDEX "idx_communities_name" ON "public"."communities" USING "btree" ("name");



CREATE INDEX "idx_communities_type" ON "public"."communities" USING "btree" ("type");



CREATE INDEX "idx_community_bans_community" ON "public"."community_bans" USING "btree" ("community_id");



CREATE INDEX "idx_community_bans_expires" ON "public"."community_bans" USING "btree" ("expires_at") WHERE ("expires_at" IS NOT NULL);



CREATE INDEX "idx_community_bans_user" ON "public"."community_bans" USING "btree" ("user_id");



CREATE INDEX "idx_community_flairs_community" ON "public"."community_flairs" USING "btree" ("community_id");



CREATE INDEX "idx_community_memberships_community" ON "public"."community_memberships" USING "btree" ("community_id");



CREATE INDEX "idx_community_memberships_role" ON "public"."community_memberships" USING "btree" ("community_id", "role");



CREATE INDEX "idx_community_memberships_user" ON "public"."community_memberships" USING "btree" ("user_id");



CREATE INDEX "idx_community_rules_community" ON "public"."community_rules" USING "btree" ("community_id");



CREATE INDEX "idx_contacts_email" ON "public"."contacts" USING "btree" ("email") WHERE ("email" IS NOT NULL);



CREATE INDEX "idx_contacts_is_primary" ON "public"."contacts" USING "btree" ("startup_id", "is_primary") WHERE ("is_primary" = true);



CREATE INDEX "idx_contacts_linkedin" ON "public"."contacts" USING "btree" ("linkedin_id") WHERE ("linkedin_id" IS NOT NULL);



CREATE INDEX "idx_contacts_name" ON "public"."contacts" USING "btree" ("first_name", "last_name");



CREATE INDEX "idx_contacts_startup_id" ON "public"."contacts" USING "btree" ("startup_id");



CREATE INDEX "idx_csp_candidate" ON "public"."candidate_startup_placements" USING "btree" ("candidate_id");



CREATE INDEX "idx_csp_startup" ON "public"."candidate_startup_placements" USING "btree" ("startup_id");



CREATE INDEX "idx_feature_banners_active" ON "public"."feature_banners" USING "btree" ("is_enabled", "start_at", "end_at");



CREATE INDEX "idx_inbox_events_candidate" ON "public"."inbox_events" USING "btree" ("candidate_id");



CREATE INDEX "idx_inbox_events_startup" ON "public"."inbox_events" USING "btree" ("startup_id");



CREATE INDEX "idx_inbox_events_status_created" ON "public"."inbox_events" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_inbox_events_type" ON "public"."inbox_events" USING "btree" ("event_type");



CREATE INDEX "idx_job_applications_applicant_id" ON "public"."job_applications" USING "btree" ("applicant_id");



CREATE INDEX "idx_job_applications_job_id" ON "public"."job_applications" USING "btree" ("job_id");



CREATE INDEX "idx_job_applications_status" ON "public"."job_applications" USING "btree" ("status");



CREATE INDEX "idx_job_saves_job_id" ON "public"."job_saves" USING "btree" ("job_id");



CREATE INDEX "idx_job_saves_user_id" ON "public"."job_saves" USING "btree" ("user_id");



CREATE INDEX "idx_job_tags_job_id" ON "public"."job_tags" USING "btree" ("job_id");



CREATE INDEX "idx_job_tags_tag_id" ON "public"."job_tags" USING "btree" ("tag_id");



CREATE INDEX "idx_jobs_is_featured" ON "public"."jobs" USING "btree" ("is_featured") WHERE ("is_featured" = true);



CREATE INDEX "idx_jobs_job_type" ON "public"."jobs" USING "btree" ("job_type");



CREATE INDEX "idx_jobs_location_type" ON "public"."jobs" USING "btree" ("location_type");



CREATE INDEX "idx_jobs_posted_by" ON "public"."jobs" USING "btree" ("posted_by");



CREATE INDEX "idx_jobs_published_at" ON "public"."jobs" USING "btree" ("published_at" DESC);



CREATE INDEX "idx_jobs_startup_id" ON "public"."jobs" USING "btree" ("startup_id");



CREATE INDEX "idx_jobs_status" ON "public"."jobs" USING "btree" ("status");



CREATE INDEX "idx_mod_actions_community" ON "public"."community_mod_actions" USING "btree" ("community_id");



CREATE INDEX "idx_mod_actions_created" ON "public"."community_mod_actions" USING "btree" ("community_id", "created_at" DESC);



CREATE INDEX "idx_mod_actions_moderator" ON "public"."community_mod_actions" USING "btree" ("moderator_id");



CREATE INDEX "idx_mod_actions_target" ON "public"."community_mod_actions" USING "btree" ("target_type", "target_id");



CREATE INDEX "idx_posts_author" ON "public"."posts" USING "btree" ("author_id");



CREATE INDEX "idx_posts_community" ON "public"."posts" USING "btree" ("community_id");



CREATE INDEX "idx_posts_community_created" ON "public"."posts" USING "btree" ("community_id", "created_at" DESC);



CREATE INDEX "idx_posts_community_score" ON "public"."posts" USING "btree" ("community_id", "score" DESC);



CREATE INDEX "idx_posts_created" ON "public"."posts" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_posts_featured" ON "public"."posts" USING "btree" ("featured") WHERE ("featured" = true);



CREATE INDEX "idx_posts_pinned" ON "public"."posts" USING "btree" ("community_id", "is_pinned") WHERE ("is_pinned" = true);



CREATE INDEX "idx_posts_score" ON "public"."posts" USING "btree" ("score" DESC);



CREATE INDEX "idx_profiles_karma" ON "public"."profiles" USING "btree" ("karma" DESC);



CREATE INDEX "idx_profiles_role" ON "public"."profiles" USING "btree" ("role");



CREATE INDEX "idx_profiles_startup_id" ON "public"."profiles" USING "btree" ("startup_id");



CREATE INDEX "idx_profiles_username" ON "public"."profiles" USING "btree" ("username");



CREATE INDEX "idx_programs_name" ON "public"."programs" USING "btree" ("name");



CREATE INDEX "idx_project_buckets_bucket_id" ON "public"."project_buckets" USING "btree" ("bucket_id");



CREATE INDEX "idx_project_buckets_project_id" ON "public"."project_buckets" USING "btree" ("project_id");



CREATE INDEX "idx_projects_kind" ON "public"."projects" USING "btree" ("kind");



CREATE INDEX "idx_projects_kind_project_id" ON "public"."projects" USING "btree" ("kind", "project_id");



CREATE INDEX "idx_projects_order_index" ON "public"."projects" USING "btree" ("order_index");



CREATE INDEX "idx_public_profiles_candidate_id" ON "public"."public_profiles" USING "btree" ("candidate_id");



CREATE INDEX "idx_public_profiles_is_visible" ON "public"."public_profiles" USING "btree" ("is_visible");



CREATE INDEX "idx_push_tokens_user_id" ON "public"."push_tokens" USING "btree" ("user_id");



CREATE INDEX "idx_roles_name" ON "public"."roles" USING "btree" ("name");



CREATE INDEX "idx_startup_programs_joined_at" ON "public"."startup_programs" USING "btree" ("joined_at");



CREATE INDEX "idx_startup_programs_program_id" ON "public"."startup_programs" USING "btree" ("program_id");



CREATE INDEX "idx_startup_programs_startup_id" ON "public"."startup_programs" USING "btree" ("startup_id");



CREATE INDEX "idx_startup_programs_status" ON "public"."startup_programs" USING "btree" ("status");



CREATE INDEX "idx_startups_created_at" ON "public"."startups" USING "btree" ("created_at");



CREATE INDEX "idx_startups_export_to_website" ON "public"."startups" USING "btree" ("export_to_website") WHERE ("export_to_website" = true);



CREATE INDEX "idx_startups_founded_year" ON "public"."startups" USING "btree" ("founded_year") WHERE ("founded_year" IS NOT NULL);



CREATE INDEX "idx_startups_funding_stage" ON "public"."startups" USING "btree" ("funding_stage") WHERE ("funding_stage" IS NOT NULL);



CREATE INDEX "idx_startups_hq_country" ON "public"."startups" USING "btree" ("hq_country") WHERE ("hq_country" IS NOT NULL);



CREATE INDEX "idx_startups_industry_tags" ON "public"."startups" USING "gin" ("industry_tags");



CREATE INDEX "idx_startups_last_contacted" ON "public"."startups" USING "btree" ("last_contacted_at") WHERE ("last_contacted_at" IS NOT NULL);



CREATE INDEX "idx_startups_name_trgm" ON "public"."startups" USING "gin" ("name" "public"."gin_trgm_ops");



CREATE INDEX "idx_startups_slug" ON "public"."startups" USING "btree" ("slug");



CREATE INDEX "idx_startups_tech_stack" ON "public"."startups" USING "gin" ("tech_stack");



CREATE INDEX "idx_startups_visible" ON "public"."startups" USING "btree" ("visible") WHERE ("visible" = true);



CREATE INDEX "idx_testimonials_published_order" ON "public"."testimonials" USING "btree" ("published", "display_order");



CREATE INDEX "idx_user_roles_role_id" ON "public"."user_roles" USING "btree" ("role_id");



CREATE INDEX "idx_user_roles_user_id" ON "public"."user_roles" USING "btree" ("user_id");



CREATE INDEX "idx_votes_comment" ON "public"."votes" USING "btree" ("comment_id");



CREATE INDEX "idx_votes_post" ON "public"."votes" USING "btree" ("post_id");



CREATE INDEX "idx_votes_user" ON "public"."votes" USING "btree" ("user_id");



CREATE INDEX "jobs_feature_level_published_idx" ON "public"."jobs" USING "btree" ("feature_level" DESC, "published_at" DESC NULLS LAST, "created_at" DESC);



CREATE OR REPLACE TRIGGER "ensure_candidate_slug" BEFORE INSERT ON "public"."candidates" FOR EACH ROW EXECUTE FUNCTION "public"."candidate_slug_trigger"();



CREATE OR REPLACE TRIGGER "increment_application_count" AFTER INSERT ON "public"."job_applications" FOR EACH ROW EXECUTE FUNCTION "public"."increment_job_application_count"();



CREATE OR REPLACE TRIGGER "set_published_at" BEFORE UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."set_job_published_at"();



CREATE OR REPLACE TRIGGER "trg_csp_touch_updated_at" BEFORE UPDATE ON "public"."candidate_startup_placements" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_comment_count" AFTER INSERT OR DELETE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."update_post_comment_count"();



CREATE OR REPLACE TRIGGER "trigger_update_inbox_events_updated_at" BEFORE UPDATE ON "public"."inbox_events" FOR EACH ROW EXECUTE FUNCTION "public"."update_inbox_events_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_member_count" AFTER INSERT OR DELETE ON "public"."community_memberships" FOR EACH ROW EXECUTE FUNCTION "public"."update_community_member_count"();



CREATE OR REPLACE TRIGGER "trigger_update_post_count" AFTER INSERT OR DELETE OR UPDATE OF "community_id" ON "public"."posts" FOR EACH ROW EXECUTE FUNCTION "public"."update_community_post_count"();



CREATE OR REPLACE TRIGGER "update_comment_count_on_comment" AFTER INSERT OR DELETE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."update_comment_count"();



CREATE OR REPLACE TRIGGER "update_comments_updated_at" BEFORE UPDATE ON "public"."comments" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_contacts_updated_at" BEFORE UPDATE ON "public"."contacts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_feature_banners_updated_at" BEFORE UPDATE ON "public"."feature_banners" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_fellows_updated_at" BEFORE UPDATE ON "public"."fellows" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_job_applications_updated_at" BEFORE UPDATE ON "public"."job_applications" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_jobs_updated_at" BEFORE UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_karma_on_vote_delete" AFTER DELETE ON "public"."votes" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_karma_on_vote_delete"();



CREATE OR REPLACE TRIGGER "update_karma_on_vote_insert" AFTER INSERT ON "public"."votes" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_karma"();



CREATE OR REPLACE TRIGGER "update_karma_on_vote_update" AFTER UPDATE ON "public"."votes" FOR EACH ROW WHEN (("old"."vote_type" IS DISTINCT FROM "new"."vote_type")) EXECUTE FUNCTION "public"."update_user_karma_on_vote_change"();



CREATE OR REPLACE TRIGGER "update_post_score_on_vote" AFTER INSERT OR DELETE OR UPDATE ON "public"."votes" FOR EACH ROW EXECUTE FUNCTION "public"."update_post_score"();



CREATE OR REPLACE TRIGGER "update_posts_updated_at" BEFORE UPDATE ON "public"."posts" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_profiles_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_public_profiles_updated_at" BEFORE UPDATE ON "public"."public_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_public_profiles_updated_at"();



CREATE OR REPLACE TRIGGER "update_push_tokens_updated_at" BEFORE UPDATE ON "public"."push_tokens" FOR EACH ROW EXECUTE FUNCTION "public"."update_push_tokens_updated_at"();



CREATE OR REPLACE TRIGGER "update_roles_updated_at" BEFORE UPDATE ON "public"."roles" FOR EACH ROW EXECUTE FUNCTION "public"."update_roles_updated_at"();



CREATE OR REPLACE TRIGGER "update_startups_updated_at" BEFORE UPDATE ON "public"."startups" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."candidate_activities"
    ADD CONSTRAINT "candidate_activities_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."candidate_activities"
    ADD CONSTRAINT "candidate_activities_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_activities"
    ADD CONSTRAINT "candidate_activities_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_availability"
    ADD CONSTRAINT "candidate_availability_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_notes"
    ADD CONSTRAINT "candidate_notes_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_project_buckets"
    ADD CONSTRAINT "candidate_project_buckets_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "public"."project_buckets"("bucket_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_project_buckets"
    ADD CONSTRAINT "candidate_project_buckets_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_project_buckets"
    ADD CONSTRAINT "candidate_project_buckets_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_startup_placements"
    ADD CONSTRAINT "candidate_startup_placements_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_startup_placements"
    ADD CONSTRAINT "candidate_startup_placements_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_summaries"
    ADD CONSTRAINT "candidate_summaries_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id");



ALTER TABLE ONLY "public"."candidate_tags"
    ADD CONSTRAINT "candidate_tags_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_tags"
    ADD CONSTRAINT "candidate_tags_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("tag_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_removed_by_fkey" FOREIGN KEY ("removed_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."communities"
    ADD CONSTRAINT "communities_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."community_bans"
    ADD CONSTRAINT "community_bans_banned_by_fkey" FOREIGN KEY ("banned_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."community_bans"
    ADD CONSTRAINT "community_bans_community_id_fkey" FOREIGN KEY ("community_id") REFERENCES "public"."communities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_bans"
    ADD CONSTRAINT "community_bans_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_flairs"
    ADD CONSTRAINT "community_flairs_community_id_fkey" FOREIGN KEY ("community_id") REFERENCES "public"."communities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_memberships"
    ADD CONSTRAINT "community_memberships_community_id_fkey" FOREIGN KEY ("community_id") REFERENCES "public"."communities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_memberships"
    ADD CONSTRAINT "community_memberships_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_mod_actions"
    ADD CONSTRAINT "community_mod_actions_community_id_fkey" FOREIGN KEY ("community_id") REFERENCES "public"."communities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_mod_actions"
    ADD CONSTRAINT "community_mod_actions_moderator_id_fkey" FOREIGN KEY ("moderator_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."community_rules"
    ADD CONSTRAINT "community_rules_community_id_fkey" FOREIGN KEY ("community_id") REFERENCES "public"."communities"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fellows"
    ADD CONSTRAINT "fellows_id_fkey" FOREIGN KEY ("id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_rejection_reasons"
    ADD CONSTRAINT "fk_bucket_id" FOREIGN KEY ("bucket_id") REFERENCES "public"."project_buckets"("bucket_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_notes"
    ADD CONSTRAINT "fk_candidate" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_rejection_reasons"
    ADD CONSTRAINT "fk_candidate_id" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."column_email_associations"
    ADD CONSTRAINT "fk_email_template" FOREIGN KEY ("email_template_id") REFERENCES "public"."email_templates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."column_email_associations"
    ADD CONSTRAINT "fk_project_bucket" FOREIGN KEY ("project_bucket_id") REFERENCES "public"."project_buckets"("bucket_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rejection_reasons"
    ADD CONSTRAINT "fk_project_id" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_rejection_reasons"
    ADD CONSTRAINT "fk_project_id" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."candidate_rejection_reasons"
    ADD CONSTRAINT "fk_reason_id" FOREIGN KEY ("reason_id") REFERENCES "public"."rejection_reasons"("reason_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."founder_forum_applications"
    ADD CONSTRAINT "founder_forum_applications_member_id_fkey" FOREIGN KEY ("member_id") REFERENCES "public"."founder_forum_members"("id");



ALTER TABLE ONLY "public"."founder_forum_applications"
    ADD CONSTRAINT "founder_forum_applications_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id");



ALTER TABLE ONLY "public"."inbox_events"
    ADD CONSTRAINT "inbox_events_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."inbox_events"
    ADD CONSTRAINT "inbox_events_founder_forum_application_id_fkey" FOREIGN KEY ("founder_forum_application_id") REFERENCES "public"."founder_forum_applications"("id");



ALTER TABLE ONLY "public"."inbox_events"
    ADD CONSTRAINT "inbox_events_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_applicant_id_fkey" FOREIGN KEY ("applicant_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_applications"
    ADD CONSTRAINT "job_applications_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_saves"
    ADD CONSTRAINT "job_saves_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_saves"
    ADD CONSTRAINT "job_saves_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_tags"
    ADD CONSTRAINT "job_tags_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_tags"
    ADD CONSTRAINT "job_tags_tag_id_fkey" FOREIGN KEY ("tag_id") REFERENCES "public"."tags"("tag_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_posted_by_fkey" FOREIGN KEY ("posted_by") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_community_id_fkey" FOREIGN KEY ("community_id") REFERENCES "public"."communities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_flair_id_fkey" FOREIGN KEY ("flair_id") REFERENCES "public"."community_flairs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_removed_by_fkey" FOREIGN KEY ("removed_by") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_buckets"
    ADD CONSTRAINT "project_buckets_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."public_profiles"
    ADD CONSTRAINT "public_profiles_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."source_data"
    ADD CONSTRAINT "source_data_source_id_fkey" FOREIGN KEY ("source_id") REFERENCES "public"."sources"("source_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sources"
    ADD CONSTRAINT "sources_candidate_id_fkey" FOREIGN KEY ("candidate_id") REFERENCES "public"."candidates"("candidate_id");



ALTER TABLE ONLY "public"."startup_programs"
    ADD CONSTRAINT "startup_programs_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."startup_programs"
    ADD CONSTRAINT "startup_programs_startup_id_fkey" FOREIGN KEY ("startup_id") REFERENCES "public"."startups"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_assigned_by_fkey" FOREIGN KEY ("assigned_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_roles"
    ADD CONSTRAINT "user_roles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."votes"
    ADD CONSTRAINT "votes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."votes"
    ADD CONSTRAINT "votes_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."votes"
    ADD CONSTRAINT "votes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can manage roles" ON "public"."roles" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_roles" "ur"
     JOIN "public"."roles" "r" ON (("ur"."role_id" = "r"."id")))
  WHERE (("ur"."user_id" = "auth"."uid"()) AND ("r"."name" = 'admin'::"text")))));



CREATE POLICY "Admins can manage user roles" ON "public"."user_roles" USING ((EXISTS ( SELECT 1
   FROM ("public"."user_roles" "ur"
     JOIN "public"."roles" "r" ON (("ur"."role_id" = "r"."id")))
  WHERE (("ur"."user_id" = "auth"."uid"()) AND ("r"."name" = 'admin'::"text")))));



CREATE POLICY "Allow authenticated to read roles" ON "public"."roles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow users to read own roles" ON "public"."user_roles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Applicants can update own applications" ON "public"."job_applications" FOR UPDATE USING (("auth"."uid"() = "applicant_id"));



CREATE POLICY "Applicants can view own applications" ON "public"."job_applications" FOR SELECT USING (("auth"."uid"() = "applicant_id"));



CREATE POLICY "Authenticated users can create votes" ON "public"."votes" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Authorized users can manage feature banners" ON "public"."feature_banners" USING ((("auth"."email"() = 'hello@felixgil.es'::"text") OR ("auth"."email"() ~~ '%@goexponential.org'::"text")));



CREATE POLICY "Feature banners are viewable by everyone" ON "public"."feature_banners" FOR SELECT USING (true);



CREATE POLICY "Fellows are viewable by everyone" ON "public"."fellows" FOR SELECT USING (true);



CREATE POLICY "Fellows can insert own data" ON "public"."fellows" FOR INSERT WITH CHECK ((("auth"."uid"() = "id") AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'fellow'::"text"))))));



CREATE POLICY "Fellows can update own data" ON "public"."fellows" FOR UPDATE USING ((("auth"."uid"() = "id") AND (EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."role" = 'fellow'::"text"))))));



CREATE POLICY "Job posters can manage tags" ON "public"."job_tags" USING ((EXISTS ( SELECT 1
   FROM "public"."jobs"
  WHERE (("jobs"."id" = "job_tags"."job_id") AND ("jobs"."posted_by" = "auth"."uid"())))));



CREATE POLICY "Job posters can update application status" ON "public"."job_applications" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."jobs"
  WHERE (("jobs"."id" = "job_applications"."job_id") AND ("jobs"."posted_by" = "auth"."uid"())))));



CREATE POLICY "Job posters can view applications to their jobs" ON "public"."job_applications" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."jobs"
  WHERE (("jobs"."id" = "job_applications"."job_id") AND ("jobs"."posted_by" = "auth"."uid"())))));



CREATE POLICY "Job tags are viewable by everyone" ON "public"."job_tags" FOR SELECT USING (true);



CREATE POLICY "Profiles are viewable by everyone" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Published jobs are viewable by everyone" ON "public"."jobs" FOR SELECT USING ((("status" = 'published'::"text") OR ("posted_by" = "auth"."uid"())));



CREATE POLICY "Roles are viewable by everyone" ON "public"."roles" FOR SELECT USING (true);



CREATE POLICY "User roles are viewable by everyone" ON "public"."user_roles" FOR SELECT USING (true);



CREATE POLICY "Users can create applications" ON "public"."job_applications" FOR INSERT WITH CHECK (("auth"."uid"() = "applicant_id"));



CREATE POLICY "Users can create jobs" ON "public"."jobs" FOR INSERT WITH CHECK (("auth"."uid"() = "posted_by"));



CREATE POLICY "Users can delete own jobs" ON "public"."jobs" FOR DELETE USING (("auth"."uid"() = "posted_by"));



CREATE POLICY "Users can delete own push tokens" ON "public"."push_tokens" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete own votes" ON "public"."votes" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert own profile" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert own push tokens" ON "public"."push_tokens" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can save jobs" ON "public"."job_saves" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can unsave jobs" ON "public"."job_saves" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own jobs" ON "public"."jobs" FOR UPDATE USING (("auth"."uid"() = "posted_by"));



CREATE POLICY "Users can update own profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own push tokens" ON "public"."push_tokens" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own votes" ON "public"."votes" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own push tokens" ON "public"."push_tokens" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own roles" ON "public"."user_roles" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own saved jobs" ON "public"."job_saves" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own votes" ON "public"."votes" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."analytics_daily" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "anon_select_published" ON "public"."testimonials" FOR SELECT TO "anon" USING (("published" = true));



CREATE POLICY "authenticated_full_access" ON "public"."candidate_activities" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_availability" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_notes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_project_buckets" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_rejection_reasons" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_startup_placements" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_summaries" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidate_tags" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."candidates" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."column_email_associations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."contacts" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."email_templates" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."founder_forum_applications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."founder_forum_members" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."inbox_events" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."programs" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."project_buckets" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."projects" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."public_profiles" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."rejection_reasons" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."source_data" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."sources" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."startup_programs" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."startups" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."tags" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "authenticated_full_access" ON "public"."testimonials" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "bans_delete" ON "public"."community_bans" FOR DELETE USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "bans_insert" ON "public"."community_bans" FOR INSERT WITH CHECK ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "bans_select_mod" ON "public"."community_bans" FOR SELECT USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "bans_select_self" ON "public"."community_bans" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "bans_update" ON "public"."community_bans" FOR UPDATE USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



ALTER TABLE "public"."candidate_activities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_availability" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_project_buckets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_rejection_reasons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_startup_placements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_summaries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidate_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."candidates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."column_email_associations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "comments_delete_own" ON "public"."comments" FOR DELETE USING (("author_id" = "auth"."uid"()));



CREATE POLICY "comments_insert" ON "public"."comments" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND ("author_id" = "auth"."uid"())));



CREATE POLICY "comments_select" ON "public"."comments" FOR SELECT USING ((("is_removed" = false) OR ("is_removed" IS NULL) OR ("author_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."posts" "p"
  WHERE (("p"."id" = "comments"."post_id") AND ("p"."community_id" IS NOT NULL) AND "public"."is_community_moderator"("p"."community_id", "auth"."uid"()))))));



CREATE POLICY "comments_update_mod" ON "public"."comments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."posts" "p"
  WHERE (("p"."id" = "comments"."post_id") AND ("p"."community_id" IS NOT NULL) AND "public"."is_community_moderator"("p"."community_id", "auth"."uid"())))));



CREATE POLICY "comments_update_own" ON "public"."comments" FOR UPDATE USING (("author_id" = "auth"."uid"()));



ALTER TABLE "public"."communities" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "communities_insert" ON "public"."communities" FOR INSERT WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "communities_select_private" ON "public"."communities" FOR SELECT USING ((("type" = 'private'::"text") AND "public"."is_community_member"("id", "auth"."uid"())));



CREATE POLICY "communities_select_public" ON "public"."communities" FOR SELECT USING (("type" = ANY (ARRAY['public'::"text", 'restricted'::"text"])));



CREATE POLICY "communities_update" ON "public"."communities" FOR UPDATE USING ("public"."is_community_admin"("id", "auth"."uid"()));



ALTER TABLE "public"."community_bans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_flairs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_mod_actions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."community_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."email_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "events public read" ON "public"."events" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."feature_banners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fellows" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "flairs_delete" ON "public"."community_flairs" FOR DELETE USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "flairs_insert" ON "public"."community_flairs" FOR INSERT WITH CHECK ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "flairs_select" ON "public"."community_flairs" FOR SELECT USING (true);



CREATE POLICY "flairs_update" ON "public"."community_flairs" FOR UPDATE USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



ALTER TABLE "public"."founder_forum_applications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."founder_forum_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hero_pill" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "hero_pill public read" ON "public"."hero_pill" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."inbox_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_applications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_saves" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "memberships_delete_admin" ON "public"."community_memberships" FOR DELETE USING ("public"."is_community_admin"("community_id", "auth"."uid"()));



CREATE POLICY "memberships_delete_self" ON "public"."community_memberships" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "memberships_insert_admin" ON "public"."community_memberships" FOR INSERT WITH CHECK ("public"."is_community_admin"("community_id", "auth"."uid"()));



CREATE POLICY "memberships_insert_self" ON "public"."community_memberships" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_id") AND ("public"."get_community_type"("community_id") = 'public'::"text")));



CREATE POLICY "memberships_select" ON "public"."community_memberships" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR ("public"."get_community_type"("community_id") = ANY (ARRAY['public'::"text", 'restricted'::"text"])) OR (("public"."get_community_type"("community_id") = 'private'::"text") AND "public"."is_community_member"("community_id", "auth"."uid"()))));



CREATE POLICY "memberships_update_admin" ON "public"."community_memberships" FOR UPDATE USING ("public"."is_community_admin"("community_id", "auth"."uid"()));



CREATE POLICY "mod_actions_insert" ON "public"."community_mod_actions" FOR INSERT WITH CHECK ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "mod_actions_select" ON "public"."community_mod_actions" FOR SELECT USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



ALTER TABLE "public"."posts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "posts_delete_own" ON "public"."posts" FOR DELETE USING (("author_id" = "auth"."uid"()));



CREATE POLICY "posts_insert" ON "public"."posts" FOR INSERT WITH CHECK ((("auth"."uid"() IS NOT NULL) AND ("author_id" = "auth"."uid"())));



CREATE POLICY "posts_select" ON "public"."posts" FOR SELECT USING ((("is_removed" = false) OR ("is_removed" IS NULL) OR ("author_id" = "auth"."uid"()) OR (("community_id" IS NOT NULL) AND "public"."is_community_moderator"("community_id", "auth"."uid"()))));



CREATE POLICY "posts_update_mod" ON "public"."posts" FOR UPDATE USING ((("community_id" IS NOT NULL) AND "public"."is_community_moderator"("community_id", "auth"."uid"())));



CREATE POLICY "posts_update_own" ON "public"."posts" FOR UPDATE USING (("author_id" = "auth"."uid"()));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."programs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_buckets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."public_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."push_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rejection_reasons" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rules_delete" ON "public"."community_rules" FOR DELETE USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "rules_insert" ON "public"."community_rules" FOR INSERT WITH CHECK ("public"."is_community_moderator"("community_id", "auth"."uid"()));



CREATE POLICY "rules_select" ON "public"."community_rules" FOR SELECT USING (true);



CREATE POLICY "rules_update" ON "public"."community_rules" FOR UPDATE USING ("public"."is_community_moderator"("community_id", "auth"."uid"()));



ALTER TABLE "public"."source_data" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."startup_programs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."startups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."testimonials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."votes" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";






































































































































































































GRANT ALL ON FUNCTION "public"."assign_to_default_bucket"() TO "anon";
GRANT ALL ON FUNCTION "public"."assign_to_default_bucket"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_to_default_bucket"() TO "service_role";



GRANT ALL ON FUNCTION "public"."candidate_slug_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."candidate_slug_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."candidate_slug_trigger"() TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_candidate"("p_candidate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_candidate"("p_candidate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_candidate"("p_candidate_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_candidate_slug"("first_name" "text", "last_name" "text", "candidate_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_candidate_slug"("first_name" "text", "last_name" "text", "candidate_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_candidate_slug"("first_name" "text", "last_name" "text", "candidate_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_slug"("title" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_slug"("title" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_slug"("title" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_community_type"("p_community_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_community_type"("p_community_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_community_type"("p_community_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_roles"("user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_roles"("user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_roles"("user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_job_application_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."increment_job_application_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_job_application_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_community_admin"("community_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_community_admin"("community_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_community_admin"("community_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_community_admin"("p_community_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_community_admin"("p_community_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_community_admin"("p_community_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_community_member"("p_community_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_community_member"("p_community_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_community_member"("p_community_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_community_moderator"("community_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_community_moderator"("community_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_community_moderator"("community_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_community_moderator"("p_community_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_community_moderator"("p_community_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_community_moderator"("p_community_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_user_banned"("p_user_id" "uuid", "p_community_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_user_banned"("p_user_id" "uuid", "p_community_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_user_banned"("p_user_id" "uuid", "p_community_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_analytics_daily"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_job_published_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_job_published_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_job_published_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_comment_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_comment_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_comment_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_community_member_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_community_member_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_community_member_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_community_post_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_community_post_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_community_post_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_inbox_events_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_inbox_events_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_inbox_events_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_post_comment_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_post_comment_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_post_comment_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_post_score"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_post_score"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_post_score"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_public_profiles_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_public_profiles_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_public_profiles_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_push_tokens_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_push_tokens_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_push_tokens_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_roles_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_roles_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_roles_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_karma"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_karma"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_karma"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_karma_on_vote_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_karma_on_vote_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_karma_on_vote_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_karma_on_vote_delete"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_karma_on_vote_delete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_karma_on_vote_delete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_has_role"("user_id" "uuid", "role_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."user_has_role"("user_id" "uuid", "role_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_has_role"("user_id" "uuid", "role_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";
























GRANT ALL ON TABLE "public"."analytics_daily" TO "anon";
GRANT ALL ON TABLE "public"."analytics_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."analytics_daily" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_activities" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_availability" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_notes" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_project_buckets" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_project_buckets" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_rejection_reasons" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_rejection_reasons" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_startup_placements" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_startup_placements" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_summaries" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_summaries" TO "service_role";



GRANT ALL ON TABLE "public"."candidate_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."candidate_tags" TO "service_role";



GRANT ALL ON TABLE "public"."candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."candidates" TO "service_role";



GRANT ALL ON TABLE "public"."column_email_associations" TO "authenticated";
GRANT ALL ON TABLE "public"."column_email_associations" TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



GRANT ALL ON TABLE "public"."communities" TO "anon";
GRANT ALL ON TABLE "public"."communities" TO "authenticated";
GRANT ALL ON TABLE "public"."communities" TO "service_role";



GRANT ALL ON TABLE "public"."community_bans" TO "anon";
GRANT ALL ON TABLE "public"."community_bans" TO "authenticated";
GRANT ALL ON TABLE "public"."community_bans" TO "service_role";



GRANT ALL ON TABLE "public"."community_flairs" TO "anon";
GRANT ALL ON TABLE "public"."community_flairs" TO "authenticated";
GRANT ALL ON TABLE "public"."community_flairs" TO "service_role";



GRANT ALL ON TABLE "public"."community_memberships" TO "anon";
GRANT ALL ON TABLE "public"."community_memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."community_memberships" TO "service_role";



GRANT ALL ON TABLE "public"."community_mod_actions" TO "anon";
GRANT ALL ON TABLE "public"."community_mod_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."community_mod_actions" TO "service_role";



GRANT ALL ON TABLE "public"."community_rules" TO "anon";
GRANT ALL ON TABLE "public"."community_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."community_rules" TO "service_role";



GRANT ALL ON TABLE "public"."contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."contacts" TO "service_role";



GRANT ALL ON TABLE "public"."email_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."email_templates" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."feature_banners" TO "anon";
GRANT ALL ON TABLE "public"."feature_banners" TO "authenticated";
GRANT ALL ON TABLE "public"."feature_banners" TO "service_role";



GRANT ALL ON TABLE "public"."fellows" TO "anon";
GRANT ALL ON TABLE "public"."fellows" TO "authenticated";
GRANT ALL ON TABLE "public"."fellows" TO "service_role";



GRANT ALL ON TABLE "public"."founder_forum_applications" TO "anon";
GRANT ALL ON TABLE "public"."founder_forum_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."founder_forum_applications" TO "service_role";



GRANT ALL ON TABLE "public"."founder_forum_members" TO "anon";
GRANT ALL ON TABLE "public"."founder_forum_members" TO "authenticated";
GRANT ALL ON TABLE "public"."founder_forum_members" TO "service_role";



GRANT ALL ON TABLE "public"."hero_pill" TO "anon";
GRANT ALL ON TABLE "public"."hero_pill" TO "authenticated";
GRANT ALL ON TABLE "public"."hero_pill" TO "service_role";



GRANT ALL ON TABLE "public"."inbox_events" TO "authenticated";
GRANT ALL ON TABLE "public"."inbox_events" TO "service_role";



GRANT ALL ON TABLE "public"."job_applications" TO "anon";
GRANT ALL ON TABLE "public"."job_applications" TO "authenticated";
GRANT ALL ON TABLE "public"."job_applications" TO "service_role";



GRANT ALL ON TABLE "public"."job_saves" TO "anon";
GRANT ALL ON TABLE "public"."job_saves" TO "authenticated";
GRANT ALL ON TABLE "public"."job_saves" TO "service_role";



GRANT ALL ON TABLE "public"."job_tags" TO "anon";
GRANT ALL ON TABLE "public"."job_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."job_tags" TO "service_role";



GRANT ALL ON TABLE "public"."jobs" TO "anon";
GRANT ALL ON TABLE "public"."jobs" TO "authenticated";
GRANT ALL ON TABLE "public"."jobs" TO "service_role";



GRANT ALL ON TABLE "public"."posts" TO "anon";
GRANT ALL ON TABLE "public"."posts" TO "authenticated";
GRANT ALL ON TABLE "public"."posts" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."programs" TO "authenticated";
GRANT ALL ON TABLE "public"."programs" TO "service_role";



GRANT ALL ON TABLE "public"."project_buckets" TO "authenticated";
GRANT ALL ON TABLE "public"."project_buckets" TO "service_role";



GRANT ALL ON TABLE "public"."projects" TO "authenticated";
GRANT ALL ON TABLE "public"."projects" TO "service_role";



GRANT ALL ON TABLE "public"."public_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."public_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."source_data" TO "authenticated";
GRANT ALL ON TABLE "public"."source_data" TO "service_role";



GRANT ALL ON TABLE "public"."sources" TO "authenticated";
GRANT ALL ON TABLE "public"."sources" TO "service_role";



GRANT ALL ON TABLE "public"."public_bucket_candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."public_bucket_candidates" TO "service_role";



GRANT ALL ON TABLE "public"."push_tokens" TO "anon";
GRANT ALL ON TABLE "public"."push_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."push_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."rejection_reasons" TO "authenticated";
GRANT ALL ON TABLE "public"."rejection_reasons" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON TABLE "public"."startup_programs" TO "authenticated";
GRANT ALL ON TABLE "public"."startup_programs" TO "service_role";



GRANT ALL ON TABLE "public"."startups" TO "authenticated";
GRANT ALL ON TABLE "public"."startups" TO "service_role";



GRANT ALL ON TABLE "public"."tags" TO "authenticated";
GRANT ALL ON TABLE "public"."tags" TO "service_role";



GRANT ALL ON TABLE "public"."testimonials" TO "anon";
GRANT ALL ON TABLE "public"."testimonials" TO "authenticated";
GRANT ALL ON TABLE "public"."testimonials" TO "service_role";



GRANT ALL ON TABLE "public"."user_roles" TO "anon";
GRANT ALL ON TABLE "public"."user_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_roles" TO "service_role";



GRANT ALL ON TABLE "public"."votes" TO "anon";
GRANT ALL ON TABLE "public"."votes" TO "authenticated";
GRANT ALL ON TABLE "public"."votes" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";
