-- ============================================================================
-- SIGNAL: NO COMMUNITY PROFILES FOR NEWS ACCOUNTS
--
-- public.handle_new_user() gives every new auth user a row in public.profiles,
-- the old community site's profiles. Exponential News accounts are auth users
-- in the same project; their profile lives in news.profiles, and a community
-- profile would make them community-site users too. News signs people up with
-- user_metadata.signup_app = 'news'; those users get no community profile.
-- Everyone else is handled as in 20261008100100_protect_community_profiles.sql.
-- ============================================================================

begin;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.raw_user_meta_data ->> 'signup_app' = 'news' then
    return new;
  end if;
  insert into public.profiles (id, email, role)
  values (new.id, '', 'user')
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

commit;
