-- Create the table with the new name
CREATE TABLE public_profiles (
  profile_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id UUID NOT NULL REFERENCES candidates(candidate_id) ON DELETE CASCADE,
  is_visible BOOLEAN NOT NULL DEFAULT false,
  tldr TEXT,
  tags JSONB DEFAULT '[]'::jsonb,
  projects JSONB DEFAULT '[]'::jsonb,
  additional_notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(candidate_id)
);

-- Add indexes for performance
CREATE INDEX idx_public_profiles_candidate_id ON public_profiles(candidate_id);
CREATE INDEX idx_public_profiles_is_visible ON public_profiles(is_visible);

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION update_public_profiles_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_public_profiles_updated_at
BEFORE UPDATE ON public_profiles
FOR EACH ROW
EXECUTE FUNCTION update_public_profiles_updated_at();

-- Enable Row Level Security
ALTER TABLE public.public_profiles ENABLE ROW LEVEL SECURITY;

-- Create policy that allows authenticated users and service role to access the table
CREATE POLICY "Enable all access for authenticated users and service role" 
ON public.public_profiles
TO authenticated, service_role 
USING (true);
