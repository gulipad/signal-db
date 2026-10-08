-- ============================================================================
-- INBOX ON MEMBER TRACKS
--
-- The inbox decides applicants with the member-track actions instead of routing
-- them into funnels:
--
--   archived    archive the candidate (one of three rejection emails)
--   community   invite to the community
--   launchpad   invite to launchpad (+ community), optionally with an interview
--   fellowship  invite to the fellowship (+ community) with interview scheduling
--
-- resolve_inbox_event records the decision and the member actions in one
-- transaction, closing every undecided application from the same person. The email is previewed before the call and sent by the app
-- after it, tagged with the returned batch_id.
--
-- Also:
--   * enrichment status on candidates, so scraping can run unattended on new
--     applications and the inbox can show progress.
--   * action_key on the existing email templates, plus drafts for the actions
--     that had no template.
-- ============================================================================

BEGIN;
-- ----------------------------------------------------------------------------
-- 1. Decisions
-- ----------------------------------------------------------------------------

ALTER TABLE public.inbox_events DROP CONSTRAINT IF EXISTS inbox_events_decision_check;
ALTER TABLE public.inbox_events
  ADD CONSTRAINT inbox_events_decision_check CHECK (decision IS NULL OR decision IN (
    -- member-track decisions
    'archived', 'community', 'launchpad', 'fellowship',
    -- legacy funnel decisions, kept for history
    'community_approved', 'rejected'
  ));
ALTER TABLE public.inbox_events
  ADD COLUMN IF NOT EXISTS decision_batch_id uuid;
-- One application for Exponential (interest in Launchpad and/or Fellowship
-- in requested_programs) is replacing the separate fellowship and community
-- forms. Old types stay valid for history.
ALTER TABLE public.inbox_events DROP CONSTRAINT IF EXISTS inbox_events_event_type_check;
ALTER TABLE public.inbox_events
  ADD CONSTRAINT inbox_events_event_type_check CHECK (event_type IN (
    'exponential_application',
    'fellowship_application', 'community_application', 'manual_addition',
    'startup_intro_request', 'founder_forum_application'
  ));
COMMENT ON COLUMN public.inbox_events.decision_batch_id IS
  'batch_id of the member-track events (or archive log row) the decision wrote. The email_sent activity carries the same id.';
CREATE OR REPLACE FUNCTION public.resolve_inbox_event(
  p_event_id       uuid,
  p_decision       text,
  p_actions        jsonb DEFAULT NULL,
  p_archive_reason text DEFAULT NULL,
  p_note           text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_event public.inbox_events;
  v_actor uuid;
  v_batch uuid := gen_random_uuid();
  v_archived boolean;
BEGIN
  PERFORM public.assert_staff();
  BEGIN v_actor := auth.uid(); EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;

  SELECT * INTO v_event FROM public.inbox_events WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inbox event % not found', p_event_id;
  END IF;
  IF v_event.decision IS NOT NULL THEN
    RAISE EXCEPTION 'inbox event % already decided as %', p_event_id, v_event.decision;
  END IF;
  IF v_event.candidate_id IS NULL THEN
    RAISE EXCEPTION 'inbox event % has no candidate', p_event_id;
  END IF;

  IF p_decision = 'archived' THEN
    PERFORM public.archive_candidate(v_event.candidate_id, p_archive_reason, v_batch);
  ELSIF p_decision IN ('community', 'launchpad', 'fellowship') THEN
    IF p_actions IS NULL OR jsonb_typeof(p_actions) <> 'array' OR jsonb_array_length(p_actions) = 0 THEN
      RAISE EXCEPTION 'decision % needs member actions', p_decision;
    END IF;

    -- A new application from an archived candidate is how they come back.
    SELECT archived_at IS NOT NULL INTO v_archived
    FROM public.candidates WHERE candidate_id = v_event.candidate_id;
    IF v_archived THEN
      PERFORM public.unarchive_candidate(v_event.candidate_id, 'reapplied');
    END IF;

    PERFORM public.apply_member_actions(
      v_event.candidate_id,
      p_actions,
      p_note,
      jsonb_build_object('inbox_event_id', p_event_id),
      v_batch
    );
  ELSE
    RAISE EXCEPTION 'unknown decision %', p_decision;
  END IF;

  UPDATE public.inbox_events
  SET decision          = p_decision,
      decided_by        = v_actor,
      decided_at        = now(),
      decision_note     = p_note,
      decision_batch_id = v_batch,
      status            = 'reviewed',
      reviewed_at       = COALESCE(reviewed_at, now()),
      reviewed_by       = COALESCE(reviewed_by, v_actor)
  WHERE event_id = p_event_id;

  -- The decision is about the person, not the form: close their other
  -- undecided applications with it (e.g. a community and a fellowship form).
  UPDATE public.inbox_events
  SET decision          = p_decision,
      decided_by        = v_actor,
      decided_at        = now(),
      decision_note     = p_note,
      decision_batch_id = v_batch,
      status            = 'reviewed',
      reviewed_at       = COALESCE(reviewed_at, now()),
      reviewed_by       = COALESCE(reviewed_by, v_actor)
  WHERE candidate_id = v_event.candidate_id
    AND event_id <> p_event_id
    AND decision IS NULL
    AND event_type IN ('exponential_application', 'fellowship_application',
                       'community_application', 'manual_addition');

  RETURN jsonb_build_object('batch_id', v_batch, 'decision', p_decision);
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_inbox_event(uuid, text, jsonb, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.resolve_inbox_event(uuid, text, jsonb, text, text) TO authenticated, service_role;
-- ----------------------------------------------------------------------------
-- 2. Enrichment status
--
-- Written by the app's enrichment runner (service role). queued -> running ->
-- done | failed. NULL means never attempted.
-- ----------------------------------------------------------------------------

ALTER TABLE public.candidates
  ADD COLUMN IF NOT EXISTS enrichment_status      text
    CHECK (enrichment_status IN ('queued', 'running', 'done', 'failed')),
  ADD COLUMN IF NOT EXISTS enrichment_started_at  timestamptz,
  ADD COLUMN IF NOT EXISTS enrichment_finished_at timestamptz,
  ADD COLUMN IF NOT EXISTS enrichment_error       text;
-- Atomically take a candidate for enrichment. True if this caller got it:
-- nobody is running it, or the running attempt is older than p_stale_after
-- (the process died mid-run).
CREATE OR REPLACE FUNCTION public.claim_enrichment(
  p_candidate_id uuid,
  p_stale_after  interval DEFAULT interval '15 minutes'
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH claimed AS (
    UPDATE public.candidates
    SET enrichment_status     = 'running',
        enrichment_started_at = now(),
        enrichment_error      = NULL
    WHERE candidate_id = p_candidate_id
      AND (enrichment_status IS DISTINCT FROM 'running'
           OR enrichment_started_at < now() - p_stale_after)
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM claimed);
$$;
REVOKE ALL ON FUNCTION public.claim_enrichment(uuid, interval) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_enrichment(uuid, interval) TO service_role;
CREATE INDEX IF NOT EXISTS idx_candidates_enrichment_pending
  ON public.candidates (enrichment_status)
  WHERE enrichment_status IS NULL OR enrichment_status IN ('queued', 'failed');
-- ----------------------------------------------------------------------------
-- 3. Email templates per action
--
-- Existing templates are linked by name; the three that had no template are
-- inserted as drafts to edit in Settings. Placeholders: {candidate_name},
-- {first_name}, {last_name}, {candidate_id}, {url}.
-- ----------------------------------------------------------------------------

UPDATE public.email_templates SET action_key = 'archive_generic'            WHERE name = 'Standard Rejection'         AND action_key IS NULL;
UPDATE public.email_templates SET action_key = 'launchpad_invite'           WHERE name = 'Launchpad Invite'           AND action_key IS NULL;
UPDATE public.email_templates SET action_key = 'launchpad_invite_interview' WHERE name = 'Launchpad Interview Invite' AND action_key IS NULL;
UPDATE public.email_templates SET action_key = 'fellowship_invite'          WHERE name = 'First Interview'            AND action_key IS NULL;
UPDATE public.email_templates SET action_key = 'interview_invite'           WHERE name = 'Second Interview'           AND action_key IS NULL;
INSERT INTO public.email_templates (name, subject, body, action_key)
SELECT v.name, v.subject, v.body, v.action_key
FROM (VALUES
  ('Community Invite',
   'Welcome to the Exponential Community, {first_name}!',
   E'Hi {first_name},\n\nCongrats! We''re excited to welcome you to the Exponential Community.\n\nJoin our [WhatsApp Group](https://chat.whatsapp.com/E7HWX6GTKsMHClE4nCjprU) to access all community benefits including:\n- Networking opportunities with fellow members\n- Priority invitations to events and workshops\n- Direct access to startup opportunities\n\nExcited to see you around,\n\nThe Exponential Team',
   'community_invite'),
  ('Rejection: Too Senior',
   '[Exponential] Update regarding your application',
   E'Dear {candidate_name},\n\nThanks for your time applying to Exponential. Exponential is built for builders at the very start of their careers, and based on your experience we don''t think we''re the right fit for where you are today.\n\nWe''re sure you''ll keep building great things, and we''d love to stay in touch.\n\nBest,',
   'archive_too_old'),
  ('Rejection: No Spanish Ties',
   '[Exponential] Update regarding your application',
   E'Dear {candidate_name},\n\nThanks for your time applying to Exponential. Exponential focuses on builders with ties to Spain, and from your application we couldn''t find that connection.\n\nIf we missed something, just reply to this email and tell us about it.\n\nBest,',
   'archive_no_spanish_ties'),
  ('Launchpad Welcome',
   'Welcome to Launchpad, {first_name}!',
   E'Hi {first_name},\n\nThank you for opting in to the Exponential Launchpad program! We''re excited to help you land a job at the best startups in Spain and Europe.\n\nTo get started, we kindly ask you to add a README.md to a new repo in your GitHub called "exponential". You can check out an example structure [here](https://github.com/goexponential/exponential).\n\nOptionally, but highly recommended, please reply to this email with a demo of the 2-3 projects you''d like to showcase. Tell us:\n- Title\n- Description\n- Video link (YouTube, Loom, Vimeo...)\n- If it can be tested (extra points!), a link to access it\n\nThe end result will look something like [this](https://signal.goexponential.org/public/guli-moreno).\n\nIdeally, this should happen within the next 10 days. Reply back once you are ready. We''re excited to see what you prepare!\n\nBest regards,\nThe Exponential Team',
   'launchpad_opted_in')
) AS v(name, subject, body, action_key)
WHERE NOT EXISTS (SELECT 1 FROM public.email_templates t WHERE t.action_key = v.action_key);
-- ----------------------------------------------------------------------------
-- 4. Retire funnels and the Launchpad watchlist
--
-- The funnels (Cohort #01, Cohort #02, Launchpad '25) and the Launchpad
-- watchlist predate member tracks, which now hold that information (the
-- backfill carries their history over). Archived, not deleted: assignments
-- stay on record and they can be restored from Settings.
-- ----------------------------------------------------------------------------

UPDATE public.projects
SET is_deprecated = true
WHERE kind = 'funnel'
   OR (kind = 'watchlist' AND name = 'Launchpad');
COMMIT;
