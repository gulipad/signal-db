ALTER TABLE candidate_activities 
  DROP CONSTRAINT IF EXISTS candidate_activities_candidate_id_fkey,
  DROP CONSTRAINT IF EXISTS candidate_activities_project_id_fkey;

ALTER TABLE candidate_activities
  ADD CONSTRAINT candidate_activities_candidate_id_fkey 
    FOREIGN KEY (candidate_id) 
    REFERENCES candidates(candidate_id) 
    ON DELETE CASCADE,
  ADD CONSTRAINT candidate_activities_project_id_fkey 
    FOREIGN KEY (project_id) 
    REFERENCES projects(project_id) 
    ON DELETE CASCADE;