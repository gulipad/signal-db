-- Create a function to delete a candidate and all associated data
CREATE OR REPLACE FUNCTION public.delete_candidate(p_candidate_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    DELETE FROM public.candidate_activities
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate notes
    DELETE FROM public.candidate_notes
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate tags
    DELETE FROM public.candidate_tags
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate project buckets
    DELETE FROM public.candidate_project_buckets
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate summaries
    DELETE FROM public.candidate_summaries
    WHERE candidate_id = p_candidate_id;

    -- Delete candidate availability
    DELETE FROM public.candidate_availability
    WHERE candidate_id = p_candidate_id;

    -- Delete source data (must be deleted before sources)
    DELETE FROM public.source_data
    WHERE source_id IN (
        SELECT source_id 
        FROM public.sources 
        WHERE candidate_id = p_candidate_id
    );

    -- Delete candidate sources
    DELETE FROM public.sources
    WHERE candidate_id = p_candidate_id;

    -- Finally delete the candidate
    DELETE FROM public.candidates
    WHERE candidate_id = p_candidate_id;
END;
$$; 