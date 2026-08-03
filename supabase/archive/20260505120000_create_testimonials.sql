create table public.testimonials (
  id               uuid primary key default gen_random_uuid(),

  testimonial_type text not null check (testimonial_type in (
    'community_member',
    'fellow',
    'industry_leader'
  )),

  first_name       text not null,
  last_name        text not null,

  role             text not null,
  company          text not null,
  company_website  text,

  avatar           text,
  quote_english    text,
  quote_spanish    text,

  website          text,
  linkedin_slug    text,
  x_slug           text,
  github_slug      text,

  display_order    integer not null default 0,
  published        boolean not null default false,

  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index idx_testimonials_published_order
  on public.testimonials (published, display_order);

alter table public.testimonials enable row level security;

create policy "authenticated_full_access"
  on public.testimonials
  for all
  to authenticated
  using (true)
  with check (true);

create policy "anon_select_published"
  on public.testimonials
  for select
  to anon
  using (published = true);
