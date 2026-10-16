-- ============================================================================
-- Exponential News: a post's text is markdown.
--
-- News renders a post's markdown to HTML when it is saved
-- (exponential-news lib/post-markdown.ts); this is what that HTML may hold,
-- tag by tag, as news.safe_html is for comments and abouts, which keep it
-- unchanged. Headings start at h2 (the post's title is the page's h1);
-- links are http(s) and nofollow; there are no images, attributes or
-- styles. Posts saved before (Arc's <p>, <i>, <pre><code>) still pass.
-- ============================================================================

begin;

create function news.safe_post_html(s text) returns boolean
language sql immutable parallel safe
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
           s,
           '</?(p|em|strong|i|s|del|code|pre|blockquote|ul|li|h2|h3|h4|table|thead|tbody|tr|th|td)>|<hr>|<br>'
           '|<ol( start="[0-9]{1,9}")?>|</ol>|<a href="https?://[^"<>[:space:]]*" rel="nofollow">|</a>',
           '', 'g') !~ '[<>]'
$$;
alter function news.safe_post_html(text) owner to news_owner;
revoke all on function news.safe_post_html(text) from public, anon, authenticated, service_role;
grant execute on function news.safe_post_html(text) to anon, authenticated;

alter table news.items drop constraint items_text_check;
alter table news.items add constraint items_text_check
  check (case when type = 'story' then news.safe_post_html(text) else news.safe_html(text) end);

commit;
