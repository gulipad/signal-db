ALTER TABLE candidate_activities 
DROP CONSTRAINT candidate_activities_activity_type_check;

ALTER TABLE candidate_activities 
ADD CONSTRAINT candidate_activities_activity_type_check 
CHECK (activity_type = ANY (ARRAY[
  'bucket_assignment'::text, 
  'availability_change'::text, 
  'source_update'::text, 
  'email_sent'::text,
  'candidate_startup_intro'::text
]));