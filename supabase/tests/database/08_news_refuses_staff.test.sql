-- A News login never carries Signal access: News learns that a session is a
-- Signal staff one, and staff can't hold a News profile.
begin;
create extension if not exists pgtap with schema extensions;

create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.as_user(p_id uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  perform set_config('role', 'anon', true);
end $$;

create function tests.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.new_user(p_email text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '', now(),
          '{"provider": "github", "providers": ["github"]}', '{}', now(), now(),
          '', '', '', '', '', '', '', '');
  return v_id;
end $$;

create temp table u as
select 'staffer' as name, tests.new_user('t_staffer@exponential.test') as id
union all select 'reader', tests.new_user('t_reader@news.test');
grant select on u to anon, authenticated;
insert into public.staff (user_id, email) select id, 't_staffer@exponential.test' from u where name = 'staffer';
create function tests.uid(p_name text) returns uuid language sql stable as $$
  select id from u where name = p_name
$$;

select plan(7);

select is(pg_get_userbyid((select proowner from pg_proc where oid = 'news.is_signal_staff()'::regprocedure)),
          'postgres', 'is_signal_staff is owned by postgres, not news_owner');
select ok(not has_table_privilege('news_owner', 'public.staff', 'SELECT'), 'news_owner still can''t read public.staff');

select tests.as_user(tests.uid('staffer'));
select is(news.is_signal_staff(), true, 'a Signal staff session is recognised');
select throws_ok($$select news.claim_profile('t_staffer')$$, '42501', 'staff', 'and can''t claim a News profile');

select tests.as_user(tests.uid('reader'));
select is(news.is_signal_staff(), false, 'anyone else is not staff');
select lives_ok($$select news.claim_profile('t_reader')$$, 'and claims a profile as before');

select tests.as_anon();
select throws_ok($$select news.is_signal_staff()$$, '42501', null, 'anon can''t ask');

select tests.as_postgres();
select * from finish();
rollback;
