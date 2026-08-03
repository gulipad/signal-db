-- ============================================================================
-- Restore table/sequence privileges for the Supabase roles
-- ============================================================================
-- Nothing in this migration set ever granted DML to `authenticated` or
-- `service_role`. The hosted database still carries those grants from when it
-- was provisioned, because Supabase's default privileges used to apply them to
-- every new table automatically. Current CLI versions no longer do, so a
-- database rebuilt purely from these migrations (local dev, `supabase db reset`,
-- CI) ends up with both roles holding only TRUNCATE/REFERENCES/TRIGGER — every
-- application query fails with `permission denied for table ...`.
--
-- Grants are additive and idempotent, so this is a no-op against the hosted DB.
--
-- `anon` is deliberately excluded: 20260208120000_lockdown_rls_policies.sql
-- revoked it from every internal table on purpose, and public traffic is served
-- through the service_role client. The single exception is testimonials, which
-- carries an `anon_select_published` policy and therefore needs SELECT.

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  TO authenticated, service_role;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public
  TO authenticated, service_role;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public
  TO authenticated, service_role;

-- The one anon-readable table; the policy still restricts rows to published.
GRANT SELECT ON TABLE public.testimonials TO anon;
