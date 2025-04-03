-- Create the table to store email templates
CREATE TABLE email_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- Using UUID to match project_buckets PK type
    name VARCHAR(255) NOT NULL, -- Internal name for easy identification
    subject TEXT NOT NULL,     -- Default subject line, can contain placeholders
    body TEXT NOT NULL,        -- Default email body, can contain placeholders and HTML/Markdown
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create the join table to associate templates with project columns (buckets)
CREATE TABLE column_email_associations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- Using UUID
    project_bucket_id UUID NOT NULL, -- Changed column name and type
    email_template_id UUID NOT NULL, -- Changed type to match email_templates PK
    "order" INTEGER NOT NULL DEFAULT 0, -- Determines display order in the UI
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Foreign key constraints
    CONSTRAINT fk_project_bucket -- Renamed constraint for clarity
        FOREIGN KEY(project_bucket_id)
        REFERENCES project_buckets(bucket_id) -- Correct table and PK column name
        ON DELETE CASCADE, -- If a bucket is deleted, remove its email associations

    CONSTRAINT fk_email_template
        FOREIGN KEY(email_template_id)
        REFERENCES email_templates(id) -- References the UUID PK of email_templates
        ON DELETE CASCADE, -- If a template is deleted, remove its associations

    -- Ensure a template isn't associated multiple times with the same bucket
    UNIQUE (project_bucket_id, email_template_id)
    -- Ensure order is unique within a specific bucket (optional)
    -- UNIQUE (project_bucket_id, "order")
);