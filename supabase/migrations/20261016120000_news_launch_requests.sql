-- ============================================================================
-- Exponential News: launches by request.
--
-- Anyone can ask for a launch. The post goes up at once as a Show
-- ("Show EN: "), with a request beside it; an admin approves it, which makes
-- it a launch ("Launch EN: "), or declines it, and it stays a Show. The
-- author of any Show can ask the same later. Each person still launches
-- once. Only the author and admins see a request.
--
-- A launch is made here and nowhere else: submit_story takes a "Launch EN:"
-- title from nobody (Fellowship and Launchpad included), and edit_item no
-- longer lets a title gain or lose it unless an admin edits it (an author
-- could, within their two hours).
-- ============================================================================

begin;

create table news.launch_requests (
  item_id     bigint primary key references news.items on delete cascade,
  "by"        uuid not null references news.profiles on delete cascade,
  created_at  timestamptz not null default now(),
  -- Null while it waits; true, a launch; false, it stays a Show.
  approved    boolean,
  decided_by  uuid references news.profiles on delete set null,
  decided_at  timestamptz
);
create index launch_requests_waiting on news.launch_requests (created_at) where approved is null;
create index launch_requests_by on news.launch_requests ("by");

alter table news.launch_requests owner to news_owner;
alter table news.launch_requests enable row level security;
create policy launch_requests_read on news.launch_requests
  for select to authenticated using ("by" = news.uid() or news.is_admin());
grant select on news.launch_requests to authenticated;

-- Once each: whether this person has a launch already.
create function news_private.has_launched(p_user uuid) returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from news.items
                 where "by" = p_user and type = 'story' and not deleted and title ~* '^\s*launch en\s*:')
$$;

-- ----------------------------------------------------------------------------
-- Posting: a launch is asked for, never posted
-- ----------------------------------------------------------------------------

drop function news.submit_story(text, text, text, boolean);

create function news.submit_story(p_url text, p_title text, p_text text, p_hat boolean default true,
                                  p_launch boolean default false)
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
  if p_title ~* '^\s*launch en\s*:' then
    raise exception 'launch' using errcode = '22023';
  end if;
  -- Asking for a launch: it goes up as a Show, with a title that will still
  -- fit once it is a launch.
  if p_launch then
    if p_title !~* '^\s*show\s+en\y' then
      raise exception 'retry' using errcode = '22023';
    end if;
    if char_length('Launch EN: ' || regexp_replace(p_title, '^\s*show\s+en\y\s*[-:–]?\s*', '', 'i')) > 80 then
      raise exception 'toolong' using errcode = '22023';
    end if;
    if news_private.has_launched(me.id) then
      raise exception 'launched' using errcode = '22023';
    end if;
  end if;

  insert into news.items (type, "by", by_name, url, site, title, text, dead, hat)
  values ('story', me.id, me.username, p_url, news.sitename(p_url), p_title, p_text, me.ignored,
          coalesce(p_hat, true))
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  if p_launch then
    insert into news.launch_requests (item_id, "by") values (new_id, me.id);
  end if;
  return new_id;
end
$$;

-- ----------------------------------------------------------------------------
-- Asking, and deciding
-- ----------------------------------------------------------------------------

-- The author of a Show asks for it to be their launch. Asking twice is
-- asking once; a declined request stays declined.
create function news.request_launch(p_item bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  i  news.items;
begin
  select * into i from news.items where id = p_item;
  if i.id is null or i."by" <> me.id or i.type <> 'story' or i.dead or i.deleted
     or i.title !~* '^\s*show\s+en\y' then
    raise exception 'noitem' using errcode = '22023';
  end if;
  if news_private.has_launched(me.id) then
    raise exception 'launched' using errcode = '22023';
  end if;
  insert into news.launch_requests (item_id, "by") values (i.id, me.id) on conflict (item_id) do nothing;
end
$$;

-- An admin approves a request, and the Show becomes a launch, or declines
-- it, and it stays a Show. A declined request can still be approved later.
create function news.decide_launch(p_item bigint, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me      news.profiles := news_private.admin();
  r       news.launch_requests;
  i       news.items;
  v_title text;
begin
  select * into r from news.launch_requests where item_id = p_item for update;
  select * into i from news.items where id = p_item for update;
  if r.item_id is null or coalesce(r.approved, false) or i.dead or i.deleted then
    raise exception 'noitem' using errcode = '22023';
  end if;
  if p_approve then
    if news_private.has_launched(i."by") then
      raise exception 'launched' using errcode = '22023';
    end if;
    v_title := 'Launch EN: ' || regexp_replace(i.title, '^\s*show\s+en\y\s*[-:–]?\s*', '', 'i');
    if char_length(v_title) > 80 then
      raise exception 'toolong' using errcode = '22023';
    end if;
    update news.items set title = v_title where id = i.id;
  end if;
  update news.launch_requests
     set approved = p_approve, decided_by = me.id, decided_at = now()
   where item_id = p_item;
end
$$;

-- ----------------------------------------------------------------------------
-- Editing: as before, except that a title keeps whether it is a launch
-- ----------------------------------------------------------------------------

create or replace function news.edit_item(p_id bigint, p_changes jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me    news.profiles := news_private.me();
  c     jsonb := coalesce(p_changes, '{}');
  i     news.items;
  a     boolean := me.is_admin;
  ed    boolean := me.is_admin or me.auth > 0;
  x     boolean;
  v_title text;
  v_url   text;
  v_text  text;
  v_was   text;
begin
  select * into i from news.items where id = p_id for update;
  if i.id is null then
    raise exception 'noitem' using errcode = '22023';
  end if;
  -- canedit
  x := a or (ed and now() - i.created_at < interval '1440 minutes')
       or (i."by" = me.id and not ('locked' = any (i.keys)) and not i.deleted
           and now() - i.created_at < interval '120 minutes');

  -- A deleted item's words live in news_private.deleted_content.
  if i.deleted then
    select d.title, d.url, d.text into v_title, v_url, v_text
    from news_private.deleted_content d where d.item_id = i.id;
  else
    v_title := i.title; v_url := i.url; v_text := i.text;
  end if;
  v_was := v_title;

  if x and jsonb_typeof(c -> 'text') = 'string' then
    v_text := c ->> 'text';
  end if;
  if i.type = 'story' then
    if x and jsonb_typeof(c -> 'title') = 'string' and btrim(c ->> 'title') <> ''
       and char_length(c ->> 'title') <= 80 then
      v_title := c ->> 'title';
    end if;
    -- Only an approved request makes a launch (decide_launch), and nothing
    -- but an admin unmakes one.
    if not a and (coalesce(v_title, '') ~* '^\s*launch en\s*:') <> (coalesce(v_was, '') ~* '^\s*launch en\s*:') then
      v_title := v_was;
    end if;
    if ed and jsonb_typeof(c -> 'url') = 'string' then
      v_url := btrim(c ->> 'url');
    end if;
  end if;

  if i.deleted then
    update news_private.deleted_content d
       set title = coalesce(v_title, ''), url = coalesce(v_url, ''), text = coalesce(v_text, '')
     where d.item_id = i.id;
  else
    update news.items
       set title = v_title, url = v_url, text = v_text, site = news.sitename(v_url)
     where id = i.id;
  end if;

  update news.items
     set score = case when a and jsonb_typeof(c -> 'score') = 'number'
                      then round((c ->> 'score')::numeric)::int else score end,
         dead  = case when ed and not ('nokill' = any (keys) and not a)
                           and jsonb_typeof(c -> 'dead') = 'boolean'
                      then (c ->> 'dead')::boolean else dead end,
         keys  = case when a and not ('locked' = any (keys)) then array_append(keys, 'locked') else keys end
   where id = i.id;

  if a and jsonb_typeof(c -> 'deleted') = 'boolean' then
    update news.items set deleted = (c ->> 'deleted')::boolean where id = i.id;
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- Owners and grants
-- ----------------------------------------------------------------------------

alter function news_private.has_launched(uuid) owner to news_owner;
alter function news.submit_story(text, text, text, boolean, boolean) owner to news_owner;
alter function news.request_launch(bigint) owner to news_owner;
alter function news.decide_launch(bigint, boolean) owner to news_owner;

revoke all on function
  news_private.has_launched(uuid), news.submit_story(text, text, text, boolean, boolean),
  news.request_launch(bigint), news.decide_launch(bigint, boolean)
from public, anon, authenticated, service_role;

grant execute on function
  news.submit_story(text, text, text, boolean, boolean), news.request_launch(bigint), news.decide_launch(bigint, boolean)
to authenticated;

commit;
