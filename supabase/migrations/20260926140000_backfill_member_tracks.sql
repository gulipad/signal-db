-- ============================================================================
-- BACKFILL MEMBER TRACKS
--
-- Rebuilds track history from what the old system recorded:
--
--   1. Funnel moves (candidate_bucket_transitions), mapped bucket -> stage.
--      Each (candidate, funnel) assignment becomes one spell, so a candidate
--      rejected in Cohort #01 and reconsidered in Cohort #02 has two
--      Fellowship spells.
--
--        Cohort #0x  Interview 1         -> fellowship invited
--                    Interview 2         -> fellowship invited + interviewed + interview_invited
--                                           (first interview done, second one invited)
--                    Startup evaluation  -> fellowship startup_evaluation
--                    Referrals           -> fellowship startup_evaluation
--                    Fellow              -> fellowship accepted
--                    Rejected            -> fellowship rejected (closes the spell)
--                    Review later        -> spell opened, no stage yet
--        Launchpad   Invited             -> launchpad invited
--                    Interview           -> launchpad interview_invited
--                    Displayed           -> launchpad accepted
--
--   2. Emails sent (candidate_activities.email_sent), matched on subject:
--        "Welcome to the Exponential Community"  -> community joined
--        "...Update to your application & more"   -> community joined
--           (the Rejection + Community Invite template)
--        "You're invited to Launchpad" /
--        "We're happy to invite you to Launchpad" -> launchpad invited
--        "[Exponential] Next steps"               -> launchpad interview_invited
--        "Welcome to Launchpad"                   -> launchpad opted_in
--
--   3. candidates.launchpad_optin without a welcome email -> launchpad opted_in
--      at the candidate's updated_at (flagged inferred in metadata).
--
--   4. The current rule applied to history: every Launchpad or Fellowship
--      invite also joins the community (both invite emails carried the
--      WhatsApp link).
--
-- Also recovers inbox_events.requested_programs (see the end).
-- Nobody is archived here; that is a separate decision.
-- Rows are marked source = 'backfill'. Re-running is a no-op.
-- ============================================================================

BEGIN;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.candidate_track_spells WHERE source = 'backfill') THEN
    RAISE NOTICE 'member tracks already backfilled; skipping';
    RETURN;
  END IF;

  CREATE TEMP TABLE bf_events (
    candidate_id uuid NOT NULL,
    track        text NOT NULL,
    spell_key    text NOT NULL,        -- groups events into one spell
    stage        text,                 -- NULL = opens the spell without a stage
    occurred_at  timestamptz NOT NULL,
    ord          int NOT NULL,         -- order within the same instant
    metadata     jsonb NOT NULL
  ) ON COMMIT DROP;

  -- 1. Funnel moves ---------------------------------------------------------
  WITH map(project_name, bucket_name, track, stages) AS (VALUES
    ('Cohort #01',    'Rejected',           'fellowship', ARRAY['rejected']),
    ('Cohort #02',    'Review later',       'fellowship', ARRAY[NULL]::text[]),
    ('Cohort #02',    'Interview 1',        'fellowship', ARRAY['invited']),
    ('Cohort #02',    'Interview 2',        'fellowship', ARRAY['invited', 'interviewed', 'interview_invited']),
    ('Cohort #02',    'Startup evaluation', 'fellowship', ARRAY['startup_evaluation']),
    ('Cohort #02',    'Referrals',          'fellowship', ARRAY['startup_evaluation']),
    ('Cohort #02',    'Fellow',             'fellowship', ARRAY['accepted']),
    ('Cohort #02',    'Rejected',           'fellowship', ARRAY['rejected']),
    ('Launchpad ''25','Invited',            'launchpad',  ARRAY['invited']),
    ('Launchpad ''25','Interview',          'launchpad',  ARRAY['interview_invited']),
    ('Launchpad ''25','Displayed',          'launchpad',  ARRAY['accepted'])
  )
  INSERT INTO bf_events (candidate_id, track, spell_key, stage, occurred_at, ord, metadata)
  SELECT t.candidate_id,
         m.track,
         CASE m.track WHEN 'fellowship' THEN 'funnel:' || t.project_id ELSE 'launchpad' END,
         st.stage,
         t.occurred_at,
         10 + st.i,
         jsonb_build_object('transition_id', t.id, 'bucket', m.bucket_name, 'funnel', m.project_name)
  FROM public.candidate_bucket_transitions t
  JOIN public.project_buckets b ON b.bucket_id = t.to_bucket_id
  JOIN public.projects p        ON p.project_id = b.project_id
  JOIN map m ON m.project_name = p.name AND m.bucket_name = b.name
  CROSS JOIN LATERAL unnest(m.stages) WITH ORDINALITY AS st(stage, i);

  -- 2. Emails ---------------------------------------------------------------
  INSERT INTO bf_events (candidate_id, track, spell_key, stage, occurred_at, ord, metadata)
  SELECT a.candidate_id, x.track, x.track, x.stage, a.activity_timestamp, x.ord,
         jsonb_build_object('activity_id', a.activity_id, 'email_subject', a.metadata->>'email_subject')
  FROM public.candidate_activities a
  CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
      ('community', 'joined',            1, (a.metadata->>'email_subject') ILIKE 'Welcome to the Exponential Community%'),
      ('community', 'joined',            1, (a.metadata->>'email_subject') ILIKE '%Update to your application & more%'),
      ('launchpad', 'invited',           2, (a.metadata->>'email_subject') ILIKE '%You''re invited to Launchpad%'),
      ('launchpad', 'invited',           2, (a.metadata->>'email_subject') ILIKE '%happy to invite you to Launchpad%'),
      ('launchpad', 'interview_invited', 4, (a.metadata->>'email_subject') = '[Exponential] Next steps'),
      ('launchpad', 'opted_in',          3, (a.metadata->>'email_subject') ILIKE 'Welcome to Launchpad%')
    ) AS v(track, stage, ord, hit)
    WHERE v.hit
  ) x
  WHERE a.activity_type = 'email_sent' AND a.candidate_id IS NOT NULL;

  -- 3. Opt-in flag without a welcome email -----------------------------------
  INSERT INTO bf_events (candidate_id, track, spell_key, stage, occurred_at, ord, metadata)
  SELECT c.candidate_id, 'launchpad', 'launchpad', 'opted_in', COALESCE(c.updated_at, c.created_at), 3,
         jsonb_build_object('inferred', 'launchpad_optin flag')
  FROM public.candidates c
  WHERE c.launchpad_optin
    AND NOT EXISTS (
      SELECT 1 FROM bf_events e
      WHERE e.candidate_id = c.candidate_id AND e.track = 'launchpad' AND e.stage = 'opted_in'
    );

  -- 4. Invites imply community ---------------------------------------------
  INSERT INTO bf_events (candidate_id, track, spell_key, stage, occurred_at, ord, metadata)
  SELECT e.candidate_id, 'community', 'community', 'joined', min(e.occurred_at), 0,
         jsonb_build_object('inferred', 'invited to a program')
  FROM bf_events e
  WHERE e.stage IN ('invited', 'opted_in')
  GROUP BY e.candidate_id;

  -- One-off stages are recorded once per spell (earliest); community is a
  -- single joined event. Repeatable stages keep every occurrence.
  DELETE FROM bf_events d
  USING (
    SELECT ctid, row_number() OVER (
      PARTITION BY candidate_id, spell_key, stage ORDER BY occurred_at, ord
    ) AS rn
    FROM bf_events
    WHERE stage IN ('joined', 'invited', 'opted_in', 'accepted')
  ) r
  WHERE d.ctid = r.ctid AND r.rn > 1;

  -- Spells -------------------------------------------------------------------
  CREATE TEMP TABLE bf_spells ON COMMIT DROP AS
  SELECT gen_random_uuid() AS id,
         candidate_id, track, spell_key,
         min(occurred_at) AS opened_at,
         -- a spell closes on its last event if that event is a rejection
         (array_agg(stage ORDER BY occurred_at DESC, ord DESC))[1] AS last_stage,
         max(occurred_at) AS last_at
  FROM bf_events
  GROUP BY candidate_id, track, spell_key;

  -- Someone reconsidered while an earlier Fellowship spell was still open
  -- (e.g. never moved out of Cohort #01): close the earlier one as removed
  -- when the next one opens, so at most one spell per track stays open.
  INSERT INTO public.candidate_track_spells (id, candidate_id, track, opened_at, closed_at, close_reason, source)
  SELECT s.id, s.candidate_id, s.track, s.opened_at,
         CASE
           WHEN s.last_stage = 'rejected' THEN s.last_at
           WHEN nxt.opened_at IS NOT NULL THEN greatest(nxt.opened_at, s.opened_at)
         END,
         CASE
           WHEN s.last_stage = 'rejected' THEN 'rejected'
           WHEN nxt.opened_at IS NOT NULL THEN 'removed'
         END,
         'backfill'
  FROM bf_spells s
  LEFT JOIN LATERAL (
    SELECT n.opened_at FROM bf_spells n
    WHERE n.candidate_id = s.candidate_id AND n.track = s.track
      AND n.id <> s.id AND n.opened_at > s.opened_at
    ORDER BY n.opened_at LIMIT 1
  ) nxt ON true
  -- archived candidates cannot hold open spells; none exist yet at backfill time
  ;

  INSERT INTO public.candidate_track_events
    (spell_id, candidate_id, track, stage, occurred_at, metadata, source)
  SELECT s.id, e.candidate_id, e.track, e.stage, e.occurred_at, e.metadata, 'backfill'
  FROM bf_events e
  JOIN bf_spells s USING (candidate_id, track, spell_key)
  WHERE e.stage IS NOT NULL
  ORDER BY e.occurred_at, e.ord;   -- seq follows this order for same-instant ties
END;
$$;
-- The website never wrote requested_programs; recover it from the program
-- preferences stored with each fellowship application (nearest application
-- source by time for the same candidate).
UPDATE public.inbox_events e
SET requested_programs = sub.programs
FROM (
  SELECT DISTINCT ON (e2.event_id)
         e2.event_id,
         ARRAY(
           SELECT p FROM unnest(ARRAY['fellowship', 'launchpad']) AS p
           WHERE (sd.json_summary->'program_preferences'->>p)::boolean
         ) AS programs
  FROM public.inbox_events e2
  JOIN public.sources s
    ON s.candidate_id = e2.candidate_id
   AND s.source_type = 'application'
   AND s.source_identifier ILIKE '%Fellowship%'
  JOIN public.source_data sd ON sd.source_id = s.source_id
  WHERE e2.event_type = 'fellowship_application'
    AND e2.requested_programs = '{}'
    AND sd.json_summary ? 'program_preferences'
  ORDER BY e2.event_id, abs(extract(epoch FROM s.created_at - e2.created_at))
) sub
WHERE e.event_id = sub.event_id AND cardinality(sub.programs) > 0;
COMMIT;
