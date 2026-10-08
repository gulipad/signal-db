-- ============================================================================
-- FETCH APPLICANT DATA WHEN IT ARRIVES
--
-- Instead of polling every minute, start a sweep (trigger_enrichment_sweep,
-- 20260927130000) when:
--   * an application lands in the inbox, and
--   * a GitHub or website link is added -- the website has written the
--     application before its links, so a sweep started by the application
--     alone could run before there was anything to fetch. A link that lands
--     after a finished run marks the candidate for fetching again.
--
-- Signal keeps sweeping while people are waiting, so one trigger drains a
-- backlog. pg_cron drops to every 30 minutes as a safety net.
-- ============================================================================

BEGIN;
CREATE OR REPLACE FUNCTION public.enrich_on_new_application()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_TABLE_NAME = 'sources' THEN
    UPDATE public.candidates
    SET enrichment_status = NULL
    WHERE candidate_id = NEW.candidate_id
      AND enrichment_status IN ('done', 'failed');
  END IF;

  -- Never let fetching get in the way of saving an application.
  BEGIN
    PERFORM public.trigger_enrichment_sweep();
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'enrichment sweep not started: %', SQLERRM;
  END;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.enrich_on_new_application() FROM public, anon, authenticated;
DROP TRIGGER IF EXISTS trg_enrich_on_application ON public.inbox_events;
CREATE TRIGGER trg_enrich_on_application
  AFTER INSERT ON public.inbox_events
  FOR EACH ROW
  WHEN (NEW.event_type IN ('exponential_application', 'fellowship_application',
                           'community_application', 'manual_addition'))
  EXECUTE FUNCTION public.enrich_on_new_application();
DROP TRIGGER IF EXISTS trg_enrich_on_source ON public.sources;
CREATE TRIGGER trg_enrich_on_source
  AFTER INSERT ON public.sources
  FOR EACH ROW
  WHEN (NEW.source_type IN ('github', 'personal_website'))
  EXECUTE FUNCTION public.enrich_on_new_application();
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'enrichment-sweep';
SELECT cron.schedule(
  'enrichment-sweep',
  '*/30 * * * *',
  'SELECT public.trigger_enrichment_sweep()'
);
COMMIT;
