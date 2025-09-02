-- 01_create_candidate_startup_placements_table.sql
CREATE TABLE IF NOT EXISTS public.candidate_startup_placements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,
  startup_id uuid NOT NULL REFERENCES public.startups(id) ON DELETE CASCADE,
  role_title text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT candidate_startup_placements_unique UNIQUE (candidate_id, startup_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_csp_candidate ON public.candidate_startup_placements (candidate_id);
CREATE INDEX IF NOT EXISTS idx_csp_startup ON public.candidate_startup_placements (startup_id);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_csp_touch_updated_at ON public.candidate_startup_placements;

CREATE TRIGGER trg_csp_touch_updated_at
BEFORE UPDATE ON public.candidate_startup_placements
FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 02_row_level_security.sql
ALTER TABLE public.candidate_startup_placements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Enable all access for authenticated users and service role"
ON public.candidate_startup_placements
TO authenticated, service_role
USING (true)
WITH CHECK (true);