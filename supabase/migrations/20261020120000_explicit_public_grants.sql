-- ============================================================================
-- NEW OBJECTS IN public NEED EXPLICIT GRANTS
--
-- From 2026-10-30 Supabase stops granting the Data API roles (anon,
-- authenticated, service_role) access to new tables, views and sequences in
-- "public" on existing projects; objects that already exist keep their grants
-- (https://github.com/orgs/supabase/discussions/45329).
--
-- 20260803200000_remote_baseline.sql came from `db pull` and replays the old
-- defaults (ALTER DEFAULT PRIVILEGES ... GRANT ALL ON TABLES/SEQUENCES TO
-- anon, authenticated, service_role), so a branch or `supabase db reset`
-- would keep auto-granting new objects while production stops. A migration
-- that forgets its grants would then work locally and fail in production.
-- These are Supabase's own opt-in statements: run after the earlier
-- migrations, they make every database built from this history behave like
-- production after the cutover. On production they are the change Supabase
-- makes on 2026-10-30, and they leave existing objects untouched.
--
-- From here on, a migration that creates a table, view or sequence in public
-- grants it in the same file, for example:
--
--   grant select, insert, update, delete on public.t to authenticated;
--   grant select, insert, update, delete on public.t to service_role;
--   grant select on public.t to anon;   -- only for data anonymous users read
--
-- plus `grant usage, select on sequence public.t_id_seq` to the roles that
-- insert, for serial columns (identity columns need nothing).
-- ============================================================================

alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke usage, select on sequences from anon, authenticated, service_role;
