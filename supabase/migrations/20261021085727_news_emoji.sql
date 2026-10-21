-- ============================================================================
-- Exponential News: emoji of its own, and a status.
--
-- Anyone writes an emoji as ":name:", with Slack's names (the app knows
-- them). Members with a badge, and staff, add emoji of News' own: an image
-- uploaded into their folder of news-images, under a name nobody has, that
-- everyone then writes as ":name:". Whoever added one, or an admin, takes it
-- away. Posts and comments keep the ":name:" and the pages draw the image, so
-- an emoji that's gone reads as its name.
--
-- A status is one emoji someone wears, on their profile and by their name in
-- conversations: an emoji ("🚀") or one of News' (":name:"), or none.
-- ============================================================================

create table news.emoji (
  name        text primary key check (name ~ '^[a-z0-9_-]{2,32}$'),
  path        text not null check (path ~ '^media/[0-9a-f-]{36}/[a-z0-9]{8,64}\.(png|jpg|webp|gif)$'),
  "by"        uuid not null references news.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
alter table news.emoji owner to news_owner;
alter table news.emoji enable row level security;
revoke all on news.emoji from public, anon, authenticated;
create policy emoji_read on news.emoji for select to anon, authenticated using (true);
grant select on news.emoji to anon, authenticated;

-- Who may add one is who reads members-only posts (news.sees_gated): a badge,
-- or staff. The image is theirs: a path in their own folder.
create function news.add_emoji(p_name text, p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
begin
  if not (me.badge is not null or me.staff or me.is_admin) then
    raise exception 'nobadge' using errcode = '42501';
  end if;
  if coalesce(p_name, '') !~ '^[a-z0-9_-]{2,32}$' then
    raise exception 'badname' using errcode = '22023';
  end if;
  if coalesce(p_path, '') !~ ('^media/' || me.id::text || '/[a-z0-9]{8,64}\.(png|jpg|webp|gif)$') then
    raise exception 'badpath' using errcode = '22023';
  end if;
  insert into news.emoji (name, path, "by") values (p_name, p_path, me.id) on conflict (name) do nothing;
  if not found then
    raise exception 'taken' using errcode = '23505';
  end if;
end
$$;

create function news.remove_emoji(p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
begin
  delete from news.emoji where name = p_name and ("by" = me.id or me.is_admin);
  if not found then
    raise exception 'noemoji' using errcode = '22023';
  end if;
end
$$;

alter function news.add_emoji(text, text) owner to news_owner;
alter function news.remove_emoji(text) owner to news_owner;
revoke all on function news.add_emoji(text, text), news.remove_emoji(text)
  from public, anon, authenticated, service_role;
grant execute on function news.add_emoji(text, text), news.remove_emoji(text) to authenticated;

-- A status: a short line with no markup, which the app holds to one emoji.
alter table news.profiles add column status text not null default ''
  check (char_length(status) <= 40 and status !~ '[<>"&[:cntrl:]]');
grant select (status) on news.profiles to anon, authenticated;

-- update_profile, as before, and the status.
create or replace function news.update_profile(p_id uuid, p_changes jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me   news.profiles := news_private.me();
  c    jsonb := coalesce(p_changes, '{}');
  s    news.profiles;
  self boolean;
  a    boolean := me.is_admin;
  ed   boolean := me.is_admin or me.auth > 0;
begin
  select * into s from news.profiles where id = p_id for update;
  if s.id is null then
    raise exception 'noprofile' using errcode = '22023';
  end if;
  self := s.id = me.id;

  if self or a then
    if jsonb_typeof(c -> 'about') = 'string' then s.about := c ->> 'about'; end if;
    if jsonb_typeof(c -> 'github') = 'string' then s.github := c ->> 'github'; end if;
    if jsonb_typeof(c -> 'linkedin') = 'string' then s.linkedin := c ->> 'linkedin'; end if;
    if jsonb_typeof(c -> 'photo') = 'string' then s.photo := c ->> 'photo'; end if;
    if jsonb_typeof(c -> 'status') = 'string' then s.status := c ->> 'status'; end if;
    if jsonb_typeof(c -> 'showdead') = 'boolean' then s.showdead := (c ->> 'showdead')::boolean; end if;
    if jsonb_typeof(c -> 'noprocrast') = 'boolean' then s.noprocrast := (c ->> 'noprocrast')::boolean; end if;
    if jsonb_typeof(c -> 'maxvisit') = 'number' and (c ->> 'maxvisit')::numeric > 0 then
      s.maxvisit := round((c ->> 'maxvisit')::numeric);
    end if;
    if jsonb_typeof(c -> 'minaway') = 'number' and (c ->> 'minaway')::numeric > 0 then
      s.minaway := round((c ->> 'minaway')::numeric);
    end if;
    if jsonb_typeof(c -> 'delay') = 'number' then s.delay := round((c ->> 'delay')::numeric); end if;
  end if;
  if a then
    if jsonb_typeof(c -> 'auth') = 'number' then s.auth := round((c ->> 'auth')::numeric); end if;
    if jsonb_typeof(c -> 'karma') = 'number' and (c ->> 'karma')::numeric > 0 then
      s.karma := round((c ->> 'karma')::numeric);
    end if;
  end if;
  if ed and jsonb_typeof(c -> 'ignored') = 'boolean' then
    s.ignored := (c ->> 'ignored')::boolean;
  end if;
  if self and me.karma > 250 and jsonb_typeof(c -> 'topcolor') = 'string' then
    s.topcolor := lower(c ->> 'topcolor');
  end if;

  update news.profiles
     set about = s.about, github = s.github, linkedin = s.linkedin, photo = s.photo, status = s.status,
         showdead = s.showdead, noprocrast = s.noprocrast, maxvisit = s.maxvisit, minaway = s.minaway,
         delay = s.delay, auth = s.auth, karma = s.karma, ignored = s.ignored, topcolor = s.topcolor
   where id = s.id;
end
$$;
