-- First, get a list of all tables in the public schema
DO $$
DECLARE
    table_name_var text;
BEGIN
    -- Loop through all tables in the public schema
    FOR table_name_var IN 
        SELECT tablename FROM pg_tables WHERE schemaname = 'public'
    LOOP
        -- Enable Row Level Security on the table
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_name_var);
        
        -- Drop existing policies if they exist (optional, comment out if you want to keep existing policies)
        EXECUTE format('DROP POLICY IF EXISTS "Enable all access for authenticated users and service role" ON public.%I', table_name_var);
        
        -- Create the new policy
        EXECUTE format('CREATE POLICY "Enable all access for authenticated users and service role" ON public.%I TO authenticated, service_role USING (true)', table_name_var);
        
        RAISE NOTICE 'Enabled RLS and added policy to table: %', table_name_var;
    END LOOP;
END $$;