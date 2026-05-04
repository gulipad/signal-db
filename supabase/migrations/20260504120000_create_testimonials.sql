-- =============================================================
-- Testimonials for the wall-of-love page
--
-- Pattern: optional FK to candidates + flat override columns.
-- A resolver view (testimonials_resolved) coalesces overrides
-- with candidate-derived data so the page sees a single shape.
-- =============================================================

create table public.testimonials (
  id                uuid primary key default gen_random_uuid(),

  -- Optional link. When set, the resolver view fills in name and
  -- linkedin/github slugs from candidates + sources.
  candidate_id      uuid unique references public.candidates(candidate_id) on delete restrict,

  testimonial_type  text not null check (testimonial_type in (
    'community_member',
    'fellow',
    'industry_leader'
  )),

  -- Override identity fields (nullable; resolver falls back to candidates)
  first_name        text,
  last_name         text,

  -- Testimonial-time facts (always live on the testimonial)
  role              text not null,
  company           text not null,
  company_website   text,

  avatar            text,
  quote             text not null,

  -- Override social fields. linkedin_slug/github_slug fall back to sources;
  -- website and x_slug are manual-only (no clean source).
  website           text,
  linkedin_slug     text,
  x_slug            text,
  github_slug       text,

  display_order     integer not null default 0,
  published         boolean not null default true,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index idx_testimonials_published_order
  on public.testimonials (published, display_order);

alter table public.testimonials enable row level security;

-- Internal admin access (matches existing convention)
create policy "authenticated_full_access"
  on public.testimonials
  for all
  to authenticated
  using (true)
  with check (true);

-- Public marketing page reads only published rows
create policy "anon_select_published"
  on public.testimonials
  for select
  to anon
  using (published = true);

-- ─────────────────────────────────────────────────────────────
-- Resolver view: coalesces overrides with candidate-derived data.
-- security_invoker=true so the underlying RLS policies apply.
-- ─────────────────────────────────────────────────────────────
create view public.testimonials_resolved
with (security_invoker = true)
as
select
  t.id,
  t.candidate_id,
  t.testimonial_type,

  coalesce(t.first_name, c.first_name) as first_name,
  coalesce(t.last_name,  c.last_name)  as last_name,

  t.role,
  t.company,
  t.company_website,

  t.avatar,
  t.quote,

  t.website,
  coalesce(
    t.linkedin_slug,
    (select s.source_identifier
       from public.sources s
      where s.candidate_id = t.candidate_id
        and s.source_type = 'linkedin'
      limit 1)
  ) as linkedin_slug,
  t.x_slug,
  coalesce(
    t.github_slug,
    (select s.source_identifier
       from public.sources s
      where s.candidate_id = t.candidate_id
        and s.source_type = 'github'
      limit 1)
  ) as github_slug,

  t.display_order,
  t.published,
  t.created_at,
  t.updated_at
from public.testimonials t
left join public.candidates c on c.candidate_id = t.candidate_id
order by t.display_order asc, t.created_at asc;
