-- Create predefined buckets for candidate management
INSERT INTO Buckets (name, is_default, created_at)
VALUES 
  ('new', TRUE, NOW()),
  ('review_later', FALSE, NOW()),
  ('watch', FALSE, NOW()),
  ('rejected', FALSE, NOW()),
  ('approved', FALSE, NOW());

-- Get the ID of the 'new' bucket for later use
DO $$
DECLARE
  new_bucket_id UUID;
BEGIN
  -- Get the ID of the 'new' bucket
  SELECT bucket_id INTO new_bucket_id FROM Buckets WHERE name = 'new';
  
  -- Assign all existing candidates to the 'new' bucket
  INSERT INTO Candidate_Buckets (candidate_id, bucket_id)
  SELECT candidate_id, new_bucket_id
  FROM Candidates;
END $$;

-- Create a function and trigger to automatically assign new candidates to the 'new' bucket
CREATE OR REPLACE FUNCTION assign_to_default_bucket()
RETURNS TRIGGER AS $$
DECLARE
  default_bucket_id UUID;
BEGIN
  -- Get the default bucket ID
  SELECT bucket_id INTO default_bucket_id FROM Buckets WHERE is_default = TRUE LIMIT 1;
  
  -- If a default bucket exists, assign the new candidate to it
  IF default_bucket_id IS NOT NULL THEN
    INSERT INTO Candidate_Buckets (candidate_id, bucket_id)
    VALUES (NEW.candidate_id, default_bucket_id);
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create the trigger to run after a new candidate is inserted
CREATE TRIGGER assign_default_bucket_trigger
AFTER INSERT ON Candidates
FOR EACH ROW
EXECUTE FUNCTION assign_to_default_bucket();
