-- ============================================================================
-- EXPONENTIAL NEWS: FUNCTIONS
--
-- Reads are plain table queries under RLS, plus a few SECURITY INVOKER
-- helpers for ranking and search. Every write is one of the SECURITY DEFINER
-- functions below. They run as news_owner, take the user from the request's
-- JWT (never from a parameter), and apply news.arc's permission rules
-- (canedit, candelete, canvote, canflag, ...) in the database, so calling them
-- directly with a session token can do no more than the site itself allows.
--
-- Errors that the site turns into messages use SQLSTATE 22023 with the
-- message key as text ('name', 'taken', 'retry', 'toolong', ...).
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- Pure helpers
-- ----------------------------------------------------------------------------

-- sitename from news.arc (lib/arc.ts), so "from" links can't be spoofed.
create function news.sitename(p_url text) returns text
language plpgsql immutable parallel safe
set search_path = ''
as $$
declare
  parts text[];
  toks  text[];
begin
  if p_url is null or char_length(p_url) <= 10 or p_url !~ '^https?://' or p_url ~ '[<>"'']' then
    return null;
  end if;
  select array_agg(x order by n) into parts
  from regexp_split_to_table(replace(p_url, ' ', ''), '[/?]') with ordinality as t(x, n)
  where x <> '';
  select array_agg(x order by n desc) into toks
  from regexp_split_to_table(coalesce(parts[2], ''), '\.') with ordinality as t(x, n)
  where x <> '';
  if toks is null then
    return null;
  end if;
  if toks[1] ~ '^-?\d+$' then
    return array_to_string(toks, '.');
  end if;
  if toks[3] is not null and toks[3] <> 'www'
     and (toks[1] = any (array['uk', 'jp', 'au', 'in', 'ph', 'tr', 'za', 'my', 'nz', 'br',
                               'mx', 'th', 'sg', 'id', 'pk', 'eg', 'il', 'at', 'pl'])
          or toks[2] = any (array['blogspot', 'wordpress', 'livejournal', 'blogs', 'typepad',
                                  'weebly', 'posterous', 'blog-city', 'supersized', 'dreamhosters',
                                  'eurekster', 'blogsome', 'edogo', 'blog', 'com'])) then
    return toks[3] || '.' || toks[2] || '.' || toks[1];
  end if;
  if toks[2] is not null then
    return toks[2] || '.' || toks[1];
  end if;
  return null;
end
$$;

-- frontpage-rank from news.arc: votes over age in hours to the gravity power,
-- with penalties for text posts, image links and controversial threads.
create function news.frontpage_rank(p_score int, p_sockvotes int, p_created timestamptz,
                                    p_type text, p_url text, p_dead boolean, p_ncomments bigint)
returns double precision
language sql stable
set search_path = ''
as $$
  with v as (
    select (p_score - p_sockvotes) as realscore,
           extract(epoch from (now() - p_created)) / 60 as age
  ), f as (
    select realscore, age,
      case when p_ncomments > 20
           then least(1, power(realscore::float / p_ncomments, 2)) else 1 end as contro
    from v
  )
  select (case when realscore - 1 > 0 then power(realscore - 1, 0.8) else realscore - 1 end)
         / power((age + 120) / 60, 1.8)
         * case when p_type <> 'story' then 0.5
                when p_url = '' then 0.4
                when p_dead or lower(p_url) ~ '\.(png|jpg|jpeg)$' then least(0.3, contro)
                else contro end
  from f
$$;

-- ----------------------------------------------------------------------------
-- Reads (invoker: RLS applies to the caller)
-- ----------------------------------------------------------------------------

-- Live comments under each story, for "n comments" links.
create function news.comment_counts(p_ids bigint[])
returns table (root_id bigint, n bigint)
language sql stable
set search_path = ''
as $$
  select c.root_id, count(*)
  from news.items c
  where c.root_id = any (p_ids) and c.type = 'comment'
    and not c.dead and not c.deleted
  group by c.root_id
$$;

-- Top stories: rank the latest 1000 stories, like gen-topstories.
create function news.top_story_ids(p_limit int default 210)
returns table (id bigint)
language sql stable
set search_path = ''
as $$
  with recent as (
    select s.* from news.items s
    where s.type = 'story' and not s.deleted
    order by s.id desc limit 1000
  ), counts as (
    select c.root_id, count(*) n from news.items c
    where c.root_id in (select r.id from recent r) and c.type = 'comment'
      and not c.dead and not c.deleted
    group by c.root_id
  )
  select r.id from recent r left join counts c on c.root_id = r.id
  where r.score - r.sockvotes >= 1
  order by news.frontpage_rank(r.score, r.sockvotes, r.created_at, r.type, r.url, r.dead,
                               coalesce(c.n, 0)) desc
  limit least(p_limit, 1000)
$$;

-- Every word of the query as a prefix, so "stablecoin" finds "stablecoins".
create function news.search_ids(p_query text, p_limit int default 210)
returns table (id bigint)
language sql stable
set search_path = ''
as $$
  with q as (
    select to_tsquery('simple', string_agg(w || ':*', ' & ')) as tsq
    from regexp_split_to_table(lower(p_query), '[^[:alnum:]]+') as w
    where w <> ''
  )
  select i.id from news.items i, q
  where q.tsq is not null and i.fts @@ q.tsq
    and not i.dead and not i.deleted
  order by ts_rank(i.fts, q.tsq) * ln(2 + greatest(i.score, 0)) desc, i.id desc
  limit least(p_limit, 1000)
$$;

create function news.leaders(p_limit int default 20)
returns table (username text, karma int, badge text)
language sql stable
security definer
set search_path = ''
as $$
  select p.username, p.karma, p.badge from news.profiles p
  where p.karma > 1 and not p.is_admin
  order by p.karma desc
  limit least(p_limit, 100)
$$;

create function news.username_available(p_username text) returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select not exists (select 1 from news.profiles p where lower(p.username) = lower(p_username))
$$;

-- The private fields of a profile: your own, or anyone's for editors and
-- admins. `ignored` is only shown to editors, as in news.arc.
create function news.profile_private(p_id uuid default null)
returns table (
  id uuid, username text, created_at timestamptz, karma int, about text,
  github text, linkedin text, badge text, is_admin boolean, auth int, ignored boolean,
  showdead boolean, noprocrast boolean, firstview timestamptz, lastview timestamptz,
  maxvisit int, minaway int, topcolor text, delay int
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
         p.showdead, p.noprocrast, p.firstview, p.lastview, p.maxvisit, p.minaway, p.topcolor, p.delay
  from news.profiles p, v
  where p.id = coalesce(p_id, news.uid())
    and (p.id = news.uid() or v.editor)
$$;

-- What a deleted item said, for admins.
create function news.deleted_items(p_ids bigint[])
returns table (item_id bigint, title text, url text, text text)
language sql stable
security definer
set search_path = ''
as $$
  select d.item_id, d.title, d.url, d.text
  from news_private.deleted_content d
  where d.item_id = any (p_ids) and news.is_admin()
$$;

-- ----------------------------------------------------------------------------
-- vote-for from news.arc. Internal: callers go through news.vote_item, which
-- checks canvote first. Returns true if the vote was recorded.
-- ----------------------------------------------------------------------------

create function news_private.cast_vote(p_user uuid, p_item bigint, p_dir int)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  i     news.items;
  voter news.profiles;
begin
  select * into i from news.items where id = p_item for update;
  select * into voter from news.profiles where id = p_user;
  if i.id is null or voter.id is null then return false; end if;
  if exists (select 1 from news.votes where user_id = p_user and item_id = p_item) then
    return false;
  end if;
  if (i.dead or i.deleted) and i."by" <> p_user then return false; end if;

  if not (voter.ignored and i."by" <> p_user) then
    update news.items
       set score = score + p_dir,
           sockvotes = sockvotes + case when p_dir = 1 and voter.ignored then 1 else 0 end,
           keys = case when voter.is_admin and not ('nokill' = any (keys))
                       then array_append(keys, 'nokill') else keys end
     where id = p_item;
    if i."by" <> p_user then
      update news.profiles set karma = karma + p_dir where id = i."by";
    end if;
  end if;

  insert into news.votes (user_id, item_id, dir) values (p_user, p_item, p_dir);
  return true;
end
$$;

-- ----------------------------------------------------------------------------
-- Writes
-- ----------------------------------------------------------------------------

-- The caller's profile, or an error if they have none.
create function news_private.me() returns news.profiles
language plpgsql stable
set search_path = ''
as $$
declare
  me news.profiles;
begin
  select * into me from news.profiles where id = news.uid();
  if me.id is null then
    raise exception 'login' using errcode = '42501';
  end if;
  return me;
end
$$;

create function news.submit_story(p_url text, p_title text, p_text text)
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

  insert into news.items (type, "by", by_name, url, site, title, text, dead)
  values ('story', me.id, me.username, p_url, news.sitename(p_url), p_title, p_text, me.ignored)
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  return new_id;
end
$$;

create function news.post_comment(p_parent bigint, p_text text)
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

  insert into news.items (type, "by", by_name, text, parent_id, root_id, parent_by, visible_at, dead)
  values ('comment', me.id, me.username, p_text, parent.id, coalesce(parent.root_id, parent.id),
          parent."by", now() + least(10, greatest(0, me.delay)) * interval '1 minute',
          me.ignored or me.karma < -20)
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  return new_id;
end
$$;

-- canvote from news.arc, then vote-for.
create function news.vote_item(p_item bigint, p_dir int)
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
  if i.id is null or i.dead or i.deleted or p_dir not in (1, -1)
     or not (i.visible_at <= now() or i."by" = me.id) then
    return false;
  end if;
  if p_dir = -1 and not (i.type = 'comment' and me.karma > 200 and i.score > -4
                         and i.parent_by is distinct from me.id
                         and (me.is_admin or now() - i.created_at < interval '1 day')) then
    return false;
  end if;
  return news_private.cast_vote(me.id, p_item, p_dir);
end
$$;

-- Take back a vote made in the last hour, undoing its effect on the score
-- and on the author's karma. Your own submission's vote stays.
create function news.unvote_item(p_item bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  v  news.votes;
  i  news.items;
begin
  select * into v from news.votes where user_id = me.id and item_id = p_item;
  if v.user_id is null or v.created_at < now() - interval '1 hour' then return false; end if;
  select * into i from news.items where id = p_item for update;
  if i."by" = me.id then return false; end if;

  if not me.ignored then
    update news.items set score = score - v.dir where id = p_item;
    update news.profiles set karma = karma - v.dir where id = i."by";
  end if;
  delete from news.votes where user_id = me.id and item_id = p_item;
  return true;
end
$$;

-- canflag, then flaglink: toggle a flag, kill the item past the threshold.
create function news.toggle_flag(p_item bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  i  news.items;
  n  int;
begin
  select * into i from news.items where id = p_item for update;
  if i.id is null or i."by" = me.id or not (me.is_admin or me.karma > 30)
     or not (i.visible_at <= now()) then
    return false;
  end if;
  if exists (select 1 from news.flags where user_id = me.id and item_id = p_item) then
    delete from news.flags where user_id = me.id and item_id = p_item;
    return true;
  end if;
  insert into news.flags (user_id, item_id) values (me.id, p_item);
  select count(*) into n from news.flags where item_id = p_item;
  if n > 7 and i.score - i.sockvotes < 10 and not ('nokill' = any (i.keys))
     and not exists (select 1 from news.votes v join news.profiles p on p.id = v.user_id
                     where v.item_id = p_item and p.is_admin) then
    update news.items set dead = true where id = p_item;
  end if;
  return true;
end
$$;

-- Admin only: toggle dead. Unkilling marks the item nokill, as in Arc.
create function news.toggle_kill(p_item bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
begin
  if not me.is_admin then return false; end if;
  update news.items
     set dead = not dead,
         keys = case when dead then array(select distinct k from unnest(array_append(keys, 'nokill')) k)
                     else array_remove(keys, 'nokill') end
   where id = p_item;
  return found;
end
$$;

-- The edit page (vars-form): each field is written only if the caller may
-- change it. Fields the caller may not change are ignored, as in Arc.
-- p_changes holds the new values already normalized by the site.
create function news.edit_item(p_id bigint, p_changes jsonb)
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

  if x and jsonb_typeof(c -> 'text') = 'string' then
    v_text := c ->> 'text';
  end if;
  if i.type = 'story' then
    if x and jsonb_typeof(c -> 'title') = 'string' and btrim(c ->> 'title') <> ''
       and char_length(c ->> 'title') <= 80 then
      v_title := c ->> 'title';
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

-- candelete, then delete or undelete.
create function news.delete_item(p_id bigint, p_deleted boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  i  news.items;
begin
  select * into i from news.items where id = p_id for update;
  if i.id is null or not (me.is_admin
                          or (i."by" = me.id and not ('locked' = any (i.keys)) and not i.deleted
                              and now() - i.created_at < interval '120 minutes')) then
    return false;
  end if;
  update news.items set deleted = p_deleted where id = i.id;
  return true;
end
$$;

-- The profile page's vars-form, with news.arc's rules for who may change
-- which field. p_changes holds values already normalized by the site.
create function news.update_profile(p_id uuid, p_changes jsonb)
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
     set about = s.about, github = s.github, linkedin = s.linkedin, showdead = s.showdead,
         noprocrast = s.noprocrast, maxvisit = s.maxvisit, minaway = s.minaway, delay = s.delay,
         auth = s.auth, karma = s.karma, ignored = s.ignored, topcolor = s.topcolor
   where id = s.id;
end
$$;

-- noprocrast bookkeeping: start a new visit, or extend the current one.
create function news.mark_visit(p_new_visit boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  update news.profiles
     set firstview = case when p_new_visit then now() else firstview end,
         lastview = now()
   where id = news.uid()
$$;

-- ----------------------------------------------------------------------------
-- Ownership and grants
-- ----------------------------------------------------------------------------

alter function news.sitename(text) owner to news_owner;
alter function news.frontpage_rank(int, int, timestamptz, text, text, boolean, bigint) owner to news_owner;
alter function news.comment_counts(bigint[]) owner to news_owner;
alter function news.top_story_ids(int) owner to news_owner;
alter function news.search_ids(text, int) owner to news_owner;
alter function news.leaders(int) owner to news_owner;
alter function news.username_available(text) owner to news_owner;
alter function news.profile_private(uuid) owner to news_owner;
alter function news.deleted_items(bigint[]) owner to news_owner;
alter function news_private.cast_vote(uuid, bigint, int) owner to news_owner;
alter function news_private.me() owner to news_owner;
alter function news.submit_story(text, text, text) owner to news_owner;
alter function news.post_comment(bigint, text) owner to news_owner;
alter function news.vote_item(bigint, int) owner to news_owner;
alter function news.unvote_item(bigint) owner to news_owner;
alter function news.toggle_flag(bigint) owner to news_owner;
alter function news.toggle_kill(bigint) owner to news_owner;
alter function news.edit_item(bigint, jsonb) owner to news_owner;
alter function news.delete_item(bigint, boolean) owner to news_owner;
alter function news.update_profile(uuid, jsonb) owner to news_owner;
alter function news.mark_visit(boolean) owner to news_owner;

revoke all on all functions in schema news, news_private from public, anon, authenticated, service_role;

-- Anyone, signed in or not.
grant execute on function
  news.safe_html(text), news.uid(), news.is_admin(), news.sitename(text),
  news.frontpage_rank(int, int, timestamptz, text, text, boolean, bigint),
  news.comment_counts(bigint[]), news.top_story_ids(int), news.search_ids(text, int),
  news.leaders(int), news.username_available(text), news.profile_private(uuid)
to anon, authenticated;

-- Signed-in users.
grant execute on function
  news.deleted_items(bigint[]), news.submit_story(text, text, text), news.post_comment(bigint, text),
  news.vote_item(bigint, int), news.unvote_item(bigint), news.toggle_flag(bigint),
  news.toggle_kill(bigint), news.edit_item(bigint, jsonb), news.delete_item(bigint, boolean),
  news.update_profile(uuid, jsonb), news.mark_visit(boolean)
to authenticated;

commit;
