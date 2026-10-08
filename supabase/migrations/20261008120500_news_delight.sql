-- ============================================================================
-- Exponential News: what HN regulars reach for.
--
--   reads        when you last read each story, for "5 new" (the unread
--                ribbon: Lobste.rs has it; news.arc left it as a TODO)
--   favorites    keeping something without upvoting it (HN's "favorite";
--                public, as on HN)
--   nominations  readers nominate comments, privately; admins pick
--   highlights   the picked ones, at /highlights
--   pooled_at    the second-chance pool: an admin gives an overlooked
--                story another run on the front page
--   hat          whether a post wears its author's Exponential badge
--   settings     site-wide switches an admin flips (the top bar's colour)
--   Launch EN    one launch per Exponential company, members only
--
-- Reads go through row level security; every write is a function below.
-- ============================================================================

begin;

create table news.reads (
  user_id   uuid not null references news.profiles on delete cascade,
  item_id   bigint not null references news.items on delete cascade,
  seen_at   timestamptz not null default now(),
  primary key (user_id, item_id)
);

create table news.favorites (
  user_id     uuid not null references news.profiles on delete cascade,
  item_id     bigint not null references news.items on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index favorites_item on news.favorites (item_id);

create table news.nominations (
  user_id     uuid not null references news.profiles on delete cascade,
  item_id     bigint not null references news.items on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index nominations_item on news.nominations (item_id);

create table news.highlights (
  item_id     bigint primary key references news.items on delete cascade,
  created_at  timestamptz not null default now()
);

create table news.settings (
  key    text primary key check (key in ('bar_color')),
  value  text not null
);

alter table news.items
  add column pooled_at timestamptz,
  add column hat boolean not null default true;

alter table news.reads owner to news_owner;
alter table news.favorites owner to news_owner;
alter table news.nominations owner to news_owner;
alter table news.highlights owner to news_owner;
alter table news.settings owner to news_owner;

alter table news.reads enable row level security;
alter table news.favorites enable row level security;
alter table news.nominations enable row level security;
alter table news.highlights enable row level security;
alter table news.settings enable row level security;

create policy reads_read on news.reads
  for select to authenticated using (user_id = news.uid());
create policy favorites_read on news.favorites
  for select to anon, authenticated using (true);
create policy nominations_read on news.nominations
  for select to authenticated using (user_id = news.uid() or news.is_admin());
create policy highlights_read on news.highlights
  for select to anon, authenticated using (true);
create policy settings_read on news.settings
  for select to anon, authenticated using (true);

grant select on news.reads, news.nominations to authenticated;
grant select on news.favorites, news.highlights, news.settings to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Reading
-- ----------------------------------------------------------------------------

-- Opening a story: remember when, and say when it was last opened (null the
-- first time), so the page can mark what's new since.
create function news.mark_read(p_story bigint)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  me   uuid := news.uid();
  prev timestamptz;
begin
  if me is null or not exists (select 1 from news.profiles where id = me)
     or not exists (select 1 from news.items where id = p_story and type = 'story') then
    return null;
  end if;
  select r.seen_at into prev from news.reads r where r.user_id = me and r.item_id = p_story;
  insert into news.reads (user_id, item_id, seen_at) values (me, p_story, now())
  on conflict (user_id, item_id) do update set seen_at = excluded.seen_at;
  return prev;
end
$$;

-- Comments by others that showed up since the caller last read each story.
-- Stories they never opened have no count: everything there is new.
create function news.unread_counts(p_ids bigint[])
returns table (root_id bigint, n bigint)
language sql stable
set search_path = ''
as $$
  select c.root_id, count(*)
  from news.items c
  join news.reads r on r.item_id = c.root_id and r.user_id = news.uid()
  where c.root_id = any (p_ids) and c.type = 'comment'
    and not c.dead and not c.deleted
    and c.visible_at > r.seen_at and c."by" <> news.uid()
  group by c.root_id
$$;

-- A story's votes in order, for the curve on its shared card: minutes after
-- posting, and the running total.
create function news.points_curve(p_item bigint)
returns table (minutes int, points int)
language sql stable
security definer
set search_path = ''
as $$
  select (extract(epoch from (v.created_at - i.created_at)) / 60)::int,
         (sum(v.dir) over (order by v.created_at, v.user_id))::int
  from news.items i
  join news.votes v on v.item_id = i.id
  where i.id = p_item and i.type = 'story' and not i.dead and not i.deleted and i.visible_at <= now()
  order by v.created_at, v.user_id
  limit 2000
$$;

-- ----------------------------------------------------------------------------
-- Keeping and recognising
-- ----------------------------------------------------------------------------

create function news.toggle_favorite(p_item bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  i  news.items;
begin
  select * into i from news.items where id = p_item;
  if i.id is null or i.deleted or not (i.visible_at <= now() or i."by" = me.id) then
    raise exception 'noitem' using errcode = '22023';
  end if;
  if exists (select 1 from news.favorites where user_id = me.id and item_id = p_item) then
    delete from news.favorites where user_id = me.id and item_id = p_item;
    return false;
  end if;
  insert into news.favorites (user_id, item_id) values (me.id, p_item);
  return true;
end
$$;

-- Readers nominate someone else's comment for /highlights. Only the reader
-- and admins see a nomination.
create function news.toggle_nomination(p_item bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  i  news.items;
begin
  select * into i from news.items where id = p_item;
  if i.id is null or i.type <> 'comment' or i."by" = me.id or i.dead or i.deleted
     or not (i.visible_at <= now()) then
    raise exception 'noitem' using errcode = '22023';
  end if;
  if exists (select 1 from news.nominations where user_id = me.id and item_id = p_item) then
    delete from news.nominations where user_id = me.id and item_id = p_item;
    return false;
  end if;
  insert into news.nominations (user_id, item_id) values (me.id, p_item);
  return true;
end
$$;

-- ----------------------------------------------------------------------------
-- Admins
-- ----------------------------------------------------------------------------

create function news_private.admin() returns news.profiles
language plpgsql stable
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
begin
  if not me.is_admin then
    raise exception 'admin' using errcode = '42501';
  end if;
  return me;
end
$$;

create function news.set_highlight(p_item bigint, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  if p_on then
    if not exists (select 1 from news.items where id = p_item and type = 'comment' and not deleted) then
      raise exception 'noitem' using errcode = '22023';
    end if;
    insert into news.highlights (item_id) values (p_item) on conflict do nothing;
  else
    delete from news.highlights where item_id = p_item;
  end if;
end
$$;

-- The second-chance pool: the story ranks as if posted now, for a while.
create function news.set_pool(p_item bigint, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  update news.items set pooled_at = case when p_on then now() end
  where id = p_item and type = 'story' and not deleted;
  if not found then
    raise exception 'noitem' using errcode = '22023';
  end if;
end
$$;

-- '' turns a setting off.
create function news.set_setting(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  p_value := lower(btrim(coalesce(p_value, '')));
  if p_key = 'bar_color' and p_value <> '' and p_value !~ '^[0-9a-f]{6}$' then
    raise exception 'value' using errcode = '22023';
  end if;
  if p_value = '' then
    delete from news.settings where key = p_key;
  else
    insert into news.settings (key, value) values (p_key, p_value)
    on conflict (key) do update set value = excluded.value;
  end if;
end
$$;

-- Top stories, as before, with pooled stories ranked from when they were
-- pooled (for two days).
create or replace function news.top_story_ids(p_limit int default 210)
returns table (id bigint)
language sql stable
set search_path = ''
as $$
  with candidates as (
    (select s.id from news.items s
     where s.type = 'story' and not s.deleted
     order by s.id desc limit 1000)
    union
    select s.id from news.items s
    where s.type = 'story' and not s.deleted and s.pooled_at > now() - interval '2 days'
  ), recent as (
    select s.* from news.items s join candidates c on c.id = s.id
  ), counts as (
    select c.root_id, count(*) n from news.items c
    where c.root_id in (select r.id from recent r) and c.type = 'comment'
      and not c.dead and not c.deleted
    group by c.root_id
  )
  select r.id from recent r left join counts c on c.root_id = r.id
  where r.score - r.sockvotes >= 1
  order by news.frontpage_rank(r.score, r.sockvotes,
                               greatest(r.created_at, coalesce(r.pooled_at, r.created_at)),
                               r.type, r.url, r.dead, coalesce(c.n, 0)) desc
  limit least(p_limit, 1000)
$$;

-- ----------------------------------------------------------------------------
-- Posting, now with a hat (and Launch EN for stories)
-- ----------------------------------------------------------------------------

drop function news.submit_story(text, text, text);
drop function news.post_comment(bigint, text);

create function news.submit_story(p_url text, p_title text, p_text text, p_hat boolean default true)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     news.profiles := news_private.me();
  new_id bigint;
begin
  p_url := btrim(coalesce(p_url, ''));
  p_title := coalesce(p_title, '');
  p_text := coalesce(p_text, '');
  -- validUrl from lib/arc.ts
  if btrim(p_title) = '' or (p_url <> '' and (char_length(p_url) <= 10 or p_url !~ '^https?://'
                                              or p_url ~ '[<>"''[:space:]]')) then
    raise exception 'retry' using errcode = '22023';
  end if;
  if char_length(p_title) > 80 then
    raise exception 'toolong' using errcode = '22023';
  end if;
  if p_url = '' and btrim(p_text) = '' then
    raise exception 'bothblank' using errcode = '22023';
  end if;
  -- Launch EN: Exponential companies, once each.
  if p_title ~* '^\s*launch en\s*:' then
    if me.badge is null or me.badge = 'community' then
      raise exception 'launch' using errcode = '22023';
    end if;
    if exists (select 1 from news.items
               where "by" = me.id and type = 'story' and not deleted and title ~* '^\s*launch en\s*:') then
      raise exception 'launched' using errcode = '22023';
    end if;
  end if;

  insert into news.items (type, "by", by_name, url, site, title, text, dead, hat)
  values ('story', me.id, me.username, p_url, news.sitename(p_url), p_title, p_text, me.ignored,
          coalesce(p_hat, true))
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  return new_id;
end
$$;

create function news.post_comment(p_parent bigint, p_text text, p_hat boolean default true)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     news.profiles := news_private.me();
  parent news.items;
  root   news.items;
  new_id bigint;
begin
  select * into parent from news.items where id = p_parent;
  if parent.id is null or not (parent.visible_at <= now() or parent."by" = me.id) then
    raise exception 'noitem' using errcode = '22023';
  end if;
  if parent.root_id is not null then
    select * into root from news.items where id = parent.root_id;
  end if;
  -- comments-active? from news.arc
  if parent.dead or parent.deleted or coalesce(root.dead or root.deleted, false)
     or not (now() - parent.created_at < interval '45 days' or 'commentable' = any (parent.keys)) then
    raise exception 'closed' using errcode = '22023';
  end if;
  if btrim(coalesce(p_text, '')) = '' then
    raise exception 'retry' using errcode = '22023';
  end if;

  insert into news.items (type, "by", by_name, text, parent_id, root_id, parent_by, visible_at, dead, hat)
  values ('comment', me.id, me.username, p_text, parent.id, coalesce(parent.root_id, parent.id),
          parent."by", now() + least(10, greatest(0, me.delay)) * interval '1 minute',
          me.ignored or me.karma < -20, coalesce(p_hat, true))
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  return new_id;
end
$$;

-- ----------------------------------------------------------------------------
-- Owners and grants
-- ----------------------------------------------------------------------------

alter function news.mark_read(bigint) owner to news_owner;
alter function news.unread_counts(bigint[]) owner to news_owner;
alter function news.points_curve(bigint) owner to news_owner;
alter function news.toggle_favorite(bigint) owner to news_owner;
alter function news.toggle_nomination(bigint) owner to news_owner;
alter function news_private.admin() owner to news_owner;
alter function news.set_highlight(bigint, boolean) owner to news_owner;
alter function news.set_pool(bigint, boolean) owner to news_owner;
alter function news.set_setting(text, text) owner to news_owner;
alter function news.submit_story(text, text, text, boolean) owner to news_owner;
alter function news.post_comment(bigint, text, boolean) owner to news_owner;

revoke all on function
  news.mark_read(bigint), news.unread_counts(bigint[]), news.points_curve(bigint),
  news.toggle_favorite(bigint), news.toggle_nomination(bigint), news_private.admin(),
  news.set_highlight(bigint, boolean), news.set_pool(bigint, boolean), news.set_setting(text, text),
  news.submit_story(text, text, text, boolean), news.post_comment(bigint, text, boolean)
from public, anon, authenticated, service_role;

grant execute on function news.points_curve(bigint) to anon, authenticated;
grant execute on function
  news.mark_read(bigint), news.unread_counts(bigint[]),
  news.toggle_favorite(bigint), news.toggle_nomination(bigint),
  news.set_highlight(bigint, boolean), news.set_pool(bigint, boolean), news.set_setting(text, text),
  news.submit_story(text, text, text, boolean), news.post_comment(bigint, text, boolean)
to authenticated;

commit;
