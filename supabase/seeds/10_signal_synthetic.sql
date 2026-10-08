-- LOCAL ONLY. Made-up Signal data, one candidate per way of being (or not
-- being) accepted, so the News badge bridge has something to read. No
-- production data is ever copied here.
--
--   expected badge   candidate
--   fellowship       Ada       fellowship accepted (no acceptance template exists)
--   launchpad        Grace     opted in, "Welcome to Launchpad" email
--   community        Alan      "Welcome to the Exponential Community" email
--   community        Katherine joined the community before the email template existed
--   community        Dennis    invited to Launchpad (implies community), never opted in
--   none             Linus     accepted to the community, then archived
--   none             Margaret  rejected and archived
--   none             Barbara   joined the community, then left


-- Signal staff (GitHub in production; a password here).
with u (id, email, password, meta) as (values
  ('00000000-0000-4000-a000-000000000001'::uuid, 'staff@exponential.test', 'signal-staff-pw',
   '{"user_name": "staffer"}'::jsonb)
), users as (
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
         extensions.crypt(password, extensions.gen_salt('bf')), now(),
         '{"provider": "email", "providers": ["email"]}', meta, now(), now(),
         '', '', '', '', '', '', '', ''
  from u
  returning id, email
)
insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select id::text, id, jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
       'email', now(), now(), now()
from users;
insert into public.staff (user_id, email, display_name)
values ('00000000-0000-4000-a000-000000000001', 'staff@exponential.test', 'staffer');

insert into public.candidates (candidate_id, first_name, last_name, email) values
  ('10000000-0000-4000-a000-000000000001', 'Ada',       'Lovelace', 'ada@example.com'),
  ('10000000-0000-4000-a000-000000000002', 'Grace',     'Hopper',   'Grace@Example.com'),
  ('10000000-0000-4000-a000-000000000003', 'Alan',      'Turing',   'alan@example.com'),
  ('10000000-0000-4000-a000-000000000004', 'Katherine', 'Johnson',  'katherine@example.com'),
  ('10000000-0000-4000-a000-000000000005', 'Dennis',    'Ritchie',  'dennis@example.com'),
  ('10000000-0000-4000-a000-000000000006', 'Linus',     'Torvalds', 'linus@example.com'),
  ('10000000-0000-4000-a000-000000000007', 'Margaret',  'Hamilton', 'margaret@example.com'),
  ('10000000-0000-4000-a000-000000000008', 'Barbara',   'Liskov',   'barbara@example.com');

-- Tracks, through Signal's own RPC (a direct database session counts as staff).
select public.apply_member_actions('10000000-0000-4000-a000-000000000001',
  '[{"track": "fellowship", "stage": "invited"}, {"track": "fellowship", "stage": "interview_invited"},
    {"track": "fellowship", "stage": "interviewed"}, {"track": "fellowship", "stage": "startup_evaluation"},
    {"track": "fellowship", "stage": "accepted"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000002',
  '[{"track": "launchpad", "stage": "invited"}, {"track": "launchpad", "stage": "opted_in"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000003',
  '[{"track": "community", "stage": "joined"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000004',
  '[{"track": "community", "stage": "joined"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000005',
  '[{"track": "launchpad", "stage": "invited"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000006',
  '[{"track": "community", "stage": "joined"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000008',
  '[{"track": "community", "stage": "joined"}]');
select public.apply_member_actions('10000000-0000-4000-a000-000000000008',
  '[{"track": "community", "stage": "left"}]');

-- Emails Signal sent.
insert into public.candidate_activities (candidate_id, activity_type, metadata) values
  ('10000000-0000-4000-a000-000000000002', 'email_sent',
   '{"email_template": "launchpad_welcome", "email_subject": "Welcome to Launchpad, Grace!"}'),
  ('10000000-0000-4000-a000-000000000003', 'email_sent',
   '{"email_template": "community_invite", "email_subject": "Welcome to the Exponential Community, Alan!"}'),
  ('10000000-0000-4000-a000-000000000005', 'email_sent',
   '{"email_template": "launchpad_invite", "email_subject": "[Exponential] We''re happy to invite you to Launchpad"}'),
  ('10000000-0000-4000-a000-000000000006', 'email_sent',
   '{"email_template": "community_invite", "email_subject": "Welcome to the Exponential Community, Linus!"}'),
  ('10000000-0000-4000-a000-000000000007', 'email_sent',
   '{"email_template": "archive_generic", "email_subject": "[Exponential] Update regarding your application"}'),
  ('10000000-0000-4000-a000-000000000001', 'email_sent',
   '{"email_template": "fellowship_invite", "email_subject": "[Exponential Fellowship] Next steps"}');

select public.archive_candidate('10000000-0000-4000-a000-000000000006', 'demo: archived after joining');
select public.archive_candidate('10000000-0000-4000-a000-000000000007', 'demo: rejected');

-- Some private Signal data that must never be visible to News users.
insert into public.candidate_notes (candidate_id, content)
values ('10000000-0000-4000-a000-000000000001', 'Private staff note: strong systems background.');
