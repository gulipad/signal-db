-- Rename tables to lowercase to match Supabase's default behavior
ALTER TABLE "Buckets" RENAME TO buckets;
ALTER TABLE "Candidates" RENAME TO candidates;
ALTER TABLE "Sources" RENAME TO sources;
ALTER TABLE "Source_Data" RENAME TO source_data;
ALTER TABLE "Candidate_Summaries" RENAME TO candidate_summaries;
ALTER TABLE "Candidate_Buckets" RENAME TO candidate_buckets;

-- Update sequence names
ALTER SEQUENCE IF EXISTS "Buckets_bucket_id_seq" RENAME TO buckets_bucket_id_seq;
ALTER SEQUENCE IF EXISTS "Candidates_candidate_id_seq" RENAME TO candidates_candidate_id_seq;
ALTER SEQUENCE IF EXISTS "Sources_source_id_seq" RENAME TO sources_source_id_seq;
ALTER SEQUENCE IF EXISTS "Source_Data_data_id_seq" RENAME TO source_data_data_id_seq;
ALTER SEQUENCE IF EXISTS "Candidate_Summaries_candidate_summary_id_seq" RENAME TO candidate_summaries_candidate_summary_id_seq;
ALTER SEQUENCE IF EXISTS "Candidate_Buckets_candidate_bucket_id_seq" RENAME TO candidate_buckets_candidate_bucket_id_seq; 