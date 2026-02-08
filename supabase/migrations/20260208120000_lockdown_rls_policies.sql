-- ============================================================================
-- SECURITY LOCKDOWN: Revoke anon access and tighten RLS policies
-- ============================================================================
-- Problem: The anon role (used by publishable keys) has full table-level grants
-- and many policies use USING(true) which exposes the entire DB.
-- Fix: Revoke anon grants, drop permissive policies, create authenticated-only
-- policies, and fix the SECURITY DEFINER view.
-- ============================================================================

BEGIN;

-- ============================================================================
-- 1. REVOKE ALL PRIVILEGES FROM anon ON ALL INTERNAL TABLES
-- ============================================================================

REVOKE ALL ON TABLE public.candidates FROM anon;
REVOKE ALL ON TABLE public.sources FROM anon;
REVOKE ALL ON TABLE public.source_data FROM anon;
REVOKE ALL ON TABLE public.candidate_summaries FROM anon;
REVOKE ALL ON TABLE public.candidate_project_buckets FROM anon;
REVOKE ALL ON TABLE public.project_buckets FROM anon;
REVOKE ALL ON TABLE public.projects FROM anon;
REVOKE ALL ON TABLE public.candidate_tags FROM anon;
REVOKE ALL ON TABLE public.tags FROM anon;
REVOKE ALL ON TABLE public.candidate_notes FROM anon;
REVOKE ALL ON TABLE public.candidate_availability FROM anon;
REVOKE ALL ON TABLE public.public_profiles FROM anon;
REVOKE ALL ON TABLE public.candidate_activities FROM anon;
REVOKE ALL ON TABLE public.candidate_rejection_reasons FROM anon;
REVOKE ALL ON TABLE public.candidate_startup_placements FROM anon;
REVOKE ALL ON TABLE public.startups FROM anon;
REVOKE ALL ON TABLE public.contacts FROM anon;
REVOKE ALL ON TABLE public.programs FROM anon;
REVOKE ALL ON TABLE public.startup_programs FROM anon;
REVOKE ALL ON TABLE public.column_email_associations FROM anon;
REVOKE ALL ON TABLE public.email_templates FROM anon;
REVOKE ALL ON TABLE public.rejection_reasons FROM anon;
REVOKE ALL ON TABLE public.inbox_events FROM anon;

-- Also revoke on the view
REVOKE ALL ON TABLE public.public_bucket_candidates FROM anon;

-- ============================================================================
-- 2. DROP ALL OVERLY-PERMISSIVE POLICIES ON INTERNAL TABLES
-- ============================================================================

-- Drop the blanket "Enable all access for authenticated users and service role" policies
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidates;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.sources;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.source_data;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_summaries;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_project_buckets;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.project_buckets;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.projects;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_tags;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.tags;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_notes;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_availability;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.public_profiles;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_activities;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_rejection_reasons;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.candidate_startup_placements;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.column_email_associations;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.email_templates;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.rejection_reasons;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.programs;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.startup_programs;
DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.contacts;

-- Drop the public slug access policy (slug access uses service_role client)
DROP POLICY IF EXISTS "Allow public access to candidates via slug" ON public.candidates;

-- Drop the overly-permissive startups policies (uses {public} role)
DROP POLICY IF EXISTS "Everyone can view startups" ON public.startups;
DROP POLICY IF EXISTS "Authenticated users can manage startups" ON public.startups;

-- Drop the inbox_events policies that use {public} role
DROP POLICY IF EXISTS "Enable all access for service role" ON public.inbox_events;
DROP POLICY IF EXISTS "Enable delete access for authenticated users" ON public.inbox_events;
DROP POLICY IF EXISTS "Enable insert access for authenticated users" ON public.inbox_events;
DROP POLICY IF EXISTS "Enable read access for authenticated users" ON public.inbox_events;
DROP POLICY IF EXISTS "Enable update access for authenticated users" ON public.inbox_events;

-- ============================================================================
-- 3. CREATE PROPER AUTHENTICATED-ONLY POLICIES
-- ============================================================================

-- Candidates
CREATE POLICY "authenticated_full_access" ON public.candidates
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Sources
CREATE POLICY "authenticated_full_access" ON public.sources
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Source Data
CREATE POLICY "authenticated_full_access" ON public.source_data
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Summaries
CREATE POLICY "authenticated_full_access" ON public.candidate_summaries
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Project Buckets
CREATE POLICY "authenticated_full_access" ON public.candidate_project_buckets
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Project Buckets
CREATE POLICY "authenticated_full_access" ON public.project_buckets
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Projects
CREATE POLICY "authenticated_full_access" ON public.projects
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Tags
CREATE POLICY "authenticated_full_access" ON public.candidate_tags
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Tags
CREATE POLICY "authenticated_full_access" ON public.tags
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Notes
CREATE POLICY "authenticated_full_access" ON public.candidate_notes
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Availability
CREATE POLICY "authenticated_full_access" ON public.candidate_availability
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Public Profiles
CREATE POLICY "authenticated_full_access" ON public.public_profiles
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Activities
CREATE POLICY "authenticated_full_access" ON public.candidate_activities
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Rejection Reasons
CREATE POLICY "authenticated_full_access" ON public.candidate_rejection_reasons
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Candidate Startup Placements
CREATE POLICY "authenticated_full_access" ON public.candidate_startup_placements
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Startups
CREATE POLICY "authenticated_full_access" ON public.startups
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Contacts
CREATE POLICY "authenticated_full_access" ON public.contacts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Programs
CREATE POLICY "authenticated_full_access" ON public.programs
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Startup Programs
CREATE POLICY "authenticated_full_access" ON public.startup_programs
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Column Email Associations
CREATE POLICY "authenticated_full_access" ON public.column_email_associations
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Email Templates
CREATE POLICY "authenticated_full_access" ON public.email_templates
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Rejection Reasons
CREATE POLICY "authenticated_full_access" ON public.rejection_reasons
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Inbox Events
CREATE POLICY "authenticated_full_access" ON public.inbox_events
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ============================================================================
-- 4. FIX THE SECURITY DEFINER VIEW
-- ============================================================================
-- The public_bucket_candidates view is SECURITY DEFINER, which means it runs
-- with the view creator's permissions (bypassing RLS). Since it's only accessed
-- via the service_role client, we can safely make it SECURITY INVOKER.

ALTER VIEW public.public_bucket_candidates SET (security_invoker = on);

COMMIT;
