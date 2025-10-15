-- Add opportunity and export_to_website fields to startups table
ALTER TABLE startups 
ADD COLUMN opportunity TEXT,
ADD COLUMN export_to_website BOOLEAN DEFAULT false;

-- Add index for filtering by export_to_website
CREATE INDEX idx_startups_export_to_website 
ON startups(export_to_website) 
WHERE export_to_website = true;

-- Add comments for documentation
COMMENT ON COLUMN startups.opportunity IS 'Type of program opportunity (e.g., fellowship, baby_fellowship)';
COMMENT ON COLUMN startups.export_to_website IS 'Whether this startup should be exported to the public website';

