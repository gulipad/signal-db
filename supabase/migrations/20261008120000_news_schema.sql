-- ============================================================================
-- EXPONENTIAL NEWS: SCHEMA
--
-- Exponential News (a Hacker News clone, open to the public) shares this
-- project with Signal. It lives entirely in two schemas of its own:
--
--   news          exposed through the Data API. Tables are readable as RLS
--                 allows; every write goes through a SECURITY DEFINER function
--                 that checks the caller (20261008120100_news_functions.sql).
--   news_private  not exposed. Deleted content and what News is told about
--                 Signal members (20261008120200_news_signal_bridge.sql).
--
-- Both are owned by `news_owner`, a NOLOGIN role with no privileges on any
-- Signal table. The News web server holds only the publishable key and the
-- visitor's session, never a secret key, so neither a bug in News nor a leak
-- of its environment can reach Signal data.
--
-- Accounts are Supabase Auth users, shared with Signal. A signed-in News user
-- is `authenticated` like a Signal user; Signal's own tables stay closed to
-- them through the staff-gated RLS of 20260908160000_staff_gated_rls.sql.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- Roles
-- ----------------------------------------------------------------------------

do $$
begin
  if not exists (select from pg_roles where rolname = 'news_owner') then
    create role news_owner nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'news_bridge') then
    create role news_bridge nologin noinherit;
  end if;
end
$$;
comment on role news_owner is
  'Owns the news and news_private schemas and runs the News RPCs. No privileges on Signal tables.';
comment on role news_bridge is
  'Reads the few Signal columns that say who was accepted, and writes news_private.signal_members. Nothing else.';

-- Lets migrations create objects owned by these roles (and tests SET ROLE).
grant news_owner, news_bridge to postgres;

-- ----------------------------------------------------------------------------
-- Schemas
-- ----------------------------------------------------------------------------

create schema news authorization news_owner;
create schema news_private authorization news_owner;
comment on schema news is 'Exponential News. Exposed through the Data API.';
comment on schema news_private is 'Exponential News internals. Not exposed; no API role can use it.';

revoke all on schema news, news_private from public;
grant usage on schema news to anon, authenticated, service_role;

-- New functions are executable by PUBLIC unless revoked. Make every grant in
-- these schemas explicit.
alter default privileges for role news_owner, postgres in schema news, news_private
  revoke all on tables from public;
alter default privileges for role news_owner, postgres in schema news, news_private
  revoke all on sequences from public;
alter default privileges for role news_owner, postgres in schema news, news_private
  revoke all on functions from public;

-- ----------------------------------------------------------------------------
-- HTML that may be stored. Item text and profile "about" are Arc markdown
-- rendered to HTML on the server (lib/arc.ts) and shown as HTML. The functions
-- that write them can also be called directly with a session token, so the
-- database checks that nothing but Arc's own tags got through: <p>, <i>,
-- <pre><code>, and links to http(s) urls. Everything else arrives as &#60;.
-- ----------------------------------------------------------------------------

create function news.safe_html(s text) returns boolean
language sql immutable parallel safe
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
           s,
           '<p>|<pre><code>|</code></pre>|<i>|</i>|<a href="https?://[^"<>[:space:]]*" rel="nofollow">|</a>',
           '', 'g') !~ '[<>]'
$$;
alter function news.safe_html(text) owner to news_owner;

-- The signed-in user, read from the request's JWT (auth.uid() lives in the
-- auth schema, which news_owner has no access to).
create function news.uid() returns uuid
language sql stable parallel safe
set search_path = ''
as $$
  select nullif(nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;
alter function news.uid() owner to news_owner;

-- ----------------------------------------------------------------------------
-- Tables. Created as postgres, then handed to news_owner: the foreign key to
-- auth.users needs a REFERENCES privilege that only postgres has.
-- ----------------------------------------------------------------------------

create table news.profiles (
  id          uuid primary key references auth.users on delete cascade,
  username    text not null check (username ~ '^[A-Za-z0-9_][A-Za-z0-9_-]{1,14}$'),
  created_at  timestamptz not null default now(),
  karma       int not null default 1,
  about       text not null default '' check (news.safe_html(about)),
  github      text not null default ''
              check (github = '' or github ~ '^https://([a-z0-9-]+\.)*github\.com/[^"''<>[:space:]]+$'),
  linkedin    text not null default ''
              check (linkedin = '' or linkedin ~ '^https://([a-z0-9-]+\.)*linkedin\.com/[^"''<>[:space:]]+$'),
  -- Highest Exponential program the person was accepted to, from Signal.
  -- Maintained by news_private.apply_badges(); nobody else writes it.
  badge       text check (badge in ('fellowship', 'launchpad', 'community')),
  -- Private from here on: only the user, editors and admins read these,
  -- through news.profile_private().
  is_admin    boolean not null default false,
  auth        int not null default 0,          -- > 0 means editor
  ignored     boolean not null default false,
  showdead    boolean not null default false,
  noprocrast  boolean not null default false,
  firstview   timestamptz,
  lastview    timestamptz,
  maxvisit    int not null default 20,
  minaway     int not null default 180,
  topcolor    text check (topcolor ~ '^[0-9a-f]{6}$'),
  delay       int not null default 0
);
create unique index profiles_username_lower on news.profiles (lower(username));
create index profiles_karma on news.profiles (karma desc);
comment on table news.profiles is
  'One row per News account, keyed by the Supabase Auth user. Created by news.claim_profile() on first login.';

create table news.items (
  id          bigint generated by default as identity primary key,
  type        text not null check (type in ('story', 'comment')),
  by          uuid not null references news.profiles on delete cascade,
  by_name     text not null,
  created_at  timestamptz not null default now(),
  url         text not null default '' check (url = '' or (url ~ '^https?://' and url !~ '[<>"''[:space:]]')),
  site        text,
  title       text not null default '' check (char_length(title) <= 80 and title !~ '[<>]'),
  text        text not null default '' check (news.safe_html(text)),
  score       int not null default 0,
  sockvotes   int not null default 0,
  dead        boolean not null default false,
  deleted     boolean not null default false,
  parent_id   bigint references news.items on delete cascade,
  root_id     bigint references news.items on delete cascade,
  parent_by   uuid references news.profiles on delete set null,
  visible_at  timestamptz not null default now(),   -- comment delay from the author's profile
  keys        text[] not null default '{}',
  fts         tsvector generated always as
              (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(text, ''))) stored
);
create index items_type_id on news.items (type, id desc);
create index items_by_id on news.items (by, id desc);
create index items_root on news.items (root_id);
create index items_parent on news.items (parent_id);
create index items_url on news.items (url) where type = 'story' and url <> '';
create index items_site on news.items (site, id desc) where type = 'story';
create index items_fts on news.items using gin (fts);

create table news.votes (
  user_id     uuid not null references news.profiles on delete cascade,
  item_id     bigint not null references news.items on delete cascade,
  dir         smallint not null check (dir in (1, -1)),
  created_at  timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index votes_item on news.votes (item_id);

create table news.flags (
  user_id     uuid not null references news.profiles on delete cascade,
  item_id     bigint not null references news.items on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index flags_item on news.flags (item_id);

create table news.hides (
  user_id     uuid not null references news.profiles on delete cascade,
  item_id     bigint not null references news.items on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, item_id)
);

-- What a deleted item said, kept for admins. Deleting an item blanks its
-- title, url and text in news.items (which anyone can read) and moves them
-- here; undeleting puts them back.
create table news_private.deleted_content (
  item_id     bigint primary key references news.items on delete cascade,
  title       text not null,
  url         text not null,
  text        text not null,
  deleted_at  timestamptz not null default now()
);

alter table news.profiles owner to news_owner;
alter table news.items owner to news_owner;
alter table news.votes owner to news_owner;
alter table news.flags owner to news_owner;
alter table news.hides owner to news_owner;
alter table news_private.deleted_content owner to news_owner;

create function news_private.stash_deleted_content() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.deleted and not old.deleted then
    insert into news_private.deleted_content (item_id, title, url, text)
    values (old.id, old.title, old.url, old.text)
    on conflict (item_id) do update
      set title = excluded.title, url = excluded.url, text = excluded.text, deleted_at = now();
    new.title := '';
    new.url := '';
    new.text := '';
  elsif old.deleted and not new.deleted then
    select d.title, d.url, d.text into new.title, new.url, new.text
    from news_private.deleted_content d where d.item_id = old.id;
    new.title := coalesce(new.title, '');
    new.url := coalesce(new.url, '');
    new.text := coalesce(new.text, '');
    delete from news_private.deleted_content where item_id = old.id;
  end if;
  return new;
end
$$;
alter function news_private.stash_deleted_content() owner to news_owner;
revoke all on function news_private.stash_deleted_content() from public;

create trigger items_stash_deleted
  before update of deleted on news.items
  for each row when (old.deleted is distinct from new.deleted)
  execute function news_private.stash_deleted_content();

-- ----------------------------------------------------------------------------
-- Row level security. Reads go through these policies; writes have no
-- policies (and no grants) except hides, which have no side effects.
-- ----------------------------------------------------------------------------

alter table news.profiles enable row level security;
alter table news.items enable row level security;
alter table news.votes enable row level security;
alter table news.flags enable row level security;
alter table news.hides enable row level security;
alter table news_private.deleted_content enable row level security;

create function news.is_admin() returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select coalesce((select p.is_admin from news.profiles p where p.id = news.uid()), false)
$$;
alter function news.is_admin() owner to news_owner;

create policy profiles_read on news.profiles
  for select to anon, authenticated using (true);

-- A comment held back by its author's delay is only theirs until it shows.
create policy items_read on news.items
  for select to anon, authenticated
  using (visible_at <= now() or "by" = news.uid());

-- Votes, flags and hides are private: yours, or anyone's for admins.
create policy votes_read on news.votes
  for select to authenticated using (user_id = news.uid() or news.is_admin());
create policy flags_read on news.flags
  for select to authenticated using (user_id = news.uid());
create policy hides_read on news.hides
  for select to authenticated using (user_id = news.uid() or news.is_admin());
create policy hides_insert on news.hides
  for insert to authenticated
  with check (user_id = news.uid()
              and exists (select 1 from news.items i where i.id = item_id and i.type = 'story'));
create policy hides_delete on news.hides
  for delete to authenticated using (user_id = news.uid());

-- ----------------------------------------------------------------------------
-- Grants. Profiles expose only their public columns; the rest is read through
-- news.profile_private().
-- ----------------------------------------------------------------------------

revoke all on all tables in schema news, news_private from public, anon, authenticated, service_role;
revoke all on all sequences in schema news, news_private from public, anon, authenticated, service_role;

grant select (id, username, created_at, karma, about, github, linkedin, badge)
  on news.profiles to anon, authenticated;
grant select on news.items to anon, authenticated;
grant select on news.votes, news.flags to authenticated;
grant select, insert, delete on news.hides to authenticated;

revoke all on function news.safe_html(text), news.uid(), news.is_admin() from public;
grant execute on function news.safe_html(text), news.uid(), news.is_admin() to anon, authenticated;

commit;
