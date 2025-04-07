-- Drop the existing trigger
DROP TRIGGER IF EXISTS assign_default_bucket_trigger ON "Candidates";
DROP TRIGGER IF EXISTS assign_default_bucket_trigger ON candidates;

-- Update the function to use lowercase table names
CREATE OR REPLACE FUNCTION assign_to_default_bucket()
RETURNS TRIGGER AS $$
DECLARE
  default_bucket_id UUID;
BEGIN
  -- Get the default bucket ID
  SELECT bucket_id INTO default_bucket_id FROM buckets WHERE is_default = TRUE LIMIT 1;
  
  -- If a default bucket exists, assign the new candidate to it
  IF default_bucket_id IS NOT NULL THEN
    INSERT INTO candidate_buckets (candidate_id, bucket_id)
    VALUES (NEW.candidate_id, default_bucket_id);
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate the trigger on the lowercase table
CREATE TRIGGER assign_default_bucket_trigger
AFTER INSERT ON candidates
FOR EACH ROW
EXECUTE FUNCTION assign_to_default_bucket(); 