-- ============================================================================
-- Exponential News: what /admin reads, and an announcement.
--
-- Admins' page needs a few numbers and lists nobody else may read: how News
-- did week by week, who has powers, and what moderators decided lately. Each
-- is one function, admins only. And a site-wide announcement, a line (and an
-- optional link) above every page, set like the stripe's colour; settings
-- keep their case now, which a sentence needs and a colour doesn't mind.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- The announcement
-- ----------------------------------------------------------------------------

alter table news.settings drop constraint settings_key_check;
alter table news.settings add constraint settings_key_check
  check (key in ('bar_color', 'banner_text', 'banner_link'));

create or replace function news.set_setting(p_key text, p_value text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  p_value := btrim(coalesce(p_value, ''));
  if p_key = 'bar_color' then
    p_value := lower(p_value);
    if p_value <> '' and p_value !~ '^[0-9a-f]{6}$' then
      raise exception 'value' using errcode = '22023';
    end if;
  elsif p_key = 'banner_text' then
    if char_length(p_value) > 140 or p_value ~ '[<>]' then
      raise exception 'value' using errcode = '22023';
    end if;
  elsif p_key = 'banner_link' then
    -- A page of News' own ("events", "item?id=1") or a full https address.
    if p_value <> '' and not (p_value ~ '^https://[^\s"<>]+$' or p_value ~ '^[a-z][a-z0-9/_?=&#.-]*$') then
      raise exception 'value' using errcode = '22023';
    end if;
  else
    raise exception 'key' using errcode = '22023';
  end if;
  if p_value = '' then
    delete from news.settings where key = p_key;
  else
    insert into news.settings (key, value) values (p_key, p_value)
    on conflict (key) do update set value = excluded.value;
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- What admins read
-- ----------------------------------------------------------------------------

-- Week by week, Monday to Sunday, the last p_weeks of them: who joined, what
-- was posted and said (removed and deleted aside), and how many people did
-- anything (posted, commented or voted).
create function news.admin_pulse(p_weeks int default 12)
returns table (week date, members int, posts int, comments int, active int)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform news_private.admin();
  return query
    with w as (
      select generate_series(date_trunc('week', now()) - make_interval(weeks => least(greatest(p_weeks, 1), 52) - 1),
                             date_trunc('week', now()), interval '1 week') as start
    )
    select w.start::date,
           (select count(*) from news.profiles p where p.created_at >= w.start and p.created_at < w.start + interval '1 week')::int,
           (select count(*) from news.items i where i.type = 'story' and not i.dead and not i.deleted
              and i.created_at >= w.start and i.created_at < w.start + interval '1 week')::int,
           (select count(*) from news.items i where i.type = 'comment' and not i.dead and not i.deleted
              and i.created_at >= w.start and i.created_at < w.start + interval '1 week')::int,
           (select count(distinct a.who) from (
              select i."by" as who from news.items i where i.created_at >= w.start and i.created_at < w.start + interval '1 week'
              union all
              select v.user_id from news.votes v where v.created_at >= w.start and v.created_at < w.start + interval '1 week'
            ) a)::int
      from w
     order by w.start;
end
$$;

-- How many people, and in which of Exponential's programs.
create function news.admin_counts()
returns table (members int, fellowship int, launchpad int, community int, staff int, moderators int)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform news_private.admin();
  return query
    select count(*)::int,
           (count(*) filter (where p.badge = 'fellowship'))::int,
           (count(*) filter (where p.badge = 'launchpad'))::int,
           (count(*) filter (where p.badge = 'community'))::int,
           (count(*) filter (where p.staff))::int,
           (count(*) filter (where p.auth > 0 and not p.is_admin))::int
      from news.profiles p;
end
$$;

-- Who has powers: staff, admins, moderators.
create function news.admin_people()
returns table (username text, staff boolean, is_admin boolean, moderator boolean, badge text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform news_private.admin();
  return query
    select p.username, p.staff, p.is_admin, p.auth > 0, p.badge, p.created_at
      from news.profiles p
     where p.staff or p.is_admin or p.auth > 0
     order by p.staff desc, p.is_admin desc, p.username;
end
$$;

-- What moderators decided lately: launch requests and reports, newest first.
create function news.admin_decisions(p_limit int default 20)
returns table (kind text, item_id bigint, outcome text, decided_by text, decided_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform news_private.admin();
  return query
    select d.kind, d.item_id, d.outcome, p.username, d.at
      from (
        select 'launch'::text as kind, r.item_id, case when r.approved then 'launched' else 'kept a Show' end as outcome,
               r.decided_by as who, r.decided_at as at
          from news.launch_requests r where r.approved is not null
        union all
        select 'report', f.item_id, case when f.removed then 'removed' else 'kept' end, f.reviewed_by, f.reviewed_at
          from news.flag_reviews f
      ) d
      left join news.profiles p on p.id = d.who
     order by d.at desc nulls last
     limit least(greatest(p_limit, 1), 100);
end
$$;

-- ----------------------------------------------------------------------------
-- Owners and grants
-- ----------------------------------------------------------------------------

alter function news.admin_pulse(int) owner to news_owner;
alter function news.admin_counts() owner to news_owner;
alter function news.admin_people() owner to news_owner;
alter function news.admin_decisions(int) owner to news_owner;

revoke all on function news.admin_pulse(int), news.admin_counts(), news.admin_people(), news.admin_decisions(int)
from public, anon, authenticated, service_role;
grant execute on function news.admin_pulse(int), news.admin_counts(), news.admin_people(), news.admin_decisions(int)
to authenticated;

commit;
