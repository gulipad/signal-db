-- ============================================================================
-- ARCHIVE REASON: LOW-EFFORT APPLICATION
--
-- A fifth rejection email for the inbox's Archive menu, for applications that
-- were clearly rushed. Allows the action_key and adds the template; the text
-- can be edited from Settings like the others.
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
    'archive_low_effort',           -- archive: low-effort application
    'community_invite',
    'launchpad_invite',             -- launchpad invite with opt-in link
    'launchpad_invite_interview',   -- launchpad invite + interview scheduling
    'launchpad_opted_in',           -- instructions, sent automatically on opt-in
    'fellowship_invite',            -- fellowship invite + interview scheduling
    'interview_invite'              -- repeat interview invite from the candidate view
  ));
INSERT INTO public.email_templates (name, subject, body, action_key)
SELECT
  'Rejection: Low Effort',
  '[Exponential] Update regarding your application',
  E'Dear {candidate_name},\n\nWe don''t accept low-effort applications, no matter how great you (think) you are. If you don''t spend time on your application, we won''t spend time on you.\n\nYou can try again in a few weeks.\n\nBest,',
  'archive_low_effort'
WHERE NOT EXISTS (
  SELECT 1 FROM public.email_templates WHERE action_key = 'archive_low_effort'
);
COMMIT;
