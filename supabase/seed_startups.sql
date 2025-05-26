-- Seed data for startups, contacts, and programs
-- Run this after the main migration to populate with sample data

-- 1. Insert Programs
INSERT INTO programs (id, name, description) VALUES
  ('550e8400-e29b-41d4-a716-446655440001', 'Launchpad', 'Early-stage startup accelerator program focused on product-market fit'),
  ('550e8400-e29b-41d4-a716-446655440002', 'Fellowship', 'Intensive 12-week program for technical founders building deep tech solutions');

-- 2. Insert Startups
INSERT INTO startups (
  id, name, slug, hq_city, hq_country, remote_friendly, founded_year, 
  funding_stage, total_funding_usd, employees_min, employees_max,
  website_url, hiring_page_url, logo_url, tldr, long_description,
  industry_tags, tech_stack, visible, notes
) VALUES
  (
    '550e8400-e29b-41d4-a716-446655440010',
    'TechFlow AI',
    'techflow-ai',
    'San Francisco',
    'United States',
    true,
    2023,
    'seed',
    2500000.00,
    8,
    12,
    'https://techflow.ai',
    'https://techflow.ai/careers',
    'https://techflow.ai/logo.png',
    'AI-powered workflow automation for enterprise teams',
    'TechFlow AI revolutionizes how enterprise teams manage complex workflows by leveraging advanced machine learning algorithms to predict bottlenecks, automate routine tasks, and optimize resource allocation. Our platform integrates seamlessly with existing enterprise tools and provides real-time insights that help teams increase productivity by up to 40%.',
    ARRAY['artificial-intelligence', 'enterprise-software', 'automation'],
    ARRAY['Python', 'TensorFlow', 'React', 'PostgreSQL', 'Docker'],
    true,
    'Strong technical team, growing rapidly'
  ),
  (
    '550e8400-e29b-41d4-a716-446655440011',
    'GreenEnergy Solutions',
    'greenenergy-solutions',
    'Austin',
    'United States',
    false,
    2022,
    'series-a',
    8000000.00,
    15,
    25,
    'https://greenenergysolutions.com',
    'https://greenenergysolutions.com/jobs',
    'https://greenenergysolutions.com/assets/logo.svg',
    'Smart grid technology for renewable energy optimization',
    'GreenEnergy Solutions develops cutting-edge smart grid technology that maximizes the efficiency of renewable energy distribution. Our IoT-enabled devices and AI algorithms help utility companies reduce energy waste by up to 30% while seamlessly integrating solar, wind, and other renewable sources into existing power grids.',
    ARRAY['clean-tech', 'energy', 'iot', 'sustainability'],
    ARRAY['IoT', 'C++', 'Node.js', 'MongoDB', 'AWS'],
    true,
    'Excellent market traction, strong partnerships with utilities'
  ),
  (
    '550e8400-e29b-41d4-a716-446655440012',
    'HealthTrack Pro',
    'healthtrack-pro',
    'Boston',
    'United States',
    true,
    2024,
    'pre-seed',
    500000.00,
    3,
    6,
    'https://healthtrackpro.com',
    null,
    'https://healthtrackpro.com/logo.png',
    'Personalized health monitoring using wearable technology',
    'HealthTrack Pro combines advanced wearable sensors with machine learning to provide personalized health insights and early disease detection. Our platform continuously monitors vital signs, sleep patterns, and activity levels to identify health risks before they become serious problems.',
    ARRAY['healthcare', 'wearables', 'machine-learning', 'preventive-care'],
    ARRAY['Python', 'Flutter', 'TensorFlow', 'Firebase', 'Bluetooth'],
    true,
    'Early stage but promising technology, FDA approval in progress'
  ),
  (
    '550e8400-e29b-41d4-a716-446655440013',
    'EduVerse',
    'eduverse',
    'London',
    'United Kingdom',
    true,
    2023,
    'seed',
    1200000.00,
    6,
    10,
    'https://eduverse.io',
    'https://eduverse.io/careers',
    'https://eduverse.io/brand/logo.png',
    'Virtual reality platform for immersive educational experiences',
    'EduVerse creates immersive virtual reality educational experiences that make learning engaging and memorable. Our platform allows students to explore ancient Rome, conduct virtual chemistry experiments, or practice surgical procedures in a safe, controlled environment. We partner with schools and universities to enhance traditional curriculum with cutting-edge VR technology.',
    ARRAY['education', 'virtual-reality', 'edtech', 'immersive-learning'],
    ARRAY['Unity', 'C#', 'WebXR', 'React', 'Node.js', 'PostgreSQL'],
    true,
    'Strong product-market fit in education sector'
  );

-- 3. Insert Contacts
INSERT INTO contacts (
  id, startup_id, first_name, last_name, email, role, phone, linkedin_id, is_primary
) VALUES
  -- TechFlow AI contacts
  (
    '550e8400-e29b-41d4-a716-446655440020',
    '550e8400-e29b-41d4-a716-446655440010',
    'Sarah',
    'Chen',
    'sarah.chen@techflow.ai',
    'CEO & Co-founder',
    '+1-415-555-0101',
    'sarah-chen-techflow',
    true
  ),
  (
    '550e8400-e29b-41d4-a716-446655440021',
    '550e8400-e29b-41d4-a716-446655440010',
    'Marcus',
    'Rodriguez',
    'marcus.rodriguez@techflow.ai',
    'CTO & Co-founder',
    '+1-415-555-0102',
    'marcus-rodriguez-ai',
    false
  ),
  
  -- GreenEnergy Solutions contacts
  (
    '550e8400-e29b-41d4-a716-446655440022',
    '550e8400-e29b-41d4-a716-446655440011',
    'David',
    'Thompson',
    'david.thompson@greenenergysolutions.com',
    'Founder & CEO',
    '+1-512-555-0201',
    'david-thompson-green',
    true
  ),
  (
    '550e8400-e29b-41d4-a716-446655440023',
    '550e8400-e29b-41d4-a716-446655440011',
    'Emily',
    'Watson',
    'emily.watson@greenenergysolutions.com',
    'VP of Engineering',
    '+1-512-555-0202',
    'emily-watson-engineer',
    false
  ),
  
  -- HealthTrack Pro contacts
  (
    '550e8400-e29b-41d4-a716-446655440024',
    '550e8400-e29b-41d4-a716-446655440012',
    'Dr. Priya',
    'Patel',
    'priya.patel@healthtrackpro.com',
    'CEO & Medical Director',
    '+1-617-555-0301',
    'dr-priya-patel-health',
    true
  ),
  
  -- EduVerse contacts
  (
    '550e8400-e29b-41d4-a716-446655440025',
    '550e8400-e29b-41d4-a716-446655440013',
    'James',
    'Mitchell',
    'james.mitchell@eduverse.io',
    'Co-founder & CEO',
    '+44-20-7946-0401',
    'james-mitchell-eduverse',
    true
  ),
  (
    '550e8400-e29b-41d4-a716-446655440026',
    '550e8400-e29b-41d4-a716-446655440013',
    'Lisa',
    'Zhang',
    'lisa.zhang@eduverse.io',
    'Co-founder & Head of Product',
    '+44-20-7946-0402',
    'lisa-zhang-vr',
    false
  );

-- 4. Insert Startup-Program Relationships
INSERT INTO startup_programs (
  id, startup_id, program_id, joined_at, status
) VALUES
  -- TechFlow AI in Fellowship
  (
    '550e8400-e29b-41d4-a716-446655440030',
    '550e8400-e29b-41d4-a716-446655440010',
    '550e8400-e29b-41d4-a716-446655440002',
    '2023-09-01 00:00:00+00',
    'graduated'
  ),
  
  -- GreenEnergy Solutions in Launchpad
  (
    '550e8400-e29b-41d4-a716-446655440031',
    '550e8400-e29b-41d4-a716-446655440011',
    '550e8400-e29b-41d4-a716-446655440001',
    '2022-03-15 00:00:00+00',
    'graduated'
  ),
  
  -- HealthTrack Pro in Fellowship (current)
  (
    '550e8400-e29b-41d4-a716-446655440032',
    '550e8400-e29b-41d4-a716-446655440012',
    '550e8400-e29b-41d4-a716-446655440002',
    '2024-01-15 00:00:00+00',
    'active'
  ),
  
  -- EduVerse in Launchpad (current)
  (
    '550e8400-e29b-41d4-a716-446655440033',
    '550e8400-e29b-41d4-a716-446655440013',
    '550e8400-e29b-41d4-a716-446655440001',
    '2023-11-01 00:00:00+00',
    'active'
  );

-- 5. Update last_contacted_at for some startups to show recent activity
UPDATE startups 
SET last_contacted_at = now() - interval '3 days'
WHERE name = 'TechFlow AI';

UPDATE startups 
SET last_contacted_at = now() - interval '1 week'
WHERE name = 'HealthTrack Pro';

-- Display summary of inserted data
SELECT 
  'Data inserted successfully!' as message,
  (SELECT COUNT(*) FROM programs) as programs_count,
  (SELECT COUNT(*) FROM startups) as startups_count,
  (SELECT COUNT(*) FROM contacts) as contacts_count,
  (SELECT COUNT(*) FROM startup_programs) as program_relationships_count; 