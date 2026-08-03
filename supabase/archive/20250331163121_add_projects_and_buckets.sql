CREATE TABLE IF NOT EXISTS projects (
  project_id uuid DEFAULT uuid_generate_v4() NOT NULL, 
  name text NOT NULL, 
  description text, 
  created_at timestamp with time zone DEFAULT now(), 
  updated_at timestamp with time zone DEFAULT now(), 
  PRIMARY KEY (project_id)
);

CREATE TABLE IF NOT EXISTS project_buckets (
  bucket_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  project_id UUID NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  order_index INTEGER NOT NULL,
  color TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(project_id, name)
);

CREATE TABLE IF NOT EXISTS candidate_project_buckets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  candidate_id UUID NOT NULL REFERENCES candidates(candidate_id) ON DELETE CASCADE,
  project_id UUID NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
  bucket_id UUID NOT NULL REFERENCES project_buckets(bucket_id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(candidate_id, project_id)
);

-- 2. Create a default project for existing buckets
INSERT INTO projects (project_id, name, description)
VALUES (
  uuid_generate_v4(),
  'Cohort #02',
  'Applicants for Exponential Fellowship Cohort #02'
);

-- 3. Migrate existing buckets to project_buckets
WITH default_project AS (
  SELECT project_id FROM projects LIMIT 1
)
INSERT INTO project_buckets (
  bucket_id,
  project_id,
  name,
  order_index
)
SELECT 
  bucket_id,
  (SELECT project_id FROM default_project),
  name,
  ROW_NUMBER() OVER (ORDER BY created_at) as order_index
FROM buckets b;

-- 4. Migrate existing candidate-bucket relationships
WITH default_project AS (
  SELECT project_id FROM projects LIMIT 1
)
INSERT INTO candidate_project_buckets (
  candidate_id,
  project_id,
  bucket_id
)
SELECT 
  cb.candidate_id,
  (SELECT project_id FROM default_project),
  cb.bucket_id
FROM candidate_buckets cb;

-- 5. Create indexes for performance
CREATE INDEX idx_project_buckets_project_id ON project_buckets(project_id);
CREATE INDEX idx_candidate_project_buckets_candidate_id ON candidate_project_buckets(candidate_id);
CREATE INDEX idx_candidate_project_buckets_project_id ON candidate_project_buckets(project_id);
CREATE INDEX idx_candidate_project_buckets_bucket_id ON candidate_project_buckets(bucket_id);

-- 6. Only after verifying the migration was successful:
-- DROP TABLE candidate_buckets;
-- DROP TABLE buckets;