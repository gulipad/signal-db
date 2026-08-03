CREATE TABLE candidate_activities (
  activity_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id UUID NOT NULL REFERENCES candidates(candidate_id),
  activity_type TEXT NOT NULL CHECK (activity_type IN ('bucket_assignment', 'availability_change', 'source_update', 'email_sent')),
  activity_timestamp TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW() NOT NULL,
  actor_id UUID REFERENCES auth.users(id),
  metadata JSONB,
  project_id UUID REFERENCES projects(project_id),
  created_at TIMESTAMP WITHOUT TIME ZONE DEFAULT NOW() NOT NULL
);

-- Create indexes for better query performance
CREATE INDEX idx_candidate_activities_candidate_id ON candidate_activities(candidate_id);
CREATE INDEX idx_candidate_activities_timestamp ON candidate_activities(activity_timestamp);
CREATE INDEX idx_candidate_activities_type ON candidate_activities(activity_type);

-- Add RLS policies so the table respects your existing security model
ALTER TABLE candidate_activities ENABLE ROW LEVEL SECURITY;

-- Create a single policy for both authenticated users and service_role
CREATE POLICY "Enable all access for authenticated users and service role" 
ON candidate_activities
FOR ALL
TO authenticated, service_role
USING (true)
WITH CHECK (true);

-- Add ordering column with a default value of 0
ALTER TABLE projects ADD COLUMN order_index INTEGER NOT NULL DEFAULT 0;

-- Add is_deprecated column with default value of false
ALTER TABLE projects ADD COLUMN is_deprecated BOOLEAN NOT NULL DEFAULT false;

-- Optional: Create an index on order_index to optimize sorting queries
CREATE INDEX idx_projects_order_index ON projects(order_index);