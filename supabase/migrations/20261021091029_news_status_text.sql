-- ============================================================================
-- Exponential News: a status says something too.
--
-- As Slack's: the emoji by someone's name, and a line of words read when the
-- emoji is pointed at or tapped ("De vacaciones hasta el lunes"). Plain text,
-- as the page shows it, never markup; 100 characters at most.
-- ============================================================================

alter table news.profiles add column status_text text not null default ''
  check (char_length(status_text) <= 100 and status_text !~ '[[:cntrl:]]');
grant select (status_text) on news.profiles to anon, authenticated;

-- update_profile, as before, and the status's words.
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
    if jsonb_typeof(c -> 'status_text') = 'string' then s.status_text := c ->> 'status_text'; end if;
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
         status_text = s.status_text, showdead = s.showdead, noprocrast = s.noprocrast, maxvisit = s.maxvisit,
         minaway = s.minaway, delay = s.delay, auth = s.auth, karma = s.karma, ignored = s.ignored,
         topcolor = s.topcolor
   where id = s.id;
end
$$;
