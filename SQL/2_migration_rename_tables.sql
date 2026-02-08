-- ============================================
-- MIGRATION: Rename tables with mind_map_app_ prefix
-- + Add TaskBrain v3 enhancements
-- ============================================
-- Run this in Supabase SQL Editor
-- Order matters: drop constraints → rename → recreate constraints

-- ============================================
-- STEP 1: Drop dependent objects (triggers, indexes, policies, functions)
-- ============================================

-- Drop trigger
DROP TRIGGER IF EXISTS tasks_updated_at ON tasks;

-- Drop indexes
DROP INDEX IF EXISTS idx_tags_type;
DROP INDEX IF EXISTS idx_tags_focused;
DROP INDEX IF EXISTS idx_task_tags_tag;
DROP INDEX IF EXISTS idx_task_tags_task;
DROP INDEX IF EXISTS idx_tasks_parent;

-- Drop RLS policies (if any exist)
DROP POLICY IF EXISTS "tags_select" ON tags;
DROP POLICY IF EXISTS "tags_insert" ON tags;
DROP POLICY IF EXISTS "tags_update" ON tags;
DROP POLICY IF EXISTS "tags_delete" ON tags;
DROP POLICY IF EXISTS "tasks_select" ON tasks;
DROP POLICY IF EXISTS "tasks_insert" ON tasks;
DROP POLICY IF EXISTS "tasks_update" ON tasks;
DROP POLICY IF EXISTS "tasks_delete" ON tasks;
DROP POLICY IF EXISTS "task_tags_select" ON task_tags;
DROP POLICY IF EXISTS "task_tags_insert" ON task_tags;
DROP POLICY IF EXISTS "task_tags_update" ON task_tags;
DROP POLICY IF EXISTS "task_tags_delete" ON task_tags;
DROP POLICY IF EXISTS "tags_all" ON tags;
DROP POLICY IF EXISTS "tasks_all" ON tasks;
DROP POLICY IF EXISTS "task_tags_all" ON task_tags;

-- Drop existing functions that reference old table names
DROP FUNCTION IF EXISTS get_ancestor_ids(UUID);
DROP FUNCTION IF EXISTS get_inherited_tags(UUID);
DROP FUNCTION IF EXISTS get_descendant_ids(UUID);

-- ============================================
-- STEP 2: Rename tables
-- ============================================
ALTER TABLE task_tags RENAME TO mind_map_app_task_tags;
ALTER TABLE tasks RENAME TO mind_map_app_tasks;
ALTER TABLE tags RENAME TO mind_map_app_tags;

-- ============================================
-- STEP 3: Rename constraints (Supabase auto-renames some, but let's be explicit)
-- ============================================
-- Primary keys
ALTER TABLE mind_map_app_tags RENAME CONSTRAINT tags_pkey TO mind_map_app_tags_pkey;
ALTER TABLE mind_map_app_tags RENAME CONSTRAINT tags_name_type_key TO mind_map_app_tags_name_type_key;

ALTER TABLE mind_map_app_tasks RENAME CONSTRAINT tasks_pkey TO mind_map_app_tasks_pkey;
ALTER TABLE mind_map_app_tasks RENAME CONSTRAINT tasks_parent_id_fkey TO mind_map_app_tasks_parent_id_fkey;

ALTER TABLE mind_map_app_task_tags RENAME CONSTRAINT task_tags_pkey TO mind_map_app_task_tags_pkey;
ALTER TABLE mind_map_app_task_tags RENAME CONSTRAINT task_tags_task_id_tag_id_key TO mind_map_app_task_tags_task_id_tag_id_key;
ALTER TABLE mind_map_app_task_tags RENAME CONSTRAINT task_tags_tag_id_fkey TO mind_map_app_task_tags_tag_id_fkey;
ALTER TABLE mind_map_app_task_tags RENAME CONSTRAINT task_tags_task_id_fkey TO mind_map_app_task_tags_task_id_fkey;

-- ============================================
-- STEP 4: Recreate indexes with new names
-- ============================================
CREATE INDEX idx_mind_map_app_tags_type ON mind_map_app_tags USING btree (type);
CREATE INDEX idx_mind_map_app_tags_focused ON mind_map_app_tags USING btree (is_focused);
CREATE INDEX idx_mind_map_app_tasks_parent ON mind_map_app_tasks USING btree (parent_id);
CREATE INDEX idx_mind_map_app_task_tags_task ON mind_map_app_task_tags USING btree (task_id);
CREATE INDEX idx_mind_map_app_task_tags_tag ON mind_map_app_task_tags USING btree (tag_id);

-- ============================================
-- STEP 5: Recreate trigger on renamed table
-- ============================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER mind_map_app_tasks_updated_at
  BEFORE UPDATE ON mind_map_app_tasks
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();

-- ============================================
-- STEP 6: Recreate RLS policies on renamed tables
-- ============================================
ALTER TABLE mind_map_app_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE mind_map_app_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE mind_map_app_task_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY "mind_map_app_tags_all" ON mind_map_app_tags FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "mind_map_app_tasks_all" ON mind_map_app_tasks FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "mind_map_app_task_tags_all" ON mind_map_app_task_tags FOR ALL USING (true) WITH CHECK (true);

-- ============================================
-- STEP 7: Recreate functions with new table names
-- ============================================
CREATE OR REPLACE FUNCTION mind_map_app_get_ancestor_ids(task_uuid UUID)
RETURNS TABLE(ancestor_id UUID) AS $$
WITH RECURSIVE ancestors AS (
  SELECT parent_id FROM mind_map_app_tasks WHERE id = task_uuid AND parent_id IS NOT NULL
  UNION ALL
  SELECT t.parent_id FROM mind_map_app_tasks t
  JOIN ancestors a ON t.id = a.parent_id
  WHERE t.parent_id IS NOT NULL
)
SELECT parent_id FROM ancestors;
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION mind_map_app_get_inherited_tags(task_uuid UUID)
RETURNS TABLE(tag_id UUID, tag_name TEXT, tag_type TEXT, tag_color TEXT, is_own BOOLEAN) AS $$
  SELECT t.id, t.name, t.type, t.color, TRUE as is_own
  FROM mind_map_app_tags t
  JOIN mind_map_app_task_tags tt ON t.id = tt.tag_id
  WHERE tt.task_id = task_uuid
  UNION
  SELECT DISTINCT t.id, t.name, t.type, t.color, FALSE as is_own
  FROM mind_map_app_tags t
  JOIN mind_map_app_task_tags tt ON t.id = tt.tag_id
  JOIN mind_map_app_get_ancestor_ids(task_uuid) a ON tt.task_id = a.ancestor_id
  WHERE t.id NOT IN (
    SELECT tag_id FROM mind_map_app_task_tags WHERE task_id = task_uuid
  );
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION mind_map_app_get_descendant_ids(task_uuid UUID)
RETURNS TABLE(descendant_id UUID) AS $$
WITH RECURSIVE descendants AS (
  SELECT id FROM mind_map_app_tasks WHERE parent_id = task_uuid
  UNION ALL
  SELECT t.id FROM mind_map_app_tasks t
  JOIN descendants d ON t.parent_id = d.id
)
SELECT id FROM descendants;
$$ LANGUAGE SQL;

-- ============================================
-- STEP 8: Add new columns to mind_map_app_tasks
-- ============================================
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS preferred_time TEXT;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS energy_required TEXT DEFAULT 'medium';
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS estimated_minutes INT;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS due_date DATE;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS is_recurring BOOLEAN DEFAULT FALSE;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS recurrence_pattern TEXT;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS last_completed_at TIMESTAMPTZ;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS auto_priority INT DEFAULT 50;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS times_completed INT DEFAULT 0;
ALTER TABLE mind_map_app_tasks ADD COLUMN IF NOT EXISTS times_skipped INT DEFAULT 0;

-- Add new column to tags
ALTER TABLE mind_map_app_tags ADD COLUMN IF NOT EXISTS sort_order INT DEFAULT 0;

-- New indexes for added columns
CREATE INDEX IF NOT EXISTS idx_mind_map_app_tasks_status ON mind_map_app_tasks USING btree (status);
CREATE INDEX IF NOT EXISTS idx_mind_map_app_tasks_preferred_time ON mind_map_app_tasks USING btree (preferred_time);
CREATE INDEX IF NOT EXISTS idx_mind_map_app_tasks_due_date ON mind_map_app_tasks USING btree (due_date);

-- ============================================
-- STEP 9: Create new tables (with prefix)
-- ============================================

-- Activity Log
CREATE TABLE IF NOT EXISTS mind_map_app_activity_log (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  task_id UUID REFERENCES mind_map_app_tasks(id) ON DELETE SET NULL,
  task_name TEXT NOT NULL,
  action TEXT NOT NULL,
  location_tag_id UUID REFERENCES mind_map_app_tags(id) ON DELETE SET NULL,
  mood_tag_id UUID REFERENCES mind_map_app_tags(id) ON DELETE SET NULL,
  day_of_week INT,
  hour_of_day INT,
  duration_minutes INT,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mind_map_app_activity_task ON mind_map_app_activity_log USING btree (task_id);
CREATE INDEX IF NOT EXISTS idx_mind_map_app_activity_time ON mind_map_app_activity_log USING btree (created_at);
CREATE INDEX IF NOT EXISTS idx_mind_map_app_activity_hour ON mind_map_app_activity_log USING btree (hour_of_day);
CREATE INDEX IF NOT EXISTS idx_mind_map_app_activity_day ON mind_map_app_activity_log USING btree (day_of_week);

ALTER TABLE mind_map_app_activity_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "mind_map_app_activity_log_all" ON mind_map_app_activity_log FOR ALL USING (true) WITH CHECK (true);

-- Chat Memory
CREATE TABLE IF NOT EXISTS mind_map_app_chat_memory (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE mind_map_app_chat_memory ENABLE ROW LEVEL SECURITY;
CREATE POLICY "mind_map_app_chat_memory_all" ON mind_map_app_chat_memory FOR ALL USING (true) WITH CHECK (true);

-- ============================================
-- STEP 10: Seed chat memory defaults
-- ============================================
INSERT INTO mind_map_app_chat_memory (key, value) VALUES
  ('user_name', 'Aniket'),
  ('default_location', 'Room'),
  ('work_hours', '9-18'),
  ('commute_hours', '7-9,18-20'),
  ('sleep_time', '23'),
  ('wake_time', '6'),
  ('current_mood', 'Energetic'),
  ('current_location', 'Room')
ON CONFLICT (key) DO NOTHING;

-- ============================================
-- STEP 11: Add new tag types (if not already present)
-- ============================================
INSERT INTO mind_map_app_tags (name, type, color, sort_order) VALUES
  ('Morning', 'time_slot', '#f39c12', 1),
  ('Afternoon', 'time_slot', '#e67e22', 2),
  ('Evening', 'time_slot', '#9b59b6', 3),
  ('Night', 'time_slot', '#34495e', 4),
  ('Commute', 'time_slot', '#3498db', 5),
  ('High energy', 'energy', '#27ae60', 1),
  ('Medium energy', 'energy', '#f1c40f', 2),
  ('Low energy', 'energy', '#95a5a6', 3),
  ('Anywhere', 'location', '#7f8c8d', 7),
  ('Reading', 'category', '#16a085', 6),
  ('Exercise', 'category', '#c0392b', 7),
  ('Errands', 'category', '#7f8c8d', 8),
  ('Critical', 'priority', '#c0392b', 0),
  ('Someday', 'priority', '#bdc3c7', 4),
  ('2hours+', 'duration', '#c0392b', 5),
  ('Mechanical', 'subject', '#f39c12', 6)
ON CONFLICT (name, type) DO NOTHING;

-- ============================================
-- VERIFICATION
-- ============================================
-- Run these to confirm everything worked:
--
-- SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'mind_map_app_%' ORDER BY tablename;
--
-- SELECT count(*) as tasks FROM mind_map_app_tasks;
-- SELECT count(*) as tags FROM mind_map_app_tags;
-- SELECT count(*) as task_tags FROM mind_map_app_task_tags;
-- SELECT count(*) as memory FROM mind_map_app_chat_memory;
