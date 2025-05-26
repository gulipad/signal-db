-- 0.  EXTENSIONS  ---------------------------------------------------------

-- Enable trigram extension for fuzzy text search
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 1.  STARTUPS  ------------------------------------------------------------
CREATE TABLE startups (
  id                 UUID            PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Core identity
  name               TEXT            NOT NULL,
  slug               TEXT            UNIQUE NOT NULL,

  -- Program-agnostic company facts
  hq_city            TEXT,
  hq_country         TEXT,
  remote_friendly    BOOLEAN         DEFAULT TRUE,
  founded_year       SMALLINT        CHECK (founded_year > 1800 AND founded_year <= EXTRACT(YEAR FROM CURRENT_DATE) + 1),
  funding_stage      TEXT            CHECK (funding_stage IN ('pre-seed', 'seed', 'series-a', 'series-b', 'series-c', 'series-d', 'growth', 'ipo', 'acquired')),
  total_funding_usd  NUMERIC(14,2)   CHECK (total_funding_usd >= 0),
  employees_min      SMALLINT        CHECK (employees_min >= 0),
  employees_max      SMALLINT        CHECK (employees_max >= employees_min),

  -- URLs & showcase copy
  website_url        TEXT,
  hiring_page_url    TEXT,
  logo_url           TEXT,
  tldr               TEXT            CHECK (LENGTH(tldr) <= 500),
  long_description   TEXT,
  industry_tags      TEXT[]          DEFAULT '{}',
  tech_stack         TEXT[]          DEFAULT '{}',
  visible            BOOLEAN         DEFAULT TRUE,

  -- Ops helpers
  last_contacted_at  TIMESTAMPTZ,
  notes              TEXT,

  -- Book-keeping
  created_at         TIMESTAMPTZ     DEFAULT now() NOT NULL,
  updated_at         TIMESTAMPTZ     DEFAULT now() NOT NULL
);

-- 2.  CONTACTS  ------------------------------------------------------------
CREATE TABLE contacts (
  id             UUID    PRIMARY KEY DEFAULT uuid_generate_v4(),
  startup_id     UUID    NOT NULL REFERENCES startups(id) ON DELETE CASCADE,
  first_name     TEXT    NOT NULL CHECK (LENGTH(TRIM(first_name)) > 0),
  last_name      TEXT    NOT NULL CHECK (LENGTH(TRIM(last_name)) > 0),
  email          TEXT    CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  role           TEXT,
  phone          TEXT,
  linkedin_id    TEXT,
  is_primary     BOOLEAN DEFAULT FALSE,

  created_at     TIMESTAMPTZ DEFAULT now() NOT NULL,
  updated_at     TIMESTAMPTZ DEFAULT now() NOT NULL,

  -- Ensure only one primary contact per startup
  CONSTRAINT unique_primary_contact EXCLUDE (startup_id WITH =) WHERE (is_primary = true)
);

-- 3.  PROGRAMS  ------------------------------------------------------------
CREATE TABLE programs (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name        TEXT NOT NULL UNIQUE CHECK (LENGTH(TRIM(name)) > 0),
  description TEXT,
  created_at  TIMESTAMPTZ DEFAULT now() NOT NULL
);

-- 4.  STARTUP_PROGRAMS (Many-to-Many relationship)  -----------------------
CREATE TABLE startup_programs (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  startup_id  UUID NOT NULL REFERENCES startups(id) ON DELETE CASCADE,
  program_id  UUID NOT NULL REFERENCES programs(id) ON DELETE CASCADE,
  joined_at   TIMESTAMPTZ DEFAULT now() NOT NULL,
  status      TEXT DEFAULT 'active' CHECK (status IN ('active', 'graduated', 'dropped', 'rejected')),
  
  -- Prevent duplicate program assignments
  UNIQUE(startup_id, program_id)
);

-- 5.  PERFORMANCE INDEXES  ------------------------------------------------

-- Startups indexes
CREATE INDEX idx_startups_slug ON startups(slug);
CREATE INDEX idx_startups_visible ON startups(visible) WHERE visible = true;
CREATE INDEX idx_startups_funding_stage ON startups(funding_stage) WHERE funding_stage IS NOT NULL;
CREATE INDEX idx_startups_hq_country ON startups(hq_country) WHERE hq_country IS NOT NULL;
CREATE INDEX idx_startups_founded_year ON startups(founded_year) WHERE founded_year IS NOT NULL;
CREATE INDEX idx_startups_last_contacted ON startups(last_contacted_at) WHERE last_contacted_at IS NOT NULL;
CREATE INDEX idx_startups_created_at ON startups(created_at);
CREATE INDEX idx_startups_name_trgm ON startups USING gin(name gin_trgm_ops);
CREATE INDEX idx_startups_industry_tags ON startups USING gin(industry_tags);
CREATE INDEX idx_startups_tech_stack ON startups USING gin(tech_stack);

-- Contacts indexes
CREATE INDEX idx_contacts_startup_id ON contacts(startup_id);
CREATE INDEX idx_contacts_email ON contacts(email) WHERE email IS NOT NULL;
CREATE INDEX idx_contacts_is_primary ON contacts(startup_id, is_primary) WHERE is_primary = true;
CREATE INDEX idx_contacts_name ON contacts(first_name, last_name);
CREATE INDEX idx_contacts_linkedin ON contacts(linkedin_id) WHERE linkedin_id IS NOT NULL;

-- Programs indexes
CREATE INDEX idx_programs_name ON programs(name);

-- Startup_programs indexes
CREATE INDEX idx_startup_programs_startup_id ON startup_programs(startup_id);
CREATE INDEX idx_startup_programs_program_id ON startup_programs(program_id);
CREATE INDEX idx_startup_programs_status ON startup_programs(status);
CREATE INDEX idx_startup_programs_joined_at ON startup_programs(joined_at);

-- 6.  TRIGGERS FOR UPDATED_AT  --------------------------------------------

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers for startups
CREATE TRIGGER update_startups_updated_at
  BEFORE UPDATE ON startups
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- Triggers for contacts
CREATE TRIGGER update_contacts_updated_at
  BEFORE UPDATE ON contacts
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- 7.  ROW LEVEL SECURITY  -------------------------------------------------

-- Enable RLS on all tables
ALTER TABLE startups ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE programs ENABLE ROW LEVEL SECURITY;
ALTER TABLE startup_programs ENABLE ROW LEVEL SECURITY;

-- Create policies for authenticated users and service role
CREATE POLICY "Enable all access for authenticated users and service role" 
ON startups
TO authenticated, service_role 
USING (true);

CREATE POLICY "Enable all access for authenticated users and service role" 
ON contacts
TO authenticated, service_role 
USING (true);

CREATE POLICY "Enable all access for authenticated users and service role" 
ON programs
TO authenticated, service_role 
USING (true);

CREATE POLICY "Enable all access for authenticated users and service role" 
ON startup_programs
TO authenticated, service_role 
USING (true);