-- Add referrals column to public_profiles table
ALTER TABLE public.public_profiles 
ADD COLUMN referrals jsonb DEFAULT '[]'::jsonb;