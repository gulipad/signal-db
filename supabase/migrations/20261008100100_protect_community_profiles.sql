-- ============================================================================
-- COMMUNITY PROFILES: NO EMAILS, NO SELF-PROMOTION
--
-- public.profiles (the old community site's profiles) is readable by anyone
-- with the publishable key ("Profiles are viewable by everyone", USING
-- (true)), and handle_new_user() copied every new auth user's email into it,
-- so every account's email address was public. Separately, "Users can update
-- own profile" lets a signed-in user set their own `role`, and 'fellow' is
-- what "Fellows can insert own data" checks before letting someone publish a
-- row in public.fellows.
--
-- Fix:
--   1. Stop copying emails, and blank the ones already copied. The address
--      stays in auth.users, its source of truth. The column keeps its
--      NOT NULL constraint and type, so nothing reading it breaks.
--   2. A trigger keeps the column blank whoever writes, and keeps API callers
--      (anon, authenticated) from setting `role`: new rows get 'user' and
--      updates keep the old value. Roles change from the dashboard or with the
--      service role, as before.
--
-- Checked first (2026-10-08): no request read or wrote public.profiles or
-- public.fellows through the Data API on Oct 1, Oct 4-5 or Oct 7-8.
-- ============================================================================

begin;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, '', 'user')
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.guard_profile_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Emails live in auth.users; this table is public.
  new.email := '';
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      new.role := 'user';
    else
      new.role := old.role;
    end if;
  end if;
  return new;
end;
$$;
comment on function public.guard_profile_columns() is
  'Keeps public.profiles.email blank and stops API callers from setting their own role.';

drop trigger if exists guard_profile_columns on public.profiles;
create trigger guard_profile_columns
  before insert or update on public.profiles
  for each row execute function public.guard_profile_columns();

-- Trigger functions can't be called over RPC anyway; don't advertise them.
revoke all on function public.handle_new_user(), public.guard_profile_columns()
  from public, anon, authenticated;

update public.profiles set email = '' where email <> '';

commit;
