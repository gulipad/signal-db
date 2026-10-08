-- ============================================================================
-- GUARD THE SECURITY DEFINER RPCs
--
-- Surfaced by the security advisor right after the staff-gated RLS migration:
-- `delete_candidate(uuid)` and `decide_inbox_event(...)` are SECURITY DEFINER,
-- carry no permission check of their own, and are executable by `anon`. Anyone
-- holding the publishable key could POST to /rest/v1/rpc/delete_candidate and
-- erase a candidate with every related row. RLS does not apply inside a
-- SECURITY DEFINER function, so the staff policies do not protect these paths.
--
-- Fix:
--   1. `assert_staff()` — raises unless the caller is staff, service_role, or a
--      direct database session (no JWT). Reusable by future RPCs.
--   2. Both functions call it first. Bodies are otherwise unchanged.
--   3. EXECUTE revoked from anon and public on both.
--
-- Left alone on purpose: the community helper functions (is_community_*,
-- get_community_type, user_has_role, ...) are called from RLS policies that
-- anon relies on, and the trigger functions cannot be invoked over RPC.
-- ============================================================================

BEGIN;
-- ----------------------------------------------------------------------------
-- 1. assert_staff()
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_staff()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text := NULLIF(current_setting('request.jwt.claims', true), '')::json->>'role';
BEGIN
  -- No JWT: direct SQL session (postgres, migrations, MCP). Allowed.
  IF v_role IS NULL THEN RETURN; END IF;
  -- Server-side callers with the secret key. Allowed.
  IF v_role = 'service_role' THEN RETURN; END IF;
  -- Signed-in users must be on the staff list.
  IF v_role = 'authenticated' AND public.is_staff() THEN RETURN; END IF;

  RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
END;
$$;
REVOKE ALL ON FUNCTION public.assert_staff() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_staff() TO authenticated, service_role;
COMMENT ON FUNCTION public.assert_staff() IS
  'Call first thing inside any SECURITY DEFINER RPC that mutates internal data. Raises 42501 unless the caller is staff, service_role, or a direct database session.';
-- ----------------------------------------------------------------------------
-- 2. delete_candidate — guarded, and given a fixed search_path
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.delete_candidate(p_candidate_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
    PERFORM public.assert_staff();

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
$function$;
REVOKE ALL ON FUNCTION public.delete_candidate(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.delete_candidate(uuid) TO authenticated, service_role;
-- ----------------------------------------------------------------------------
-- 3. decide_inbox_event — guarded
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.decide_inbox_event(
  p_event_id   uuid,
  p_decision   text,
  p_project_id uuid DEFAULT NULL::uuid,
  p_note       text DEFAULT NULL::text
)
RETURNS inbox_events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_event      public.inbox_events;
  v_actor      uuid;
  v_program_id uuid;
  v_bucket_id  uuid;
BEGIN
  PERFORM public.assert_staff();

  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  SELECT * INTO v_event FROM public.inbox_events WHERE event_id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inbox event % not found', p_event_id;
  END IF;
  IF v_event.decision IS NOT NULL THEN
    RAISE EXCEPTION 'inbox event % already decided as %', p_event_id, v_event.decision;
  END IF;

  -- Qualifying into a funnel needs somewhere to put the person.
  IF p_decision IN ('fellowship', 'launchpad') THEN
    IF p_project_id IS NULL THEN
      RAISE EXCEPTION 'a funnel must be supplied when qualifying someone';
    END IF;
    IF v_event.candidate_id IS NULL THEN
      RAISE EXCEPTION 'inbox event % has no candidate to route', p_event_id;
    END IF;

    -- Land them in the funnel's first column.
    SELECT bucket_id INTO v_bucket_id
    FROM public.project_buckets
    WHERE project_id = p_project_id
    ORDER BY order_index
    LIMIT 1;

    IF v_bucket_id IS NULL THEN
      RAISE EXCEPTION 'funnel % has no buckets to place the candidate in', p_project_id;
    END IF;

    -- The transition trigger records this arrival automatically.
    INSERT INTO public.candidate_project_buckets (candidate_id, project_id, bucket_id)
    VALUES (v_event.candidate_id, p_project_id, v_bucket_id)
    ON CONFLICT (candidate_id, project_id) DO NOTHING;

    SELECT id INTO v_program_id FROM public.programs WHERE slug = p_decision;
  END IF;

  IF p_decision = 'community_approved' THEN
    SELECT id INTO v_program_id
    FROM public.programs WHERE kind = 'community' ORDER BY name LIMIT 1;
  END IF;

  -- Record membership of whichever program the decision implies. Now possible
  -- for community programs too, since the placement-only guard moved.
  IF v_program_id IS NOT NULL AND v_event.candidate_id IS NOT NULL THEN
    INSERT INTO public.candidate_program_memberships (candidate_id, program_id, status)
    VALUES (v_event.candidate_id, v_program_id, 'active')
    ON CONFLICT (candidate_id, program_id) DO NOTHING;
  END IF;

  UPDATE public.inbox_events
  SET decision            = p_decision,
      decided_by          = v_actor,
      decided_at          = now(),
      decision_project_id = p_project_id,
      decision_note       = p_note,
      status              = 'reviewed',
      reviewed_at         = COALESCE(reviewed_at, now()),
      reviewed_by         = COALESCE(reviewed_by, v_actor)
  WHERE event_id = p_event_id
  RETURNING * INTO v_event;

  RETURN v_event;
END;
$function$;
REVOKE ALL ON FUNCTION public.decide_inbox_event(uuid, text, uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.decide_inbox_event(uuid, text, uuid, text) TO authenticated, service_role;
COMMIT;
