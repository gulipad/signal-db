-- Enable Row Level Security on the candidate_availability table
ALTER TABLE public.candidate_availability ENABLE ROW LEVEL SECURITY;

-- Create policy that allows authenticated users and service role to access the table
CREATE POLICY "Enable all access for authenticated users and service role" 
ON public.candidate_availability
TO authenticated, service_role 
USING (true);
