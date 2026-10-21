-- ============================================================================
-- Exponential News: an Ask says it is one.
--
-- A post without a link was taken for an Ask, so there was nowhere to write
-- something that isn't a question (a hello, a proposal, an essay): it went
-- to Ask with the questions. News now has a plain post, with a link, words
-- or both, and an Ask carries "Ask EN: " in its title as a Show carries
-- "Show EN: " (news.arc's way; the pages show a label instead, and the
-- seed's Ask already did).
--
-- This marks the Asks already up: the posts without a link whose title is a
-- question. A title too long to take the prefix (the 80 the table allows)
-- stays a plain post.
-- ============================================================================

update news.items
set title = 'Ask EN: ' || title
where type = 'story'
  and url = ''
  and btrim(title) ~ '\?$'
  and title !~* '^\s*(ask|show|launch)\s+en\y'
  and char_length('Ask EN: ' || title) <= 80;
