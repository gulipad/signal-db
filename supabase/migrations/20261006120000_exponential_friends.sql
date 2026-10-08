-- ============================================================================
-- EXPONENTIAL FRIENDS
--
-- Industry people and friends who get Exponential update emails: investors,
-- partner-startup founders, evaluators, academics, institutions and community
-- builders. Seeded from guli@goexponential.org correspondence, excluding anyone
-- already tracked in `candidates`.
--
-- Lives in a `private` schema on purpose:
--   - PostgREST and pg_graphql only expose `public`, so no API key (anon,
--     authenticated, or service_role) can reach these tables over HTTP.
--   - No grants to anon, authenticated, or service_role at all; only the
--     owner (postgres) can read or write. Access is direct SQL: the Supabase
--     MCP connector, the dashboard SQL editor, or the CLI.
--   - RLS is enabled with no policies as a second line: if a grant is ever
--     added by mistake, non-owner roles still see zero rows.
--
-- One person, many addresses: people live in `exponential_friends`, addresses
-- in `exponential_friend_emails`. An address is unique across the whole list
-- (case-insensitive) and each person has at most one primary address, which
-- is where updates are sent.
-- ============================================================================

BEGIN;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated, service_role;
-- Supabase's default privileges hand new objects to the API roles. Make sure
-- nothing created in `private` inherits them.
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE ALL ON TABLES    FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;
-- ----------------------------------------------------------------------------
-- People
-- ----------------------------------------------------------------------------

CREATE TABLE private.exponential_friends (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name     text,
  last_name      text,
  phone          text,
  company        text,
  position       text,
  category       text CHECK (category IN (
                   'investor', 'founder', 'operator', 'evaluator', 'academic',
                   'institution', 'corporate', 'media', 'community', 'personal', 'other'
                 )),
  why_relevant   text,
  relationship   text,
  source         text NOT NULL DEFAULT 'gmail',
  last_contacted date,
  subscribed     boolean NOT NULL DEFAULT true,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE private.exponential_friends IS
  'People who receive Exponential updates. Candidates live in public.candidates, not here. Addresses live in private.exponential_friend_emails.';
CREATE TRIGGER trg_exponential_friends_touch_updated_at
  BEFORE UPDATE ON private.exponential_friends
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
-- ----------------------------------------------------------------------------
-- Addresses
-- ----------------------------------------------------------------------------

CREATE TABLE private.exponential_friend_emails (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  friend_id  uuid NOT NULL REFERENCES private.exponential_friends(id) ON DELETE CASCADE,
  email      text NOT NULL CHECK (email = lower(btrim(email)) AND email LIKE '_%@_%.__%'),
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE private.exponential_friend_emails IS
  'Every known address of a friend. Unique across the list; one primary per friend is the sending address.';
-- An address belongs to exactly one person.
CREATE UNIQUE INDEX exponential_friend_emails_email_key
  ON private.exponential_friend_emails (email);
-- At most one primary address per person.
CREATE UNIQUE INDEX exponential_friend_emails_one_primary
  ON private.exponential_friend_emails (friend_id) WHERE is_primary;
CREATE INDEX exponential_friend_emails_friend_id_idx
  ON private.exponential_friend_emails (friend_id);
-- ----------------------------------------------------------------------------
-- Mailing view: one row per subscribed person, at their primary address
-- ----------------------------------------------------------------------------

CREATE VIEW private.exponential_friends_mailing
WITH (security_invoker = true) AS
SELECT f.id, f.first_name, f.last_name, e.email, f.company, f.category
FROM private.exponential_friends f
JOIN private.exponential_friend_emails e ON e.friend_id = f.id AND e.is_primary
WHERE f.subscribed;
-- ----------------------------------------------------------------------------
-- Lock down
-- ----------------------------------------------------------------------------

ALTER TABLE private.exponential_friends       ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.exponential_friend_emails ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.exponential_friends, private.exponential_friend_emails, private.exponential_friends_mailing
  FROM PUBLIC, anon, authenticated, service_role;
COMMIT;
