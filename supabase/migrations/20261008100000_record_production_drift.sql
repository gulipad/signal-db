-- ============================================================================
-- RECORD WHAT PRODUCTION ALREADY HAS
--
-- These objects were created in production outside the migration history
-- (dashboard, other repos), so a database built from the history differed
-- from production. Found on 2026-10-08 by diffing `supabase db dump --linked`
-- against the replayed history, plus the auth.users trigger and cron jobs,
-- which schema dumps leave out. (The Gmail tables were also missing; they come
-- from signal-db's 20261005120000_add_candidate_email_log.sql, which was run
-- but never recorded, and is now recorded as is.)
--
-- Every statement is idempotent: on production this migration changes
-- nothing and only records the objects; on a fresh database it creates them.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- Website forms (RLS on, no policies: only the service role writes)
-- ----------------------------------------------------------------------------

create table if not exists public.inquiries (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  kind          text not null check (kind in ('partner', 'host')),
  name          text not null check (char_length(name) between 1 and 120),
  email         text not null check (char_length(email) between 3 and 120),
  organization  text not null check (char_length(organization) between 1 and 120),
  website       text check (website is null or char_length(website) <= 500),
  message       text not null check (char_length(message) between 1 and 2000),
  status        text not null default 'new' check (status in ('new', 'contacted', 'agreed', 'declined')),
  notes         text
);
create index if not exists inquiries_created_at_idx on public.inquiries (created_at desc);
create index if not exists inquiries_kind_status_idx on public.inquiries (kind, status, created_at desc);
alter table public.inquiries enable row level security;

create table if not exists public.speaker_proposals (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  speaker         text not null check (char_length(speaker) between 1 and 120),
  link            text check (link is null or char_length(link) <= 500),
  reason          text not null check (char_length(reason) between 1 and 600),
  proposer_email  text not null check (char_length(proposer_email) between 3 and 120),
  status          text not null default 'new' check (status in ('new', 'contacted', 'booked', 'declined')),
  notes           text
);
create index if not exists speaker_proposals_created_at_idx on public.speaker_proposals (created_at desc);
create index if not exists speaker_proposals_status_idx on public.speaker_proposals (status, created_at desc);
alter table public.speaker_proposals enable row level security;

-- ----------------------------------------------------------------------------
-- Events pruning, called by the scrape-events edge function
-- (nextponential/supabase/functions/scrape-events)
-- ----------------------------------------------------------------------------

create or replace function public.prune_events(keep_ids text[]) returns integer
language plpgsql as $$
declare
  removed integer;
begin
  -- Never delete everything on an empty / null keep-set.
  if keep_ids is null or array_length(keep_ids, 1) is null then
    return 0;
  end if;
  with d as (
    delete from public.events
    where not (api_id = any(keep_ids))
    returning 1
  )
  select count(*)::int into removed from d;
  return removed;
end;
$$;

-- ----------------------------------------------------------------------------
-- Every new auth user gets a community profile (public.profiles)
-- ----------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_created'
                 and tgrelid = 'auth.users'::regclass) then
    create trigger on_auth_user_created
      after insert on auth.users
      for each row execute function public.handle_new_user();
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- anon grants revoked by hand in production
-- ----------------------------------------------------------------------------

revoke references, trigger, truncate on
  public.candidate_activities, public.candidate_availability, public.candidate_notes,
  public.candidate_project_buckets, public.candidate_rejection_reasons, public.candidates,
  public.candidate_startup_placements, public.candidate_summaries, public.candidate_tags,
  public.column_email_associations, public.contacts, public.email_templates,
  public.inbox_events, public.programs, public.project_buckets, public.projects,
  public.public_profiles, public.rejection_reasons, public.source_data, public.sources,
  public.startup_programs, public.startups, public.tags
from anon;

-- ----------------------------------------------------------------------------
-- Daily analytics refresh (the scrape-events job is redefined in
-- 20261008100300_scrape_events_secret_in_vault.sql)
-- ----------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'refresh-analytics-daily') then
    perform cron.schedule('refresh-analytics-daily', '0 5 * * *', 'select public.refresh_analytics_daily()');
  end if;
end
$$;

commit;
