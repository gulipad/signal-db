-- Create the inbox_events table
CREATE TABLE inbox_events (
  event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'fellowship_application',
    'community_application', 
    'startup_intro_request',
    'manual_addition'
  )),
  candidate_id UUID REFERENCES candidates(candidate_id) ON DELETE CASCADE,
  startup_id UUID REFERENCES startups(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'archived')),
  priority INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  reviewed_at TIMESTAMP WITH TIME ZONE,
  reviewed_by UUID
);

-- Create indexes for efficient querying
CREATE INDEX idx_inbox_events_status_created ON inbox_events(status, created_at DESC);
CREATE INDEX idx_inbox_events_candidate ON inbox_events(candidate_id);
CREATE INDEX idx_inbox_events_type ON inbox_events(event_type);
CREATE INDEX idx_inbox_events_startup ON inbox_events(startup_id);

-- Create a function to automatically update the updated_at timestamp
CREATE OR REPLACE FUNCTION update_inbox_events_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create the trigger
CREATE TRIGGER trigger_update_inbox_events_updated_at
  BEFORE UPDATE ON inbox_events
  FOR EACH ROW
  EXECUTE FUNCTION update_inbox_events_updated_at();

-- Add RLS (Row Level Security) policies
ALTER TABLE inbox_events ENABLE ROW LEVEL SECURITY;

-- Authenticated user policies
CREATE POLICY "Enable read access for authenticated users" ON inbox_events
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Enable insert access for authenticated users" ON inbox_events
  FOR INSERT WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Enable update access for authenticated users" ON inbox_events
  FOR UPDATE USING (auth.role() = 'authenticated');

CREATE POLICY "Enable delete access for authenticated users" ON inbox_events
  FOR DELETE USING (auth.role() = 'authenticated');

-- Service role policies (full access)
CREATE POLICY "Enable all access for service role" ON inbox_events
  FOR ALL USING (auth.role() = 'service_role');