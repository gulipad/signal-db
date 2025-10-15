-- Add opportunity and export_to_website fields to inbox_events table
ALTER TABLE inbox_events 
ADD COLUMN opportunity TEXT,
ADD COLUMN export_to_website BOOLEAN DEFAULT false;

-- Add index for filtering by export_to_website
CREATE INDEX idx_inbox_events_export_to_website 
ON inbox_events(export_to_website) 
WHERE export_to_website = true;

-- Add comment for documentation
COMMENT ON COLUMN inbox_events.opportunity IS 'Type of program opportunity (e.g., fellowship, baby_fellowship)';
COMMENT ON COLUMN inbox_events.export_to_website IS 'Whether this candidate profile should be exported to the public website';

