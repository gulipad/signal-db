-- Add scrape_status column to Source_Data table
ALTER TABLE Source_Data
ADD COLUMN success BOOLEAN;

-- Set all existing records to true
UPDATE Source_Data
SET success = TRUE;
