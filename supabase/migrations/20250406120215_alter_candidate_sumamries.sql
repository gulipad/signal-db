-- Update candidate_summaries table to be consistent with existing schema
ALTER TABLE candidate_summaries 
ADD COLUMN IF NOT EXISTS success BOOLEAN DEFAULT TRUE,
ADD COLUMN IF NOT EXISTS sources_used JSONB, -- Array of source_ids
ADD COLUMN IF NOT EXISTS recommended_tags JSONB, -- Array of {tag_id, confidence} objects
ADD COLUMN IF NOT EXISTS json_summary JSONB, -- Full analysis data
ADD COLUMN IF NOT EXISTS analysis_version TEXT;

ALTER TABLE candidate_summaries
DROP COLUMN markdown_summary;