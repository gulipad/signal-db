-- ============================================================================
-- Exponential News: a status set from anywhere, that clears itself.
--
-- As Slack's: set from the account's menu, in one go (the emoji, its words,
-- and when it goes: in an hour, at the end of the day, never). Past
-- status_until the status is gone: the app shows none, so nothing needs to
-- sweep it. Clearing the emoji clears all three.
-- ============================================================================

alter table news.profiles add column status_until timestamptz;
grant select (status_until) on news.profiles to anon, authenticated;

create function news.set_status(p_status text, p_text text, p_until timestamptz default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me news.profiles := news_private.me();
  clear boolean := coalesce(p_status, '') = '';
begin
  if not clear and p_until is not null and p_until <= now() then
    raise exception 'past' using errcode = '22023';
  end if;
  update news.profiles
     set status = coalesce(p_status, ''),
         status_text = case when clear then '' else coalesce(p_text, '') end,
         status_until = case when clear then null else p_until end
   where id = me.id;
end
$$;

alter function news.set_status(text, text, timestamptz) owner to news_owner;
revoke all on function news.set_status(text, text, timestamptz) from public, anon, authenticated, service_role;
grant execute on function news.set_status(text, text, timestamptz) to authenticated;
