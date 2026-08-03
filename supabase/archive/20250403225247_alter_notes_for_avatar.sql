    -- 1. Drop the incorrect foreign key if it was accidentally created from previous attempts
    --    (Run this first, it might fail if the constraint doesn't exist, which is fine)
    ALTER TABLE public.candidate_notes
    DROP CONSTRAINT IF EXISTS candidate_notes_created_by_fkey;

    -- 2. Change the created_by column type back to text
    ALTER TABLE public.candidate_notes
    ALTER COLUMN created_by TYPE TEXT;

    -- 3. Add the new column for the avatar URL
    ALTER TABLE public.candidate_notes
    ADD COLUMN creator_avatar_url TEXT NULL;

    -- 4. (Optional but Recommended) Add comments to clarify column purpose
    COMMENT ON COLUMN public.candidate_notes.created_by IS 'GitHub username of the user who created the note.';
    COMMENT ON COLUMN public.candidate_notes.creator_avatar_url IS 'URL of the GitHub avatar of the user who created the note.';