CREATE TABLE candidate_availability (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    candidate_id UUID NOT NULL,
    available_from DATE,
    unavailability_reason VARCHAR(20) CHECK (unavailability_reason IN ('STUDYING', 'CURRENT_JOB', 'OTHER')),
    reason_details TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by TEXT,
    FOREIGN KEY (candidate_id) 
        REFERENCES candidates(candidate_id) 
        ON DELETE CASCADE
);