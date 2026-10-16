-- ============================================================================
-- Exponential News: reports a moderator reviews.
--
-- Any member reports a post or comment as noise. It waits for a moderator or
-- an admin (News' /reported, news.reported_items), who removes it or keeps
-- it (news.review_reports). Keeping clears the reports made until then: they
-- leave the queue and stop counting toward removal.
--
-- Removal by numbers alone stays as it was (more than seven reports on an
-- item under 10 points that no admin upvoted), but now that anyone can
-- report, only reports from members over 30 points count toward it: new
-- accounts can't take anything down between them, only ask a moderator to.
-- ============================================================================

begin;

create table news.flag_reviews (
  item_id      bigint primary key references news.items on delete cascade,
  reviewed_by  uuid references news.profiles on delete set null,
  reviewed_at  timestamptz not null default now(),
  removed      boolean not null
);
alter table news.flag_reviews owner to news_owner;
-- Read and written only by the functions below.
alter table news.flag_reviews enable row level security;

-- Moderators and admins.
create function news_private.editor() returns news.profiles
language plpgsql stable
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
begin
  if not (me.is_admin or me.auth > 0) then
    raise exception 'editor' using errcode = '42501';
  end if;
  return me;
end
$$;

-- Reporting: any member, anything that isn't theirs.
create or replace function news.toggle_flag(p_item bigint)
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
  if i.id is null or i."by" = me.id or not (i.visible_at <= now()) then
    return false;
  end if;
  if exists (select 1 from news.flags where user_id = me.id and item_id = p_item) then
    delete from news.flags where user_id = me.id and item_id = p_item;
    return true;
  end if;
  insert into news.flags (user_id, item_id) values (me.id, p_item);
  select count(*) into n
    from news.flags f join news.profiles p on p.id = f.user_id
   where f.item_id = p_item and (p.is_admin or p.karma > 30)
     and f.created_at > coalesce((select r.reviewed_at from news.flag_reviews r where r.item_id = p_item), '-infinity');
  if n > 7 and i.score - i.sockvotes < 10 and not ('nokill' = any (i.keys))
     and not exists (select 1 from news.votes v join news.profiles p on p.id = v.user_id
                     where v.item_id = p_item and p.is_admin) then
    update news.items set dead = true where id = p_item;
  end if;
  return true;
end
$$;

-- What waits for a moderator: live items with reports since they were last
-- kept, most reported first.
create function news.reported_items(p_limit int default 210)
returns table (item_id bigint, reports bigint, last_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform news_private.editor();
  return query
    select f.item_id, count(*)::bigint, max(f.created_at)
      from news.flags f
      join news.items i on i.id = f.item_id
      left join news.flag_reviews r on r.item_id = f.item_id
     where not i.dead and not i.deleted
       and f.created_at > coalesce(r.reviewed_at, '-infinity')
     group by f.item_id
     order by count(*) desc, max(f.created_at) desc
     limit least(greatest(p_limit, 0), 1000);
end
$$;

create function news.reported_count()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) from news.reported_items(1000)
$$;

-- A moderator's decision: remove it (as Removed in Edit does, which an
-- admin's "nokill" holds back from moderators), or keep it.
create function news.review_reports(p_item bigint, p_remove boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.editor();
  i  news.items;
begin
  select * into i from news.items where id = p_item for update;
  if i.id is null then
    raise exception 'noitem' using errcode = '22023';
  end if;
  if p_remove then
    if 'nokill' = any (i.keys) and not me.is_admin then
      raise exception 'nokill' using errcode = '22023';
    end if;
    update news.items set dead = true where id = p_item;
  end if;
  insert into news.flag_reviews (item_id, reviewed_by, removed) values (p_item, me.id, coalesce(p_remove, false))
  on conflict (item_id) do update
    set reviewed_by = excluded.reviewed_by, reviewed_at = now(), removed = excluded.removed;
end
$$;

alter function news_private.editor() owner to news_owner;
alter function news.reported_items(int) owner to news_owner;
alter function news.reported_count() owner to news_owner;
alter function news.review_reports(bigint, boolean) owner to news_owner;

revoke all on function
  news_private.editor(), news.reported_items(int), news.reported_count(), news.review_reports(bigint, boolean)
from public, anon, authenticated, service_role;

grant execute on function news.reported_items(int), news.reported_count(), news.review_reports(bigint, boolean)
to authenticated;

commit;
