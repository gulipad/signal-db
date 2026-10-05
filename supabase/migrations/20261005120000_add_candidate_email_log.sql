-- ============================================================================
-- Candidate email log
-- ============================================================================
-- Candidates write to hello@goexponential.org and the team answers from Gmail.
-- Nobody can see who already replied, so two people sometimes answer the same
-- email. Signal now reads the team's Gmail mailboxes (read-only, through a
-- Google Workspace service account with domain-wide delegation) and keeps a
-- copy of every message that has a candidate in From, To, Cc or Bcc. The
-- candidate page shows the full exchange, and who sent each reply.
--
-- Two tables:
--
--   email_messages        one row per email, keyed by its RFC 5322 Message-ID.
--                         The same email lands in many mailboxes (a message to
--                         hello@ reaches every member of the group); it is
--                         stored once.
--
--   email_message_copies  one row per mailbox that holds the email, with its
--                         Gmail ids and labels. The sync uses it to skip
--                         messages it already has. The SENT label on a copy
--                         tells which teammate sent a reply, also when they
--                         sent it "as" hello@.
--
-- Only messages with a candidate address are stored. The app writes with the
-- service role; staff can only read.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.email_messages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- RFC 5322 Message-ID, angle brackets included. The same in every mailbox.
  message_id    text NOT NULL UNIQUE,
  in_reply_to   text,
  "references"  text[] NOT NULL DEFAULT '{}',

  subject       text,
  from_address  text NOT NULL,
  from_name     text,
  to_addresses  text[] NOT NULL DEFAULT '{}',
  cc_addresses  text[] NOT NULL DEFAULT '{}',
  -- Every address on the email, lowercased: From, To, Cc, Bcc (Bcc is only
  -- known from the sender's copy). The candidate lookup reads this.
  participants  text[] NOT NULL DEFAULT '{}',

  sent_at       timestamptz NOT NULL,
  snippet       text,
  body_text     text,
  body_html     text,
  -- [{ part_id, filename, mime_type, size }]
  attachments   jsonb NOT NULL DEFAULT '[]'::jsonb,

  created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.email_messages IS
  'Emails between the team and candidates, read from Gmail. One row per Message-ID, however many mailboxes hold it.';

CREATE INDEX IF NOT EXISTS idx_email_messages_participants
  ON public.email_messages USING gin (participants);
CREATE INDEX IF NOT EXISTS idx_email_messages_sent_at
  ON public.email_messages (sent_at DESC);

CREATE TABLE IF NOT EXISTS public.email_message_copies (
  mailbox          text NOT NULL,
  gmail_message_id text NOT NULL,
  gmail_thread_id  text NOT NULL,
  email_id         uuid NOT NULL REFERENCES public.email_messages(id) ON DELETE CASCADE,
  labels           text[] NOT NULL DEFAULT '{}',
  synced_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (mailbox, gmail_message_id)
);

COMMENT ON TABLE public.email_message_copies IS
  'Where each stored email sits in Gmail: mailbox, Gmail ids, labels. A SENT label marks the mailbox that sent it.';

CREATE INDEX IF NOT EXISTS idx_email_message_copies_email
  ON public.email_message_copies (email_id);

-- Staff read; only the service role writes.
ALTER TABLE public.email_messages       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_message_copies ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.email_messages       FROM anon, authenticated;
REVOKE ALL ON public.email_message_copies FROM anon, authenticated;
GRANT SELECT ON public.email_messages       TO authenticated;
GRANT SELECT ON public.email_message_copies TO authenticated;
GRANT ALL    ON public.email_messages       TO service_role;
GRANT ALL    ON public.email_message_copies TO service_role;

DROP POLICY IF EXISTS staff_read_email_messages ON public.email_messages;
CREATE POLICY staff_read_email_messages ON public.email_messages
  FOR SELECT TO authenticated USING (public.is_staff());

DROP POLICY IF EXISTS staff_read_email_message_copies ON public.email_message_copies;
CREATE POLICY staff_read_email_message_copies ON public.email_message_copies
  FOR SELECT TO authenticated USING (public.is_staff());

COMMIT;
