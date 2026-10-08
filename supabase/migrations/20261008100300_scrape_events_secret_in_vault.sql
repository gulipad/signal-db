-- ============================================================================
-- SCRAPE-EVENTS: SECRET IN VAULT
--
-- The hourly `scrape-events` cron job (created by hand from
-- nextponential/supabase/scheduling.sql) carried the edge function's shared
-- secret in its command, readable by anyone with SQL access in cron.job.
-- The secret has been rotated, and the job now reads it, and the URL, from
-- Vault at run time, as trigger_enrichment_sweep() does:
--
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/scrape-events',
--                              'scrape_events_url');
--   select vault.create_secret('<SCRAPE_SECRET of the edge function>', 'scrape_events_secret');
--
-- Until both exist the job does nothing, so databases without them (local,
-- branches) never call production.
-- ============================================================================

begin;

create or replace function public.trigger_scrape_events()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'scrape_events_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'scrape_events_secret';
  if v_url is null or v_secret is null then
    return;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('x-scrape-secret', v_secret, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  );
end;
$$;
revoke all on function public.trigger_scrape_events() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'scrape-events';
select cron.schedule('scrape-events', '0 * * * *', 'select public.trigger_scrape_events()');

commit;
