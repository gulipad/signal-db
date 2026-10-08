-- ============================================================================
-- EXPONENTIAL NEWS: BADGES FROM SIGNAL
--
-- People Exponential accepted into the community, Launchpad or the Fellowship
-- get a badge on News, and an account waiting for them: the first time they
-- log in with the email Signal has for them, their profile carries the badge.
--
-- Who counts as accepted:
--   * live: Signal sent them an acceptance email (candidate_activities,
--     email_sent, with a template listed in news_private.badge_rules), and
--   * history: the track log says so (community joined, launchpad opted_in or
--     accepted, fellowship accepted), which covers everyone accepted before
--     those templates existed and the Fellowship, which has none.
-- Archived candidates, and people who left the community, get no badge.
-- Delete the 'track_stage' rows of badge_rules to count emails only.
--
-- The bridge is one way and runs on a schedule, not on Signal's triggers, so
-- nothing on Signal's write path depends on News:
--
--   pg_cron, every minute
--     news_private.sync_signal_members()   runs as news_bridge: reads three
--         Signal tables (only the columns granted below), writes
--         news_private.signal_members (candidate id, email, badges).
--     news_private.apply_badges()          runs as news_owner: sets
--         news.profiles.badge for accounts whose confirmed email matches.
--
-- news_bridge can read nothing else in Signal and write nothing in Signal.
-- news_owner never reads Signal tables, only signal_members.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- What the bridge may read in Signal
-- ----------------------------------------------------------------------------

grant usage on schema public to news_bridge;
grant select (candidate_id, email, archived_at) on public.candidates to news_bridge;
grant select (candidate_id, activity_type, activity_timestamp, metadata)
  on public.candidate_activities to news_bridge;
grant select (candidate_id, track, stage, occurred_at, seq)
  on public.candidate_track_events to news_bridge;

-- Signal's policies only let staff read these tables; these let the bridge
-- see the rows its column grants allow, and nothing more.
create policy news_bridge_read on public.candidates
  for select to news_bridge using (true);
create policy news_bridge_read on public.candidate_activities
  for select to news_bridge using (activity_type = 'email_sent');
create policy news_bridge_read on public.candidate_track_events
  for select to news_bridge using (true);

-- ----------------------------------------------------------------------------
-- Bridge tables
-- ----------------------------------------------------------------------------

create table news_private.badge_rules (
  source  text not null check (source in ('email_template', 'track_stage')),
  key     text not null,   -- template name, or 'track:stage'
  badge   text not null check (badge in ('fellowship', 'launchpad', 'community')),
  primary key (source, key)
);
comment on table news_private.badge_rules is
  'Which Signal events mean someone was accepted, and into what.';

insert into news_private.badge_rules (source, key, badge) values
  ('email_template', 'community_invite',    'community'),
  ('email_template', 'launchpad_welcome',   'launchpad'),   -- before 2026-09-27
  ('email_template', 'launchpad_opted_in',  'launchpad'),
  ('track_stage',    'community:joined',    'community'),
  ('track_stage',    'launchpad:opted_in',  'launchpad'),
  ('track_stage',    'launchpad:accepted',  'launchpad'),
  ('track_stage',    'fellowship:accepted', 'fellowship');

create table news_private.signal_members (
  candidate_id  uuid primary key,
  email         text not null check (email = lower(btrim(email))),
  badges        text[] not null,
  accepted_at   timestamptz not null,
  synced_at     timestamptz not null default now()
);
create index signal_members_email on news_private.signal_members (email);
comment on table news_private.signal_members is
  'Accepted, unarchived Signal candidates: the minimum News needs to recognise them. Written by sync_signal_members().';

alter table news_private.badge_rules owner to news_owner;
alter table news_private.signal_members owner to news_owner;
alter table news_private.badge_rules enable row level security;
alter table news_private.signal_members enable row level security;

grant usage on schema news_private to news_bridge;
grant select on news_private.badge_rules to news_bridge;
grant select, insert, update, delete on news_private.signal_members to news_bridge;
create policy news_bridge_all on news_private.badge_rules
  for select to news_bridge using (true);
create policy news_bridge_all on news_private.signal_members
  for all to news_bridge using (true) with check (true);

-- ----------------------------------------------------------------------------
-- Sync: Signal -> news_private.signal_members (as news_bridge)
-- ----------------------------------------------------------------------------

create function news_private.sync_signal_members() returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
begin
  with accepted as (
    select a.candidate_id, r.badge, a.activity_timestamp as at
    from public.candidate_activities a
    join news_private.badge_rules r
      on r.source = 'email_template' and r.key = a.metadata ->> 'email_template'
    where a.activity_type = 'email_sent'
    union all
    select e.candidate_id, r.badge, e.occurred_at
    from public.candidate_track_events e
    join news_private.badge_rules r
      on r.source = 'track_stage' and r.key = e.track || ':' || e.stage
  ), community_now as (
    select distinct on (e.candidate_id) e.candidate_id, e.stage
    from public.candidate_track_events e
    where e.track = 'community'
    order by e.candidate_id, e.occurred_at desc, e.seq desc
  ), members as (
    select c.candidate_id,
           lower(btrim(c.email)) as email,
           array_agg(distinct x.badge order by x.badge) as badges,
           min(x.at) as accepted_at
    from accepted x
    join public.candidates c on c.candidate_id = x.candidate_id
    left join community_now l on l.candidate_id = x.candidate_id
    where c.archived_at is null
      and coalesce(btrim(c.email), '') <> ''
      and (x.badge <> 'community' or l.stage is distinct from 'left')
    group by c.candidate_id, c.email
  ), upserted as (
    insert into news_private.signal_members as m (candidate_id, email, badges, accepted_at, synced_at)
    select candidate_id, email, badges, accepted_at, now() from members
    on conflict (candidate_id) do update
      set email = excluded.email, badges = excluded.badges,
          accepted_at = excluded.accepted_at, synced_at = now()
      where (m.email, m.badges, m.accepted_at)
            is distinct from (excluded.email, excluded.badges, excluded.accepted_at)
    returning 1
  ), removed as (
    delete from news_private.signal_members m
    where not exists (select 1 from members x where x.candidate_id = m.candidate_id)
    returning 1
  )
  select (select count(*) from upserted) + (select count(*) from removed) into changed;
  return changed;
end
$$;
-- Changing owner needs CREATE on the schema; news_bridge keeps only USAGE.
grant create on schema news_private to news_bridge;
alter function news_private.sync_signal_members() owner to news_bridge;
revoke create on schema news_private from news_bridge;

-- ----------------------------------------------------------------------------
-- Badges: signal_members -> news.profiles (as news_owner)
-- ----------------------------------------------------------------------------

-- Confirmed emails of News accounts (or of one user, who may not have a
-- profile yet). Owned by postgres, the only role that can read auth.users;
-- news_owner may call it, nobody else.
create function news_private.confirmed_emails(p_id uuid default null)
returns table (id uuid, email text)
language sql stable
security definer
set search_path = ''
as $$
  select u.id, lower(btrim(u.email))
  from auth.users u
  where u.email_confirmed_at is not null and u.email is not null
    and (u.id = p_id
         or (p_id is null and exists (select 1 from news.profiles p where p.id = u.id)))
$$;

create function news_private.badge_for(p_id uuid) returns text
language sql stable
set search_path = ''
as $$
  select case when bool_or('fellowship' = any (m.badges)) then 'fellowship'
              when bool_or('launchpad' = any (m.badges)) then 'launchpad'
              when bool_or('community' = any (m.badges)) then 'community' end
  from news_private.confirmed_emails(p_id) u
  join news_private.signal_members m on m.email = u.email
$$;
alter function news_private.badge_for(uuid) owner to news_owner;

-- Every account, or one. Returns how many badges changed.
create function news_private.apply_badges(p_id uuid default null) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed integer;
begin
  with b as (
    select u.id,
           case when bool_or('fellowship' = any (m.badges)) then 'fellowship'
                when bool_or('launchpad' = any (m.badges)) then 'launchpad'
                when bool_or('community' = any (m.badges)) then 'community' end as badge
    from news_private.confirmed_emails(p_id) u
    join news_private.signal_members m on m.email = u.email
    group by u.id
  )
  update news.profiles p
     set badge = b.badge
    from news.profiles q
    left join b on b.id = q.id
   where p.id = q.id
     and (p_id is null or p.id = p_id)
     and p.badge is distinct from b.badge;
  get diagnostics changed = row_count;
  return changed;
end
$$;
alter function news_private.apply_badges(uuid) owner to news_owner;

-- ----------------------------------------------------------------------------
-- Claiming an account
-- ----------------------------------------------------------------------------

-- The badge waiting for the signed-in user, before they have a profile.
create function news.badge_preview() returns text
language sql stable
security definer
set search_path = ''
as $$
  select news_private.badge_for(news.uid())
$$;
alter function news.badge_preview() owner to news_owner;

-- Create the signed-in user's News profile. Accepted Signal candidates get
-- their badge at once.
create function news.claim_profile(p_username text) returns void
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
end
$$;
alter function news.claim_profile(text) owner to news_owner;

-- ----------------------------------------------------------------------------
-- Grants and schedule
-- ----------------------------------------------------------------------------

revoke all on function
  news_private.sync_signal_members(), news_private.confirmed_emails(uuid),
  news_private.badge_for(uuid), news_private.apply_badges(uuid),
  news.badge_preview(), news.claim_profile(text)
from public, anon, authenticated, service_role;

grant select on news_private.signal_members, news_private.badge_rules to news_owner;
grant execute on function news_private.confirmed_emails(uuid) to news_owner;
grant execute on function news.badge_preview(), news.claim_profile(text) to authenticated;
grant execute on function news_private.sync_signal_members(), news_private.apply_badges(uuid) to postgres;

select cron.unschedule(jobid) from cron.job where jobname = 'news-signal-badges';
select cron.schedule(
  'news-signal-badges',
  '* * * * *',
  'select news_private.sync_signal_members(); select news_private.apply_badges();'
);

-- First fill, so badges are right as soon as this is applied.
select news_private.sync_signal_members();

commit;
