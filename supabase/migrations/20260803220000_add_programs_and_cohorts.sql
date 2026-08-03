-- ============================================================================
-- Programs and cohorts
-- ============================================================================
-- `programs` is currently (id, name, description, created_at) with no way to say
-- what KIND of program it is. That matters because the three programs are not
-- the same sort of object:
--
--   Launchpad, Fellowship  -- placement programs. People are admitted, then
--                             placed into a job at a startup.
--   Ateneo                 -- a community of VC-backed founders. Its members are
--                             founders, not candidates, and it has no placements.
--
-- Without a discriminator there is nothing stopping a placement being attributed
-- to Ateneo, which is meaningless.
--
-- COHORTS ARE A PRESENTATION LAYER, NOT AN OPERATIONAL GATE.
-- Admission is continuous -- people join throughout the year -- but the programs
-- are presented externally as cohorts. So:
--   * cohort date bounds are nullable and descriptive, never enforced;
--   * membership carries its OWN joined_at, because that is the real event;
--   * a member can be relabelled into a different cohort without rewriting when
--     they actually joined.
--
-- Ateneo is deliberately left alone: founder_forum_members and
-- founder_forum_applications are untouched by this migration. Ateneo is only
-- labelled kind='community' so that placements can be constrained away from it.
-- ============================================================================

-- 1. Extend programs --------------------------------------------------------

ALTER TABLE public.programs
  ADD COLUMN IF NOT EXISTS slug       text,
  ADD COLUMN IF NOT EXISTS kind       text NOT NULL DEFAULT 'placement',
  ADD COLUMN IF NOT EXISTS status     text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

COMMENT ON COLUMN public.programs.kind IS
  'placement = admits people and places them at startups (Launchpad, Fellowship). community = a network with no placements (Ateneo).';
COMMENT ON COLUMN public.programs.status IS
  'active = currently admitting or running. paused = temporarily not admitting. archived = historical.';

-- Backfill slugs from names before adding the unique index.
UPDATE public.programs
SET slug = trim(both '-' from regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g'))
WHERE slug IS NULL;

-- Ateneo is the one community program; everything else places people.
UPDATE public.programs SET kind = 'community' WHERE lower(name) = 'ateneo';

ALTER TABLE public.programs
  ADD CONSTRAINT programs_kind_check   CHECK (kind   IN ('placement', 'community')),
  ADD CONSTRAINT programs_status_check CHECK (status IN ('active', 'paused', 'archived'));

CREATE UNIQUE INDEX IF NOT EXISTS programs_slug_key ON public.programs (slug);

-- Referenced as the target of the composite foreign keys below, which is how
-- "a placement may only belong to a placement program" is enforced
-- declaratively rather than by trigger. Redundant with the primary key, but a
-- foreign key needs a unique constraint covering exactly its referenced columns.
ALTER TABLE public.programs
  ADD CONSTRAINT programs_id_kind_key UNIQUE (id, kind);

DROP TRIGGER IF EXISTS trg_programs_touch_updated_at ON public.programs;
CREATE TRIGGER trg_programs_touch_updated_at
  BEFORE UPDATE ON public.programs
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 2. Cohorts ----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.cohorts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  program_id  uuid NOT NULL REFERENCES public.programs(id) ON DELETE CASCADE,

  -- How the cohort is presented externally, e.g. 'Spring 2026'.
  name        text NOT NULL CHECK (length(trim(name)) > 0),
  slug        text NOT NULL CHECK (length(trim(slug)) > 0),
  description text,

  -- Descriptive only. Admission is continuous, so these are the dates the cohort
  -- is PRESENTED as covering -- they are never used to accept or reject a member.
  starts_on   date,
  ends_on     date,

  status      text NOT NULL DEFAULT 'active'
              CHECK (status IN ('upcoming', 'active', 'closed')),

  -- Where new members land when nobody picks a cohort explicitly. Because
  -- admission is continuous there is normally exactly one of these open per
  -- program at any time.
  is_default  boolean NOT NULL DEFAULT false,

  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT cohorts_program_slug_key UNIQUE (program_id, slug),
  CONSTRAINT cohorts_date_order CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on),

  -- Lets membership rows prove their cohort belongs to their program.
  CONSTRAINT cohorts_id_program_key UNIQUE (id, program_id)
);

COMMENT ON TABLE public.cohorts IS
  'External presentation grouping for a program. Admission is continuous; cohort dates are descriptive labels and are never enforced against membership.';
COMMENT ON COLUMN public.cohorts.is_default IS
  'Cohort new members are labelled with when none is specified. At most one per program.';

CREATE INDEX IF NOT EXISTS idx_cohorts_program ON public.cohorts (program_id);
CREATE INDEX IF NOT EXISTS idx_cohorts_status  ON public.cohorts (status);

-- At most one default cohort per program.
CREATE UNIQUE INDEX IF NOT EXISTS cohorts_one_default_per_program
  ON public.cohorts (program_id) WHERE is_default;

DROP TRIGGER IF EXISTS trg_cohorts_touch_updated_at ON public.cohorts;
CREATE TRIGGER trg_cohorts_touch_updated_at
  BEFORE UPDATE ON public.cohorts
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 3. Candidate membership in placement programs -----------------------------

CREATE TABLE IF NOT EXISTS public.candidate_program_memberships (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id uuid NOT NULL REFERENCES public.candidates(candidate_id) ON DELETE CASCADE,
  program_id   uuid NOT NULL,

  -- Nullable: a member always belongs to a program, but the cohort is only a
  -- label and may not have been assigned yet.
  cohort_id    uuid,

  -- The real admission event. Independent of any cohort's date bounds.
  joined_at    timestamptz NOT NULL DEFAULT now(),
  left_at      timestamptz,

  status       text NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'placed', 'alumni', 'withdrawn', 'rejected')),
  notes        text,

  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  -- Pinned so the composite foreign key below can assert the program is a
  -- placement program. Constant by construction: community programs do not
  -- admit candidates.
  program_kind text NOT NULL GENERATED ALWAYS AS ('placement') STORED,

  CONSTRAINT candidate_program_memberships_program_is_placement
    FOREIGN KEY (program_id, program_kind)
    REFERENCES public.programs(id, kind) ON DELETE CASCADE,

  -- The cohort must belong to the same program as the membership.
  CONSTRAINT candidate_program_memberships_cohort_matches_program
    FOREIGN KEY (cohort_id, program_id)
    REFERENCES public.cohorts(id, program_id) ON DELETE SET NULL,

  CONSTRAINT candidate_program_memberships_left_after_joined
    CHECK (left_at IS NULL OR left_at >= joined_at)
);

COMMENT ON TABLE public.candidate_program_memberships IS
  'Admission of a candidate to a placement program. joined_at is the real event; cohort_id is only a presentation label. Community programs (Ateneo) keep their own member tables and are rejected by the composite FK on program kind.';

CREATE INDEX IF NOT EXISTS idx_cpm_candidate ON public.candidate_program_memberships (candidate_id);
CREATE INDEX IF NOT EXISTS idx_cpm_program   ON public.candidate_program_memberships (program_id);
CREATE INDEX IF NOT EXISTS idx_cpm_cohort    ON public.candidate_program_memberships (cohort_id);
CREATE INDEX IF NOT EXISTS idx_cpm_joined_at ON public.candidate_program_memberships (joined_at);

-- A candidate may return to a program later, so repeated memberships are
-- allowed -- but only one may be open at a time.
CREATE UNIQUE INDEX IF NOT EXISTS cpm_one_active_per_candidate_program
  ON public.candidate_program_memberships (candidate_id, program_id)
  WHERE status = 'active';

-- Lets placements prove the candidate really was admitted to the program they
-- are attributed to (used by the placement lifecycle migration).
ALTER TABLE public.candidate_program_memberships
  ADD CONSTRAINT cpm_candidate_program_key UNIQUE (candidate_id, program_id);

DROP TRIGGER IF EXISTS trg_cpm_touch_updated_at ON public.candidate_program_memberships;
CREATE TRIGGER trg_cpm_touch_updated_at
  BEFORE UPDATE ON public.candidate_program_memberships
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- 4. Default-cohort assignment ----------------------------------------------
-- Because admission is continuous, a member who arrives without an explicit
-- cohort is labelled with the program's current default. Applied only when the
-- caller left cohort_id NULL, so an explicit choice always wins.

CREATE OR REPLACE FUNCTION public.apply_default_cohort()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.cohort_id IS NULL THEN
    SELECT c.id INTO NEW.cohort_id
    FROM public.cohorts c
    WHERE c.program_id = NEW.program_id AND c.is_default
    LIMIT 1;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cpm_apply_default_cohort ON public.candidate_program_memberships;
CREATE TRIGGER trg_cpm_apply_default_cohort
  BEFORE INSERT ON public.candidate_program_memberships
  FOR EACH ROW EXECUTE FUNCTION public.apply_default_cohort();

-- 5. Convenience view -------------------------------------------------------

CREATE OR REPLACE VIEW public.candidate_program_membership_details AS
SELECT m.id AS membership_id,
       m.candidate_id,
       c.first_name,
       c.last_name,
       c.email,
       m.program_id,
       p.name AS program_name,
       p.slug AS program_slug,
       m.cohort_id,
       co.name AS cohort_name,
       co.slug AS cohort_slug,
       m.joined_at,
       m.left_at,
       m.status
FROM public.candidate_program_memberships m
JOIN public.candidates c ON c.candidate_id = m.candidate_id
JOIN public.programs   p ON p.id = m.program_id
LEFT JOIN public.cohorts co ON co.id = m.cohort_id;

ALTER VIEW public.candidate_program_membership_details SET (security_invoker = on);

-- 6. RLS and grants ---------------------------------------------------------

ALTER TABLE public.cohorts                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.candidate_program_memberships ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_full_access" ON public.cohorts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "authenticated_full_access" ON public.candidate_program_memberships
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.cohorts                       TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.candidate_program_memberships TO authenticated, service_role;
GRANT SELECT ON public.candidate_program_membership_details TO authenticated, service_role;
