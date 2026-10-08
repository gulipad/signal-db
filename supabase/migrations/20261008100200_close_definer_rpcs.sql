-- ============================================================================
-- TAKE THE COMMUNITY'S SECURITY DEFINER FUNCTIONS OFF THE API
--
-- The security advisor reported 15 SECURITY DEFINER functions in `public`
-- that anyone with the publishable key could call at /rest/v1/rpc/<name>.
-- They run as postgres, past RLS:
--
--   * trigger functions (handle_new_user, update_community_member_count,
--     update_community_post_count, update_post_comment_count,
--     project_intro_activity, record_bucket_transition): calling one over RPC
--     only errors, but there's no reason to offer it. EXECUTE is revoked;
--     triggers fire regardless of EXECUTE.
--   * helpers: get_community_type, is_community_admin, is_community_member,
--     is_community_moderator, is_user_banned (which deletes expired bans),
--     user_has_role, get_user_roles. They answer questions about anyone's
--     memberships and roles. Several are used inside the community tables'
--     RLS policies, which anon also evaluates, so revoking EXECUTE would
--     break those tables. Instead they move to `community_private`, a schema
--     the Data API doesn't expose: policies refer to functions by OID and keep
--     working, and nothing can call them over HTTP.
--
-- Each helper gets a fixed search_path (the advisor's other warning); their
-- bodies use public tables unqualified.
--
-- Checked first (2026-10-08): no /rest/v1/rpc/ call to any of these on
-- Oct 1, Oct 4-5 or Oct 7-8; no function calls the helpers.
-- ============================================================================

begin;

revoke all on function
  public.handle_new_user(),
  public.update_community_member_count(),
  public.update_community_post_count(),
  public.update_post_comment_count(),
  public.project_intro_activity(),
  public.record_bucket_transition()
from public, anon, authenticated;

-- The community's SECURITY DEFINER triggers also get a fixed search_path.
alter function public.update_community_member_count() set search_path = public;
alter function public.update_community_post_count() set search_path = public;
alter function public.update_post_comment_count() set search_path = public;

create schema if not exists community_private;
comment on schema community_private is
  'Helpers for the community tables'' RLS policies. Not exposed through the Data API.';
-- No USAGE for the API roles: policies call these functions by OID, which
-- needs EXECUTE on the function but not access to the schema.
revoke all on schema community_private from public;
alter default privileges in schema community_private revoke all on functions from public;

alter function public.get_community_type(uuid) set schema community_private;
alter function public.is_community_admin(uuid, uuid) set schema community_private;
alter function public.is_community_admin(uuid) set schema community_private;
alter function public.is_community_member(uuid, uuid) set schema community_private;
alter function public.is_community_moderator(uuid, uuid) set schema community_private;
alter function public.is_community_moderator(uuid) set schema community_private;
alter function public.is_user_banned(uuid, uuid) set schema community_private;
alter function public.user_has_role(uuid, text) set schema community_private;
alter function public.get_user_roles(uuid) set schema community_private;

alter function community_private.get_community_type(uuid) set search_path = public;
alter function community_private.is_community_admin(uuid, uuid) set search_path = public;
alter function community_private.is_community_admin(uuid) set search_path = public;
alter function community_private.is_community_member(uuid, uuid) set search_path = public;
alter function community_private.is_community_moderator(uuid, uuid) set search_path = public;
alter function community_private.is_community_moderator(uuid) set search_path = public;
alter function community_private.is_user_banned(uuid, uuid) set search_path = public;
alter function community_private.user_has_role(uuid, text) set search_path = public;
alter function community_private.get_user_roles(uuid) set search_path = public;

-- Only what the policies use stays executable by the API roles.
revoke all on all functions in schema community_private from public, anon, authenticated;
grant execute on function
  community_private.get_community_type(uuid),
  community_private.is_community_admin(uuid, uuid),
  community_private.is_community_member(uuid, uuid),
  community_private.is_community_moderator(uuid, uuid)
to anon, authenticated;
grant execute on all functions in schema community_private to service_role;

commit;
