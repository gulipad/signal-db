-- =============================================================
-- Founder Forum: members, applications, and inbox integration
-- =============================================================

-- 1. founder_forum_members — the person
create table public.founder_forum_members (
  id                 uuid primary key default gen_random_uuid(),
  first_name         text not null,
  last_name          text not null,
  email              text not null,
  phone_country_code text not null,
  phone_dial_code    text not null,
  phone_local_number text not null,
  phone_full         text not null,
  linkedin           text not null,
  twitter            text not null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

alter table public.founder_forum_members enable row level security;

-- 2. founder_forum_applications — each submission
create table public.founder_forum_applications (
  id                 uuid primary key default gen_random_uuid(),
  member_id          uuid not null references public.founder_forum_members(id),
  startup_id         uuid references public.startups(id),

  -- personal context (can change between applications)
  role               text not null check (role in ('Fundador', 'Co-fundador', 'Otro')),
  title              text not null,

  -- empresa
  company_website    text not null,
  capital_raised     text not null check (capital_raised in ('Bootstrapped', '<1M€', '1-5M€', '5-10M€', '10-50M€', '+50M€')),
  revenue_range      text not null check (revenue_range in ('Pre-revenue', '<1M€', '1-5M€', '5-10M€', '10-50M€', '+50M€')),
  investor_websites  text[] not null default '{}',

  -- otros
  referred_by        text,
  discovery_channel  text check (discovery_channel in ('LinkedIn', 'Boca a boca', 'Búsqueda', 'Twitter', 'Reddit', 'ChatGPT & otros')),

  -- status
  status             text not null default 'applied' check (status in ('applied', 'accepted', 'rejected')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

alter table public.founder_forum_applications enable row level security;

-- 3. Wire into inbox_events
alter table public.inbox_events
  add column founder_forum_application_id uuid references public.founder_forum_applications(id);

alter table public.inbox_events
  drop constraint inbox_events_event_type_check;

alter table public.inbox_events
  add constraint inbox_events_event_type_check
  check (event_type in (
    'fellowship_application',
    'community_application',
    'startup_intro_request',
    'manual_addition',
    'founder_forum_application'
  ));

-- 4. Add Ateneo program
insert into public.programs (name, description)
values ('Ateneo', 'Founder forum program for company founders in Spain.');

-- 5. RLS policies (matches existing convention)
create policy "authenticated_full_access"
  on public.founder_forum_members
  for all
  to authenticated
  using (true)
  with check (true);

create policy "authenticated_full_access"
  on public.founder_forum_applications
  for all
  to authenticated
  using (true)
  with check (true);
