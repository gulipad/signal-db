-- First, drop the existing constraint
ALTER TABLE source_data DROP CONSTRAINT source_data_source_id_fkey;

-- Then add the new constraint with ON DELETE CASCADE
ALTER TABLE source_data 
ADD CONSTRAINT source_data_source_id_fkey 
FOREIGN KEY (source_id) 
REFERENCES sources(source_id) 
ON DELETE CASCADE;