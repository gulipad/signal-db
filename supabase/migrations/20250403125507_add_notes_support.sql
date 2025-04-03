CREATE TABLE candidate_notes (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  candidate_id uuid NOT NULL REFERENCES candidates(candidate_id) ON DELETE CASCADE,
  content text NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  created_by uuid NULL,  -- Could reference a users table if you have one
  CONSTRAINT fk_candidate
    FOREIGN KEY(candidate_id)
    REFERENCES candidates(candidate_id)
    ON DELETE CASCADE
);