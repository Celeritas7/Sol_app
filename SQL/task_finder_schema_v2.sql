-- ============================================
-- TASK FINDER DATABASE SCHEMA v2
-- Hierarchical Tasks + Tag Inheritance + Focus System
-- ============================================

-- Drop existing tables (if any)
DROP TABLE IF EXISTS task_tags CASCADE;
DROP TABLE IF EXISTS tasks CASCADE;
DROP TABLE IF EXISTS tags CASCADE;

-- ============================================
-- 1. TAGS TABLE
-- ============================================
CREATE TABLE tags (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,  -- 'subject', 'category', 'mood', 'location', 'duration', 'priority', 'project', 'tool'
  color TEXT DEFAULT '#667eea',
  is_focused BOOLEAN DEFAULT FALSE,  -- For quick focus toggle
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(name, type)
);

-- ============================================
-- 2. TASKS TABLE (with self-referencing parent_id)
-- ============================================
CREATE TABLE tasks (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  parent_id UUID REFERENCES tasks(id) ON DELETE CASCADE,  -- NULL for root tasks
  status TEXT DEFAULT 'not_started',  -- 'not_started', 'in_progress', 'done', 'blocked'
  notes TEXT,
  links TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- 3. TASK_TAGS JUNCTION TABLE
-- ============================================
CREATE TABLE task_tags (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  task_id UUID REFERENCES tasks(id) ON DELETE CASCADE,
  tag_id UUID REFERENCES tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(task_id, tag_id)
);

-- ============================================
-- INDEXES FOR PERFORMANCE
-- ============================================
CREATE INDEX idx_tags_type ON tags(type);
CREATE INDEX idx_tags_focused ON tags(is_focused);
CREATE INDEX idx_tasks_parent ON tasks(parent_id);
CREATE INDEX idx_task_tags_task ON task_tags(task_id);
CREATE INDEX idx_task_tags_tag ON task_tags(tag_id);

-- ============================================
-- AUTO-UPDATE TRIGGER
-- ============================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tasks_updated_at
  BEFORE UPDATE ON tasks
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ============================================
-- FUNCTION: Get all ancestor IDs of a task
-- ============================================
CREATE OR REPLACE FUNCTION get_ancestor_ids(task_uuid UUID)
RETURNS TABLE(ancestor_id UUID) AS $$
WITH RECURSIVE ancestors AS (
  SELECT parent_id FROM tasks WHERE id = task_uuid AND parent_id IS NOT NULL
  UNION ALL
  SELECT t.parent_id FROM tasks t
  JOIN ancestors a ON t.id = a.parent_id
  WHERE t.parent_id IS NOT NULL
)
SELECT parent_id FROM ancestors;
$$ LANGUAGE SQL;

-- ============================================
-- FUNCTION: Get all inherited tags for a task (own + ancestors')
-- ============================================
CREATE OR REPLACE FUNCTION get_inherited_tags(task_uuid UUID)
RETURNS TABLE(tag_id UUID, tag_name TEXT, tag_type TEXT, tag_color TEXT, is_own BOOLEAN) AS $$
  -- Own tags
  SELECT t.id, t.name, t.type, t.color, TRUE as is_own
  FROM tags t
  JOIN task_tags tt ON t.id = tt.tag_id
  WHERE tt.task_id = task_uuid
  
  UNION
  
  -- Inherited tags from ancestors
  SELECT DISTINCT t.id, t.name, t.type, t.color, FALSE as is_own
  FROM tags t
  JOIN task_tags tt ON t.id = tt.tag_id
  JOIN get_ancestor_ids(task_uuid) a ON tt.task_id = a.ancestor_id
  WHERE t.id NOT IN (
    SELECT tag_id FROM task_tags WHERE task_id = task_uuid
  );
$$ LANGUAGE SQL;

-- ============================================
-- FUNCTION: Get all descendant IDs of a task
-- ============================================
CREATE OR REPLACE FUNCTION get_descendant_ids(task_uuid UUID)
RETURNS TABLE(descendant_id UUID) AS $$
WITH RECURSIVE descendants AS (
  SELECT id FROM tasks WHERE parent_id = task_uuid
  UNION ALL
  SELECT t.id FROM tasks t
  JOIN descendants d ON t.parent_id = d.id
)
SELECT id FROM descendants;
$$ LANGUAGE SQL;

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================
ALTER TABLE tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_tags ENABLE ROW LEVEL SECURITY;

-- Public access policies
CREATE POLICY "tags_select" ON tags FOR SELECT USING (true);
CREATE POLICY "tags_insert" ON tags FOR INSERT WITH CHECK (true);
CREATE POLICY "tags_update" ON tags FOR UPDATE USING (true) WITH CHECK (true);
CREATE POLICY "tags_delete" ON tags FOR DELETE USING (true);

CREATE POLICY "tasks_select" ON tasks FOR SELECT USING (true);
CREATE POLICY "tasks_insert" ON tasks FOR INSERT WITH CHECK (true);
CREATE POLICY "tasks_update" ON tasks FOR UPDATE USING (true) WITH CHECK (true);
CREATE POLICY "tasks_delete" ON tasks FOR DELETE USING (true);

CREATE POLICY "task_tags_select" ON task_tags FOR SELECT USING (true);
CREATE POLICY "task_tags_insert" ON task_tags FOR INSERT WITH CHECK (true);
CREATE POLICY "task_tags_update" ON task_tags FOR UPDATE USING (true) WITH CHECK (true);
CREATE POLICY "task_tags_delete" ON task_tags FOR DELETE USING (true);

-- ============================================
-- INSERT SAMPLE TAGS
-- ============================================
INSERT INTO tags (name, type, color) VALUES
  -- Subjects
  ('AI', 'subject', '#e74c3c'),
  ('Japanese', 'subject', '#3498db'),
  ('SQL', 'subject', '#2ecc71'),
  ('Burmese', 'subject', '#9b59b6'),
  ('Language', 'subject', '#1abc9c'),
  
  -- Categories
  ('Coding', 'category', '#f39c12'),
  ('Documentation', 'category', '#8e44ad'),
  ('Paper study', 'category', '#2980b9'),
  ('App generation', 'category', '#27ae60'),
  ('Quick study', 'category', '#e67e22'),
  
  -- Moods
  ('Energetic', 'mood', '#2ecc71'),
  ('Bit tired', 'mood', '#f1c40f'),
  ('Tired', 'mood', '#e67e22'),
  ('Sleepy', 'mood', '#95a5a6'),
  
  -- Locations
  ('Train', 'location', '#3498db'),
  ('Room', 'location', '#9b59b6'),
  ('Company', 'location', '#34495e'),
  ('Share house', 'location', '#16a085'),
  ('Park', 'location', '#27ae60'),
  ('Cafe', 'location', '#e74c3c'),
  
  -- Durations
  ('5min', 'duration', '#1abc9c'),
  ('15min', 'duration', '#3498db'),
  ('30min', 'duration', '#9b59b6'),
  ('1hour', 'duration', '#e74c3c'),
  
  -- Priorities
  ('High', 'priority', '#e74c3c'),
  ('Medium', 'priority', '#f39c12'),
  ('Low', 'priority', '#95a5a6');

-- ============================================
-- IMPORT CSV DATA
-- ============================================

-- Helper function to get or create task by name and parent
-- We'll do this step by step with direct inserts

-- Level 0: ROOT
INSERT INTO tasks (name, parent_id, status, notes, links) VALUES
  ('Life goals', NULL, 'not_started', NULL, NULL);

-- Level 1: Direct children of Life goals
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Language expert', id, 'in_progress', NULL, NULL FROM tasks WHERE name = 'Life goals';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'AI expert', id, 'done', NULL, NULL FROM tasks WHERE name = 'Life goals';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Job change', id, 'done', NULL, NULL FROM tasks WHERE name = 'Life goals';

-- Level 2: Children of Language expert
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Japanese self study', id, 'done', NULL, NULL FROM tasks WHERE name = 'Language expert';

-- Level 2: Children of AI expert
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Homework given by Amy Bhai', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'AI expert';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Document generation from the data given by Amy bhai', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'AI expert';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Mechanical revision', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'AI expert';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Mechanical practice problems', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'AI expert';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Statistics', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'AI expert';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Colab links', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'AI expert';

-- Level 2: Children of Job change
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Interview Q and A review with AI', id, 'done', NULL, NULL FROM tasks WHERE name = 'Job change';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Mechanical practice problems (Job)', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Job change';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Generate the assembly tree app', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Job change';

-- Level 3: Children of Japanese self study
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Japanese study app', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Japanese self study';

-- Level 3: Children of Interview Q and A review with AI
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Feed the data to AI version wise', id, 'done', NULL, NULL FROM tasks WHERE name = 'Interview Q and A review with AI';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Problems covering the different concepts of AI', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Interview Q and A review with AI';

-- Level 3: Children of Mechanical practice problems (under AI expert)
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Generate the SFD BMD app', id, 'blocked', NULL, NULL FROM tasks WHERE name = 'Mechanical practice problems' AND parent_id = (SELECT id FROM tasks WHERE name = 'AI expert');

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'TOM book concepts', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Mechanical practice problems' AND parent_id = (SELECT id FROM tasks WHERE name = 'AI expert');

-- Level 3: Children of Statistics
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Generate the MS word files for hand calculations', id, 'in_progress', NULL, NULL FROM tasks WHERE name = 'Statistics';

-- Level 3: Children of Colab links
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Python study', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Colab links';

-- Level 4: Children of Japanese study app
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Design the UI to match with excel', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Japanese study app';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'The story page linking in interactive way', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Japanese study app';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT '10 min quick study', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Japanese study app';

-- Level 4: Children of Generate the SFD BMD app
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Add different cases for the SFD BMD', id, 'not_started', NULL, NULL FROM tasks WHERE name = 'Generate the SFD BMD app';

-- Level 4: Children of Generate the MS word files
INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'Mean-median, mode', id, 'in_progress', NULL, NULL FROM tasks WHERE name = 'Generate the MS word files for hand calculations';

INSERT INTO tasks (name, parent_id, status, notes, links)
SELECT 'ANOVA 3 types', id, 'in_progress', NULL, NULL FROM tasks WHERE name = 'Generate the MS word files for hand calculations';

-- ============================================
-- ASSIGN TAGS TO TASKS
-- ============================================

-- AI expert -> AI tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'AI expert' AND g.name = 'AI' AND g.type = 'subject';

-- Language expert -> Language tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Language expert' AND g.name = 'Language' AND g.type = 'subject';

-- Japanese self study -> Japanese tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Japanese self study' AND g.name = 'Japanese' AND g.type = 'subject';

-- Homework given by Amy Bhai -> Coding, AI tags
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Homework given by Amy Bhai' AND g.name = 'Coding' AND g.type = 'category';

-- Document generation -> Documentation tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Document generation from the data given by Amy bhai' AND g.name = 'Documentation' AND g.type = 'category';

-- Mechanical revision -> Documentation tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Mechanical revision' AND g.name = 'Documentation' AND g.type = 'category';

-- Mechanical practice problems -> Paper study tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Mechanical practice problems' AND g.name = 'Paper study' AND g.type = 'category';

-- Statistics -> Paper study, Coding tags
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Statistics' AND g.name = 'Paper study' AND g.type = 'category';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Statistics' AND g.name = 'Coding' AND g.type = 'category';

-- Colab links -> Coding tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Colab links' AND g.name = 'Coding' AND g.type = 'category';

-- Interview Q and A -> Documentation tag
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Interview Q and A review with AI' AND g.name = 'Documentation' AND g.type = 'category';

-- Japanese study app children -> App generation, locations
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Design the UI to match with excel' AND g.name = 'App generation' AND g.type = 'category';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Design the UI to match with excel' AND g.name = 'Room' AND g.type = 'location';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Design the UI to match with excel' AND g.name = 'Share house' AND g.type = 'location';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'The story page linking in interactive way' AND g.name = 'App generation' AND g.type = 'category';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'The story page linking in interactive way' AND g.name = 'Room' AND g.type = 'location';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'The story page linking in interactive way' AND g.name = 'Share house' AND g.type = 'location';

-- 10 min quick study -> Quick study, Energetic, Train, Company
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = '10 min quick study' AND g.name = 'Quick study' AND g.type = 'category';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = '10 min quick study' AND g.name = 'Energetic' AND g.type = 'mood';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = '10 min quick study' AND g.name = 'Train' AND g.type = 'location';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = '10 min quick study' AND g.name = 'Company' AND g.type = 'location';

-- Feed the data to AI -> Documentation
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Feed the data to AI version wise' AND g.name = 'Documentation' AND g.type = 'category';

-- Problems covering -> Documentation
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Problems covering the different concepts of AI' AND g.name = 'Documentation' AND g.type = 'category';

-- Generate SFD BMD app -> App generation
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Generate the SFD BMD app' AND g.name = 'App generation' AND g.type = 'category';

-- TOM book concepts -> App generation
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'TOM book concepts' AND g.name = 'App generation' AND g.type = 'category';

-- Generate MS word files -> Paper study
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Generate the MS word files for hand calculations' AND g.name = 'Paper study' AND g.type = 'category';

-- Mean-median, mode -> Paper study, Room
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Mean-median, mode' AND g.name = 'Paper study' AND g.type = 'category';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'Mean-median, mode' AND g.name = 'Room' AND g.type = 'location';

-- ANOVA 3 types -> Paper study, Room
INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'ANOVA 3 types' AND g.name = 'Paper study' AND g.type = 'category';

INSERT INTO task_tags (task_id, tag_id)
SELECT t.id, g.id FROM tasks t, tags g 
WHERE t.name = 'ANOVA 3 types' AND g.name = 'Room' AND g.type = 'location';

-- ============================================
-- VERIFICATION QUERY
-- ============================================
-- Run this to verify the data was imported correctly:
-- SELECT t.name, t.status, p.name as parent_name 
-- FROM tasks t 
-- LEFT JOIN tasks p ON t.parent_id = p.id 
-- ORDER BY t.created_at;
