-- ============================================================================
-- Exponential News: posts for members with a badge.
--
-- Staff gate a post, their own when they write it or anyone's after: only
-- people with a badge (the Fellowship, Launchpad or the Community), staff
-- and admins, and the post's own author can read it and its conversation.
-- Nobody else sees it at all, visitors and the Data API included: the gate
-- is the items policy, not the page. A comment in a gated conversation is
-- gated too (items.gated, kept by set_gate and post_comment).
-- ============================================================================

begin;

alter table news.items add column gated boolean not null default false;

-- Who reads a gated post (apart from its author).
create function news.sees_gated() returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select coalesce((select p.badge is not null or p.staff or p.is_admin from news.profiles p where p.id = news.uid()), false)
$$;

drop policy items_read on news.items;
create policy items_read on news.items
  for select to anon, authenticated
  using ((visible_at <= now() or "by" = news.uid())
         and (not gated or "by" = news.uid() or (select news.sees_gated())));

-- Whether a link leads behind the gate, so News can say why it opens
-- nothing for this reader. Nothing else about the item.
create function news.gated_item(p_id bigint) returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (select 1 from news.items where id = p_id and gated and not dead and not deleted)
$$;

-- Staff gate a post, or open it, with its whole conversation.
create function news.set_gate(p_item bigint, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  if not exists (select 1 from news.items where id = p_item and type = 'story') then
    raise exception 'noitem' using errcode = '22023';
  end if;
  update news.items set gated = coalesce(p_on, false) where id = p_item or root_id = p_item;
end
$$;

-- ----------------------------------------------------------------------------
-- Posting: as before, and staff can gate what they post
-- ----------------------------------------------------------------------------

drop function news.submit_story(text, text, text, boolean, boolean);

create function news.submit_story(p_url text, p_title text, p_text text, p_hat boolean default true,
                                  p_launch boolean default false, p_gated boolean default false)
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
  if coalesce(p_gated, false) and not me.is_admin then
    raise exception 'gate' using errcode = '42501';
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

  insert into news.items (type, "by", by_name, url, site, title, text, dead, hat, gated)
  values ('story', me.id, me.username, p_url, news.sitename(p_url), p_title, p_text, me.ignored,
          coalesce(p_hat, true), coalesce(p_gated, false))
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  if p_launch then
    insert into news.launch_requests (item_id, "by") values (new_id, me.id);
  end if;
  return new_id;
end
$$;

-- Commenting: as before, and in a gated conversation only for those who can
-- read it; the comment is gated with it.
create or replace function news.post_comment(p_parent bigint, p_text text, p_hat boolean default true)
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
  if coalesce(root.gated, parent.gated) and not (news.sees_gated() or coalesce(root."by", parent."by") = me.id) then
    raise exception 'noitem' using errcode = '22023';
  end if;
  -- comments-active? from news.arc
  if parent.dead or parent.deleted or coalesce(root.dead or root.deleted, false)
     or not (now() - parent.created_at < interval '45 days' or 'commentable' = any (parent.keys)) then
    raise exception 'closed' using errcode = '22023';
  end if;
  if btrim(coalesce(p_text, '')) = '' then
    raise exception 'retry' using errcode = '22023';
  end if;

  insert into news.items (type, "by", by_name, text, parent_id, root_id, parent_by, visible_at, dead, hat, gated)
  values ('comment', me.id, me.username, p_text, parent.id, coalesce(parent.root_id, parent.id),
          parent."by", now() + least(10, greatest(0, me.delay)) * interval '1 minute',
          me.ignored or me.karma < -20, coalesce(p_hat, true), coalesce(root.gated, parent.gated))
  returning id into new_id;
  perform news_private.cast_vote(me.id, new_id, 1);
  return new_id;
end
$$;

-- A post's points over time, which its shared card draws: not a gated one's
-- for those who can't read it.
create or replace function news.points_curve(p_item bigint)
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
    and (not i.gated or (select news.sees_gated()))
  order by v.created_at, v.user_id
  limit 2000
$$;

-- ----------------------------------------------------------------------------
-- Owners and grants
-- ----------------------------------------------------------------------------

alter function news.sees_gated() owner to news_owner;
alter function news.gated_item(bigint) owner to news_owner;
alter function news.set_gate(bigint, boolean) owner to news_owner;
alter function news.submit_story(text, text, text, boolean, boolean, boolean) owner to news_owner;

revoke all on function
  news.sees_gated(), news.gated_item(bigint), news.set_gate(bigint, boolean),
  news.submit_story(text, text, text, boolean, boolean, boolean)
from public, anon, authenticated, service_role;

grant execute on function news.sees_gated(), news.gated_item(bigint) to anon, authenticated;
grant execute on function news.set_gate(bigint, boolean), news.submit_story(text, text, text, boolean, boolean, boolean)
to authenticated;

commit;
