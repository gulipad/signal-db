-- ============================================================================
-- Exponential News: a News login never carries Signal access.
--
-- News and Signal share Supabase Auth. A Signal staff member who logged in
-- to News would hold, in News' cookies, a session that public.is_staff()
-- accepts: the same user, so the same access to every candidate. So News
-- refuses staff accounts: right after every login the app asks
-- news.is_signal_staff() and signs staff straight out (app/auth/confirm and
-- lib/actions.ts in exponential-news), and news.claim_profile() refuses them,
-- so no staff account can hold a News profile either. Staff use another
-- email on News.
-- ============================================================================

begin;

-- One question, about the caller only. Owned by postgres: news_owner can't
-- read public.staff, and must not be able to.
create function news.is_signal_staff() returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.staff s where s.user_id = news.uid())
$$;
revoke all on function news.is_signal_staff() from public, anon, authenticated, service_role;
grant execute on function news.is_signal_staff() to authenticated, news_owner;

create or replace function news.claim_profile(p_username text) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := news.uid();
begin
  if uid is null then
    raise exception 'login' using errcode = '42501';
  end if;
  if news.is_signal_staff() then
    raise exception 'staff' using errcode = '42501';
  end if;
  if exists (select 1 from news.profiles where id = uid) then
    return;
  end if;
  if p_username is null or p_username !~ '^[A-Za-z0-9_][A-Za-z0-9_-]{1,14}$' then
    raise exception 'name' using errcode = '22023';
  end if;
  begin
    insert into news.profiles (id, username) values (uid, p_username);
  exception when unique_violation then
    raise exception 'taken' using errcode = '22023';
  end;
  perform news_private.apply_badges(uid);
end
$$;

commit;
