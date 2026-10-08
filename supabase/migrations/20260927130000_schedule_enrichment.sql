-- ============================================================================
-- SCHEDULE APPLICANT DATA FETCHING
--
-- Signal fetches GitHub and website data for applicants waiting in the inbox
-- (POST /api/cron/enrich). This used to be driven by the inbox page itself,
-- so it only ran while someone had it open. pg_cron now calls it every minute.
--
-- The URL and the shared secret are read from Vault, never stored here:
--
--   select vault.create_secret('https://signal.goexponential.org/api/cron/enrich',
--                              'enrichment_sweep_url');
--   select vault.create_secret('<CRON_SECRET from Vercel>', 'enrichment_sweep_secret');
--
-- Until both exist the job does nothing, so databases without them (local,
-- branches) never call production.
-- ============================================================================

BEGIN;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE OR REPLACE FUNCTION public.trigger_enrichment_sweep()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_url    text;
  v_secret text;
BEGIN
  SELECT decrypted_secret INTO v_url
  FROM vault.decrypted_secrets WHERE name = 'enrichment_sweep_url';
  SELECT decrypted_secret INTO v_secret
  FROM vault.decrypted_secrets WHERE name = 'enrichment_sweep_secret';
  IF v_url IS NULL OR v_secret IS NULL THEN
    RETURN;
  END IF;

  -- Fire and forget: the route answers 202 at once and works after replying.
  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_secret,
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  );
END;
$$;
REVOKE ALL ON FUNCTION public.trigger_enrichment_sweep() FROM public, anon, authenticated;
-- Re-runnable: replace the job if it already exists.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'enrichment-sweep';
SELECT cron.schedule(
  'enrichment-sweep',
  '* * * * *',
  'SELECT public.trigger_enrichment_sweep()'
);
COMMIT;
