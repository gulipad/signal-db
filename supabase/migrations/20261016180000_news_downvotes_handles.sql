-- ============================================================================
-- Exponential News: downvotes for everyone, and handles that can change.
--
-- Downvotes were Hacker News' (comments only, from 200 points, never a reply
-- to you): on News, with its few points, that was nobody. Now any member
-- downvotes any post or comment that isn't theirs. Within the hour a vote
-- can change its mind (up to down, down to up); after it, it stays, as an
-- upvote always has.
--
-- A handle could never change. Now it can, once every 30 days. The old one
-- stays its owner's: their old links lead to who they are now, and nobody
-- else can take it (they can take it back).
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- Downvotes
-- ----------------------------------------------------------------------------

create or replace function news.vote_item(p_item bigint, p_dir int)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  i  news.items;
  v  news.votes;
begin
  select * into i from news.items where id = p_item;
  if i.id is null or i.dead or i.deleted or p_dir not in (1, -1) or i."by" = me.id
     or i.visible_at > now() or (i.gated and not news.sees_gated()) then
    return false;
  end if;
  -- Changing its mind: the vote it had goes first, within its hour.
  select * into v from news.votes where user_id = me.id and item_id = p_item;
  if v.user_id is not null then
    if v.dir = p_dir or not news.unvote_item(p_item) then
      return false;
    end if;
  end if;
  return news_private.cast_vote(me.id, p_item, p_dir);
end
$$;

-- ----------------------------------------------------------------------------
-- Handles
-- ----------------------------------------------------------------------------

alter table news.profiles add column username_changed_at timestamptz;

-- Every handle someone has left, in lower case: whose it stays.
create table news.past_usernames (
  username    text primary key check (username = lower(username)),
  profile_id  uuid not null references news.profiles (id) on delete cascade,
  changed_at  timestamptz not null default now()
);
alter table news.past_usernames owner to news_owner;
alter table news.past_usernames enable row level security;
revoke all on news.past_usernames from public, anon, authenticated;

-- Free: nobody has it, and nobody else had it.
create or replace function news.username_available(p_username text) returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select not exists (select 1 from news.profiles p where lower(p.username) = lower(p_username))
     and not exists (select 1 from news.past_usernames h
                      where h.username = lower(p_username) and h.profile_id is distinct from news.uid())
$$;

-- Joining can't take someone's old handle.
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
  if exists (select 1 from news.past_usernames where username = lower(p_username)) then
    raise exception 'taken' using errcode = '22023';
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

-- Change one's handle: on the profile, and on everything they wrote.
create function news.change_username(p_username text) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
begin
  if p_username is null or p_username !~ '^[A-Za-z0-9_][A-Za-z0-9_-]{1,14}$' then
    raise exception 'name' using errcode = '22023';
  end if;
  if p_username = me.username then
    return;
  end if;
  if me.username_changed_at > now() - interval '30 days' then
    raise exception 'soon' using errcode = '22023';
  end if;
  if exists (select 1 from news.past_usernames where username = lower(p_username) and profile_id <> me.id) then
    raise exception 'taken' using errcode = '22023';
  end if;
  begin
    update news.profiles set username = p_username, username_changed_at = now() where id = me.id;
  exception when unique_violation then
    raise exception 'taken' using errcode = '22023';
  end;
  if lower(me.username) <> lower(p_username) then
    insert into news.past_usernames (username, profile_id) values (lower(me.username), me.id)
    on conflict (username) do update set profile_id = excluded.profile_id, changed_at = now();
    delete from news.past_usernames where username = lower(p_username);
  end if;
  update news.items set by_name = p_username where "by" = me.id;
end
$$;

-- Who an old handle is now, so its links still lead somewhere.
create function news.username_now(p_username text) returns text
language sql stable
security definer
set search_path = ''
as $$
  select p.username from news.past_usernames h join news.profiles p on p.id = h.profile_id
   where h.username = lower(p_username)
$$;

-- When one's handle can change again; null when it can now.
create function news.username_change_after() returns timestamptz
language sql stable
security definer
set search_path = ''
as $$
  select p.username_changed_at + interval '30 days' from news.profiles p
   where p.id = news.uid() and p.username_changed_at > now() - interval '30 days'
$$;

-- ----------------------------------------------------------------------------
-- Owners and grants
-- ----------------------------------------------------------------------------

alter function news.change_username(text) owner to news_owner;
alter function news.username_now(text) owner to news_owner;
alter function news.username_change_after() owner to news_owner;

revoke all on function news.change_username(text), news.username_now(text), news.username_change_after()
from public, anon, authenticated, service_role;
grant execute on function news.username_now(text) to anon, authenticated;
grant execute on function news.change_username(text), news.username_change_after() to authenticated;

commit;
