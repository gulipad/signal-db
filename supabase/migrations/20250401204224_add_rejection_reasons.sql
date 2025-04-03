-- Add is_rejection_column flag to project_buckets table
ALTER TABLE project_buckets 
ADD COLUMN is_rejection_column BOOLEAN NOT NULL DEFAULT false;

-- Create rejection_reasons table
CREATE TABLE rejection_reasons (
  reason_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  CONSTRAINT fk_project_id
    FOREIGN KEY (project_id)
    REFERENCES projects(project_id)
    ON DELETE CASCADE
);

-- Create candidate_rejection_reasons table to store the selected reasons
CREATE TABLE candidate_rejection_reasons (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id UUID NOT NULL,
  project_id UUID NOT NULL,
  bucket_id UUID NOT NULL,
  reason_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  CONSTRAINT fk_candidate_id
    FOREIGN KEY (candidate_id)
    REFERENCES candidates(candidate_id)
    ON DELETE CASCADE,
  
  CONSTRAINT fk_project_id
    FOREIGN KEY (project_id)
    REFERENCES projects(project_id)
    ON DELETE CASCADE,
  
  CONSTRAINT fk_bucket_id
    FOREIGN KEY (bucket_id)
    REFERENCES project_buckets(bucket_id)
    ON DELETE CASCADE,
  
  CONSTRAINT fk_reason_id
    FOREIGN KEY (reason_id)
    REFERENCES rejection_reasons(reason_id)
    ON DELETE CASCADE,
  
  -- Ensure a candidate can't have the same rejection reason multiple times in the same bucket
  CONSTRAINT unique_candidate_bucket_reason
    UNIQUE (candidate_id, bucket_id, reason_id)
);