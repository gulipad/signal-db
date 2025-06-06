-- Add public_description column to project_buckets table
ALTER TABLE project_buckets 
ADD COLUMN public_description TEXT,
ADD COLUMN is_public BOOLEAN DEFAULT false,
ADD COLUMN public_password TEXT;

-- Drop existing view if it exists
DROP VIEW IF EXISTS public_bucket_candidates;

-- Create view for public bucket candidates with social media identifiers
CREATE OR REPLACE VIEW public_bucket_candidates AS
WITH latest_successful_sources AS (
  SELECT DISTINCT ON (s.candidate_id, s.source_type) 
    s.candidate_id,
    s.source_type,
    s.source_identifier
  FROM sources s
  JOIN source_data sd ON s.source_id = sd.source_id
  WHERE sd.success = true
    AND s.source_type IN ('linkedin', 'github', 'personal_website')
  ORDER BY s.candidate_id, s.source_type, s.created_at DESC
),
candidate_social_links AS (
  SELECT 
    candidate_id,
    MAX(CASE WHEN source_type = 'linkedin' THEN source_identifier END) as linkedin_identifier,
    MAX(CASE WHEN source_type = 'github' THEN source_identifier END) as github_identifier,
    MAX(CASE WHEN source_type = 'personal_website' THEN source_identifier END) as website_url
  FROM latest_successful_sources
  GROUP BY candidate_id
)
SELECT 
  pb.project_id,
  pb.bucket_id,
  p.name as project_name,
  pb.name as bucket_name,
  pb.public_description,
  c.candidate_id,
  c.first_name,
  c.last_name,
  c.email,
  c.candidate_slug,
  c.created_at,
  pp.tldr,
  pp.tags,
  csl.linkedin_identifier,
  csl.github_identifier,
  csl.website_url
FROM project_buckets pb
JOIN projects p ON pb.project_id = p.project_id
JOIN candidate_project_buckets cpb ON pb.bucket_id = cpb.bucket_id
JOIN candidates c ON cpb.candidate_id = c.candidate_id
LEFT JOIN public_profiles pp ON c.candidate_id = pp.candidate_id AND pp.is_visible = true
LEFT JOIN candidate_social_links csl ON c.candidate_id = csl.candidate_id
WHERE pb.is_public = true; 