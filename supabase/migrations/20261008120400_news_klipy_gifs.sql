-- ============================================================================
-- Exponential News: GIFs from KLIPY in comments.
--
-- A comment can carry a GIF picked from KLIPY (klipy.com, a GIF API). The
-- comment's text keeps the GIF's media url on a line of its own; lib/arc.ts
-- renders a KLIPY media url as an image instead of a link. KLIPY requires
-- its media to be loaded straight from the urls its API returns, so the
-- image points at KLIPY's media hosts (static.klipy.com, static1, static2...)
-- and nothing is copied here.
--
-- news.safe_html learns exactly that one tag, in exactly the form the app
-- writes, with https urls on KLIPY's media hosts only. Anything else that
-- looks like an image is still rejected.
-- ============================================================================

create or replace function news.safe_html(s text) returns boolean
language sql immutable parallel safe
set search_path = ''
as $$
  select pg_catalog.regexp_replace(
           s,
           '<p>|<pre><code>|</code></pre>|<i>|</i>|<a href="https?://[^"<>[:space:]]*" rel="nofollow">|</a>'
           '|<img class="gif" src="https://static[0-9]*\.klipy\.com/[^"<>[:space:]]+" alt="GIF" loading="lazy">',
           '', 'g') !~ '[<>]'
$$;
