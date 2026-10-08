# Signal DB

## Project Overview

Supabase-backed database for managing startups, contacts, and programs for an accelerator/fellowship platform (Exponential).

## Key Tables

- `startups` - Company/startup records (name, slug, funding stage, etc.)
- `contacts` - People associated with startups (name, email, role, phone, linkedin_id)
- `programs` - Accelerator/fellowship programs
- `startup_programs` - Many-to-many junction linking startups to programs

## Common Workflows

### Adding a contact to a startup

1. Find the startup ID using the Supabase MCP:
   ```sql
   SELECT id, name FROM startups WHERE name ILIKE '%<name>%';
   ```
2. Insert the contact:
   ```sql
   INSERT INTO contacts (startup_id, first_name, last_name, email, role, phone, linkedin_id)
   VALUES ('<startup_id>', '<first>', '<last>', '<email>', '<role>', '<phone>', '<linkedin_username>');
   ```
- `linkedin_id` stores just the LinkedIn username/slug (not the full URL)
- Only one contact per startup can have `is_primary = true`

### Sending emails via Resend

- Default from address: `hello@goexponential.org`
- Always draft the email and show it to the user before sending
- Always ask the user for BCC/CC addresses — never assume them
- Use the `mcp__resend__send-email` tool to send

## MCP Servers

- **Supabase** — for database queries (`mcp__supabase__execute_sql`, etc.)
- **Resend** — for sending emails (`mcp__resend__send-email`, etc.)
- **Claude in Chrome** — for browser automation

## Exponential News

Exponential News (github.com/goexponential/exponential-news, a public Hacker
News clone) uses this project too. All of its migrations live here.

- Its tables and functions live in the `news` (exposed through the Data API)
  and `news_private` (not exposed) schemas, owned by the `news_owner` role.
  Never grant `news_owner` anything on Signal tables.
- `news_bridge` reads only who was accepted (a few columns of `candidates`,
  `candidate_activities`, `candidate_track_events`) to give News badges; it
  runs from the `news-signal-badges` cron job. Badge rules are in
  `news_private.badge_rules`.
- News accounts are auth users with `user_metadata.signup_app = 'news'` and
  get no `public.profiles` row.
- Its auth email templates are `supabase/templates/`. Production's project
  settings for News (exposed `news` schema, email sign-up with confirmation,
  templates, redirect URL, SMTP) are applied with
  `scripts/news-production-settings.sh`, which changes nothing else.

## Local development

`supabase start` builds production's schema from `supabase/migrations`, then
loads `supabase/seed.sql` (yours, gitignored) and `supabase/seeds/` (made-up
candidates and News demo accounts). `supabase test db` runs the pgTAP tests
in `supabase/tests`, including the checks that News users can't reach Signal
data. Add a migration here for every schema change, including ones made in
production first, so a database built from this directory keeps matching it.
