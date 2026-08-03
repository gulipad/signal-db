-- First, create the enum type if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'project_kind_enum') THEN
        CREATE TYPE project_kind_enum AS ENUM ('funnel', 'watchlist');
    END IF;
END
$$;

-- Then add the column to the projects table with a default value of 'funnel'
ALTER TABLE projects 
ADD COLUMN kind project_kind_enum NOT NULL DEFAULT 'funnel';

-- Set all existing projects to 'funnel' (though technically redundant due to default)
UPDATE projects SET kind = 'funnel';