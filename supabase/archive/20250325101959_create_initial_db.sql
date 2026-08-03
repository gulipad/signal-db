-- Create enum for source types
CREATE TYPE source_type_enum AS ENUM ('linkedin', 'github', 'personal_website', 'application', 'other');

CREATE TABLE Candidates (
    candidate_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name VARCHAR(128),
    last_name VARCHAR(128),
    email VARCHAR(255) UNIQUE,
    phone VARCHAR(20),  -- Format: +XX XXXXXXXXX
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE Sources (
    source_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id UUID REFERENCES Candidates(candidate_id),
    source_type source_type_enum NOT NULL,
    source_identifier VARCHAR(255) NOT NULL,
    last_scraped_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE Source_Data (
    data_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id UUID REFERENCES Sources(source_id),
    json_summary JSONB NOT NULL,
    scrape_timestamp TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE Candidate_Summaries (
    candidate_summary_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id UUID REFERENCES Candidates(candidate_id),
    markdown_summary TEXT NOT NULL,
    generated_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE Buckets (
    bucket_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    is_default BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE Candidate_Buckets (
    candidate_bucket_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id UUID REFERENCES Candidates(candidate_id),
    bucket_id UUID REFERENCES Buckets(bucket_id),
    assigned_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);