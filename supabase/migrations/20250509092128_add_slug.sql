-- Add the candidate_slug column to the candidates table
ALTER TABLE public.candidates
ADD COLUMN candidate_slug TEXT UNIQUE;

-- Create extension for unaccent function if it doesn't exist
CREATE EXTENSION IF NOT EXISTS unaccent;

-- Create a function to generate slugs based on candidate names
CREATE OR REPLACE FUNCTION generate_candidate_slug(
  first_name TEXT,
  last_name TEXT,
  candidate_id UUID
) RETURNS TEXT AS $$
DECLARE
  base_slug TEXT;
  final_slug TEXT;
  counter INTEGER := 1;
BEGIN
  -- Create base slug from name (or use candidate_id prefix if no name)
  IF first_name IS NOT NULL OR last_name IS NOT NULL THEN
    -- First unaccent the names to convert accented characters to their ASCII equivalents
    base_slug := LOWER(
      REGEXP_REPLACE(
        UNACCENT(COALESCE(first_name, '')) || '-' || UNACCENT(COALESCE(last_name, '')),
        '[^a-zA-Z0-9]', '-', 'g'
      )
    );
    -- Remove consecutive dashes and trim
    base_slug := REGEXP_REPLACE(base_slug, '-+', '-', 'g');
    base_slug := REGEXP_REPLACE(base_slug, '^-|-$', '', 'g');
  ELSE
    -- Fallback to using candidate_id prefix if no name available
    base_slug := 'candidate-' || SUBSTRING(candidate_id::TEXT, 1, 8);
  END IF;
  
  -- Check if the slug already exists and append counter if needed
  final_slug := base_slug;
  WHILE EXISTS (SELECT 1 FROM public.candidates WHERE candidate_slug = final_slug) LOOP
    counter := counter + 1;
    final_slug := base_slug || '-' || counter::TEXT;
  END LOOP;
  
  RETURN final_slug;
END;
$$ LANGUAGE plpgsql;

-- Populate slugs for existing candidates
DO $$
DECLARE
  candidate_rec RECORD;
BEGIN
  FOR candidate_rec IN SELECT candidate_id, first_name, last_name FROM public.candidates WHERE candidate_slug IS NULL LOOP
    UPDATE public.candidates
    SET candidate_slug = generate_candidate_slug(candidate_rec.first_name, candidate_rec.last_name, candidate_rec.candidate_id)
    WHERE candidate_id = candidate_rec.candidate_id;
  END LOOP;
END;
$$;

-- Create a trigger to automatically generate slugs for new candidates
CREATE OR REPLACE FUNCTION candidate_slug_trigger() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.candidate_slug IS NULL THEN
    NEW.candidate_slug := generate_candidate_slug(NEW.first_name, NEW.last_name, NEW.candidate_id);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER ensure_candidate_slug
BEFORE INSERT ON public.candidates
FOR EACH ROW
EXECUTE FUNCTION candidate_slug_trigger();

-- Add RLS policy to allow anyone to read candidates via slug (if we decide to expose this directly)
-- Note: We'll primarily use service role API access, but this policy could be useful
ALTER TABLE public.candidates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow public access to candidates via slug" 
ON public.candidates 
FOR SELECT 
USING (candidate_slug IS NOT NULL);

-- Create index on candidate_slug for faster lookups
CREATE INDEX idx_candidate_slug ON public.candidates(candidate_slug);