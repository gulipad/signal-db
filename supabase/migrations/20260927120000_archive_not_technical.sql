-- ============================================================================
-- ARCHIVE REASON: NOT TECHNICAL ENOUGH
--
-- A fourth rejection email for the inbox's Archive menu, for applicants whose
-- work isn't hands-on building in code. Allows the action_key and adds the
-- template; the text can be edited from Settings like the others.
-- ============================================================================

BEGIN;
ALTER TABLE public.email_templates
  DROP CONSTRAINT IF EXISTS email_templates_action_key_check;
ALTER TABLE public.email_templates
  ADD CONSTRAINT email_templates_action_key_check CHECK (action_key IS NULL OR action_key IN (
    'archive_generic',              -- archive: generic rejection
    'archive_too_old',              -- archive: too senior / too old for the program
    'archive_no_spanish_ties',      -- archive: no ties to Spain
    'archive_not_technical',        -- archive: not technical enough
    'community_invite',
    'launchpad_invite',             -- launchpad invite with opt-in link
    'launchpad_invite_interview',   -- launchpad invite + interview scheduling
    'launchpad_opted_in',           -- instructions, sent automatically on opt-in
    'fellowship_invite',            -- fellowship invite + interview scheduling
    'interview_invite'              -- repeat interview invite from the candidate view
  ));
INSERT INTO public.email_templates (name, subject, body, action_key)
SELECT
  'Rejection: Not Technical Enough',
  '[Exponential] Update regarding your application',
  E'Dear {candidate_name},\n\nThanks for your time applying to Exponential. The Fellowship is geared towards people who dream in code: builders who spend their days (and often their nights) writing software and shipping what they make. From your application, we don''t think that''s where you are today, so we don''t think the Fellowship is the right fit right now.\n\nIf we missed something, like projects or code that weren''t in your application, just reply to this email and tell us about it.\n\nBest,',
  'archive_not_technical'
WHERE NOT EXISTS (
  SELECT 1 FROM public.email_templates WHERE action_key = 'archive_not_technical'
);
COMMIT;
