-- Add cascade delete for sources
ALTER TABLE sources
DROP CONSTRAINT IF EXISTS sources_candidate_id_fkey,
ADD CONSTRAINT sources_candidate_id_fkey 
FOREIGN KEY (candidate_id) REFERENCES candidates(candidate_id) 
ON DELETE CASCADE;

-- Add cascade delete for candidate_tags
ALTER TABLE candidate_tags
DROP CONSTRAINT IF EXISTS candidate_tags_candidate_id_fkey,
ADD CONSTRAINT candidate_tags_candidate_id_fkey 
FOREIGN KEY (candidate_id) REFERENCES candidates(candidate_id) 
ON DELETE CASCADE;

-- Add cascade delete for candidate_summaries
ALTER TABLE candidate_summaries
DROP CONSTRAINT IF EXISTS candidate_summaries_candidate_id_fkey,
ADD CONSTRAINT candidate_summaries_candidate_id_fkey 
FOREIGN KEY (candidate_id) REFERENCES candidates(candidate_id) 
ON DELETE CASCADE;

-- Add cascade delete for candidate_notes
ALTER TABLE candidate_notes
DROP CONSTRAINT IF EXISTS candidate_notes_candidate_id_fkey,
ADD CONSTRAINT candidate_notes_candidate_id_fkey 
FOREIGN KEY (candidate_id) REFERENCES candidates(candidate_id) 
ON DELETE CASCADE;

-- Add cascade delete for candidate_project_buckets
ALTER TABLE candidate_project_buckets
DROP CONSTRAINT IF EXISTS candidate_project_buckets_candidate_id_fkey,
ADD CONSTRAINT candidate_project_buckets_candidate_id_fkey 
FOREIGN KEY (candidate_id) REFERENCES candidates(candidate_id) 
ON DELETE CASCADE;

-- Add cascade delete for candidate_rejection_reasons
ALTER TABLE candidate_rejection_reasons
DROP CONSTRAINT IF EXISTS candidate_rejection_reasons_candidate_id_fkey,
ADD CONSTRAINT candidate_rejection_reasons_candidate_id_fkey 
FOREIGN KEY (candidate_id) REFERENCES candidates(candidate_id) 
ON DELETE CASCADE;

-- Add cascade delete for source_data

ALTER TABLE source_data
DROP CONSTRAINT IF EXISTS source_data_source_id_fkey,
ADD CONSTRAINT source_data_source_id_fkey 
FOREIGN KEY (source_id) REFERENCES sources(source_id) 
ON DELETE CASCADE;

