-- ============================================================================
-- Exponential News: staff.
--
-- Exponential's staff use the same login on News as on Signal, and moderate
-- News. A News profile whose user is on Signal's staff list (public.staff)
-- is staff on News: an admin, and it can wear a "staff" mark on what it
-- posts (its hat, like the program badges). Leaving the staff list ends
-- both, within a minute (the news-signal-badges job).
--
-- Signal's list stays the one source. News reads it through
-- news_private.signal_staff(), owned by postgres and callable only by
-- news_owner, which still has no privilege on public.staff itself.
-- ============================================================================

begin;

alter table news.profiles add column staff boolean not null default false;
grant select (staff) on news.profiles to anon, authenticated;

-- Who is on Signal's staff list. Nothing else about them.
create function news_private.signal_staff() returns setof uuid
language sql stable
security definer
set search_path = ''
as $$
  select s.user_id from public.staff s where s.user_id is not null
$$;
revoke all on function news_private.signal_staff() from public, anon, authenticated, service_role;
grant execute on function news_private.signal_staff() to news_owner;

-- Bring News in line with the list: staff are admins while they're staff.
-- Only rows whose staff status changes are touched, so an admin made by hand
-- (not staff) stays one. Returns how many changed.
create function news_private.apply_staff(p_user uuid default null) returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  with listed as (select news_private.signal_staff() as id)
  update news.profiles p
     set staff = s.on_list, is_admin = s.on_list
    from (select p2.id, p2.id in (select l.id from listed l) as on_list
          from news.profiles p2
          where p_user is null or p2.id = p_user) s
   where p.id = s.id and p.staff is distinct from s.on_list;
  get diagnostics n = row_count;
  return n;
end
$$;
alter function news_private.apply_staff(uuid) owner to news_owner;
revoke all on function news_private.apply_staff(uuid) from public, anon, authenticated, service_role;

-- A new profile learns at once whether it is staff.
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
  perform news_private.apply_staff(uid);
end
$$;

-- The private fields of a profile, now with staff.
drop function news.profile_private(uuid);
create function news.profile_private(p_id uuid default null)
returns table (
  id uuid, username text, created_at timestamptz, karma int, about text,
  github text, linkedin text, badge text, is_admin boolean, auth int, ignored boolean,
  showdead boolean, noprocrast boolean, firstview timestamptz, lastview timestamptz,
  maxvisit int, minaway int, topcolor text, delay int, staff boolean
)
language sql stable
security definer
set search_path = ''
as $$
  with v as (
    select coalesce(bool_or(p.is_admin or p.auth > 0), false) as editor
    from news.profiles p where p.id = news.uid()
  )
  select p.id, p.username, p.created_at, p.karma, p.about, p.github, p.linkedin, p.badge,
         p.is_admin, p.auth, case when v.editor then p.ignored else false end,
         p.showdead, p.noprocrast, p.firstview, p.lastview, p.maxvisit, p.minaway, p.topcolor, p.delay,
         p.staff
  from news.profiles p, v
  where p.id = coalesce(p_id, news.uid())
    and (p.id = news.uid() or v.editor)
$$;
alter function news.profile_private(uuid) owner to news_owner;
revoke all on function news.profile_private(uuid) from public, anon, authenticated, service_role;
grant execute on function news.profile_private(uuid) to anon, authenticated;

-- Every minute, with the badges.
select cron.unschedule(jobid) from cron.job where jobname = 'news-signal-badges';
select cron.schedule(
  'news-signal-badges',
  '* * * * *',
  'select news_private.sync_signal_members(); select news_private.apply_badges(); select news_private.apply_staff();'
);

commit;
