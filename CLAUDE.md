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
