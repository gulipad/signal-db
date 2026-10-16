-- ============================================================================
-- Exponential News: images members upload.
--
-- In a post (markdown's ![words](media/...)) and as a profile photo. Files
-- live in Storage's news-images bucket, each member's in a folder named by
-- their id; News serves them from its own address (/media/<id>/<name>), so
-- what's stored is a path, and no reader's browser is sent anywhere else.
-- The bucket holds the limits too (4 MB, four image types), not only News:
-- 4 MB because a request to Vercel can't be larger than 4.5.
-- ============================================================================

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('news-images', 'news-images', true, 4194304, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- A News member uploads into their own folder, and nowhere else. Nobody
-- replaces or deletes through the API.
create policy news_images_upload on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'news-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (select 1 from news.profiles p where p.id = (select auth.uid()))
  );

-- A photo of one's own: a path in one's own folder, or none.
alter table news.profiles add column photo text not null default ''
  check (photo = '' or photo ~ ('^media/' || id::text || '/[a-z0-9]{8,64}\.(png|jpg|webp|gif)$'));
grant select (photo) on news.profiles to anon, authenticated;

-- A post may also hold an image News serves, and link to one.
create or replace function news.safe_post_html(s text) returns boolean
language sql immutable parallel safe
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
           s,
           '</?(p|em|strong|i|s|del|code|pre|blockquote|ul|li|h2|h3|h4|table|thead|tbody|tr|th|td)>|<hr>|<br>'
           '|<ol( start="[0-9]{1,9}")?>|</ol>'
           '|<a href="(https?://[^"<>[:space:]]*|media/[0-9a-f-]{36}/[a-z0-9]{8,64}\.(png|jpg|webp|gif))" rel="nofollow">|</a>'
           '|<img src="media/[0-9a-f-]{36}/[a-z0-9]{8,64}\.(png|jpg|webp|gif)" alt="[^"<>]*" loading="lazy">',
           '', 'g') !~ '[<>]'
$$;

-- update_profile, as before, and the photo (the column's check holds it to
-- the profile's own folder).
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
     set about = s.about, github = s.github, linkedin = s.linkedin, photo = s.photo, showdead = s.showdead,
         noprocrast = s.noprocrast, maxvisit = s.maxvisit, minaway = s.minaway, delay = s.delay,
         auth = s.auth, karma = s.karma, ignored = s.ignored, topcolor = s.topcolor
   where id = s.id;
end
$$;

-- The private fields of a profile, now with the photo.
drop function news.profile_private(uuid);
create function news.profile_private(p_id uuid default null)
returns table (
  id uuid, username text, created_at timestamptz, karma int, about text,
  github text, linkedin text, badge text, is_admin boolean, auth int, ignored boolean,
  showdead boolean, noprocrast boolean, firstview timestamptz, lastview timestamptz,
  maxvisit int, minaway int, topcolor text, delay int, staff boolean, photo text
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
         p.showdead, p.noprocrast, p.firstview, p.lastview, p.maxvisit, p.minaway, p.topcolor, p.delay,
         p.staff, p.photo
  from news.profiles p, v
  where p.id = coalesce(p_id, news.uid())
    and (p.id = news.uid() or v.editor)
$$;
alter function news.profile_private(uuid) owner to news_owner;
revoke all on function news.profile_private(uuid) from public, anon, authenticated, service_role;
grant execute on function news.profile_private(uuid) to anon, authenticated;

commit;
