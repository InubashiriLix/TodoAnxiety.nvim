local M = {}
M.__index = M

local migration_v1 = {
  [[CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('todo','in_progress','done','cancelled')),
    priority INTEGER NOT NULL DEFAULT 2 CHECK(priority BETWEEN 0 AND 3),
    due_date TEXT,
    due_time TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    completed_at INTEGER,
    archived_at INTEGER,
    CHECK(due_time IS NULL OR due_date IS NOT NULL)
  )]],
  [[CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE
  )]],
  [[CREATE TABLE IF NOT EXISTS task_tags (
    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY(task_id, tag_id)
  )]],
  "CREATE INDEX IF NOT EXISTS idx_tasks_status_archived ON tasks(status, archived_at)",
  "CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks(due_date, due_time)",
  "CREATE INDEX IF NOT EXISTS idx_task_tags_tag ON task_tags(tag_id, task_id)",
}

local function transaction(db, fn)
  db:execute("BEGIN IMMEDIATE")
  local ok, result = xpcall(fn, debug.traceback)
  if ok then
    db:execute("COMMIT")
    return result
  end
  pcall(function()
    db:execute("ROLLBACK")
  end)
  error(result)
end

local function migrate(db)
  db:execute([[CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
  )]])
  local rows = db:eval("SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations")
  local version = rows[1] and tonumber(rows[1].version) or 0
  if version > 1 then
    error("database schema version " .. version .. " is newer than this todo.nvim supports")
  end
  if version < 1 then
    transaction(db, function()
      for _, statement in ipairs(migration_v1) do
        db:execute(statement)
      end
      db:eval("INSERT INTO schema_migrations(version, applied_at) VALUES(:version, :applied_at)", {
        version = 1,
        applied_at = os.time(),
      })
    end)
  end
end

local function query_one(db, sql, params)
  local rows = db:eval(sql, params)
  return type(rows) == "table" and rows[1] or nil
end

function M.open(path)
  local ok, sqlite = pcall(require, "sqlite.db")
  if not ok then
    error("missing dependency kkharji/sqlite.lua: " .. tostring(sqlite))
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local db = sqlite:open(path)
  db:execute("PRAGMA foreign_keys = ON")
  db:execute("PRAGMA journal_mode = WAL")
  db:execute("PRAGMA busy_timeout = 3000")
  migrate(db)
  return setmetatable({ db = db, path = path }, M)
end

function M:close()
  if self.db and self.db:isopen() then
    self.db:close()
  end
end

function M:_tags_for(task_id)
  local rows = self.db:eval(
    [[
    SELECT tags.name FROM tags
    JOIN task_tags ON task_tags.tag_id = tags.id
    WHERE task_tags.task_id = :task_id
    ORDER BY lower(tags.name), tags.name
  ]],
    { task_id = task_id }
  )
  local tags = {}
  for _, row in ipairs(type(rows) == "table" and rows or {}) do
    tags[#tags + 1] = row.name
  end
  return tags
end

function M:_hydrate(rows)
  rows = type(rows) == "table" and rows or {}
  for _, row in ipairs(rows) do
    row.id = tonumber(row.id)
    row.priority = tonumber(row.priority)
    row.created_at = tonumber(row.created_at)
    row.updated_at = tonumber(row.updated_at)
    row.completed_at = row.completed_at and tonumber(row.completed_at) or nil
    row.archived_at = row.archived_at and tonumber(row.archived_at) or nil
    row.tags = self:_tags_for(row.id)
  end
  return rows
end

function M:list(opts)
  opts = opts or {}
  local predicate = opts.archived and "archived_at IS NOT NULL" or "archived_at IS NULL"
  local rows = self.db:eval("SELECT * FROM tasks WHERE " .. predicate .. " ORDER BY created_at, id")
  return self:_hydrate(rows)
end

function M:get(id)
  local row = query_one(self.db, "SELECT * FROM tasks WHERE id = :id", { id = id })
  return row and self:_hydrate({ row })[1] or nil
end

function M:_set_tags(task_id, tags)
  self.db:eval("DELETE FROM task_tags WHERE task_id = :task_id", { task_id = task_id })
  for _, name in ipairs(tags or {}) do
    self.db:eval("INSERT OR IGNORE INTO tags(name) VALUES(:name)", { name = name })
    local tag = query_one(self.db, "SELECT id FROM tags WHERE name = :name COLLATE NOCASE", { name = name })
    self.db:eval("INSERT INTO task_tags(task_id, tag_id) VALUES(:task_id, :tag_id)", {
      task_id = task_id,
      tag_id = tag.id,
    })
  end
end

function M:create(task)
  return transaction(self.db, function()
    local now = os.time()
    self.db:eval(
      [[
      INSERT INTO tasks(title, description, status, priority, due_date, due_time, created_at, updated_at)
      VALUES(:title, :description, :status, :priority, :due_date, :due_time, :created_at, :updated_at)
    ]],
      {
        title = task.title,
        description = task.description,
        status = task.status,
        priority = task.priority,
        due_date = task.due_date,
        due_time = task.due_time,
        created_at = now,
        updated_at = now,
      }
    )
    local inserted = query_one(self.db, "SELECT last_insert_rowid() AS id")
    local id = tonumber(inserted.id)
    self:_set_tags(id, task.tags)
    return self:get(id)
  end)
end

function M:update(id, task)
  return transaction(self.db, function()
    self.db:eval(
      [[
      UPDATE tasks SET
        title = :title,
        description = :description,
        status = :status,
        priority = :priority,
        due_date = :due_date,
        due_time = :due_time,
        completed_at = CASE WHEN :status = 'done' THEN COALESCE(completed_at, :now) ELSE NULL END,
        updated_at = :now
      WHERE id = :id
    ]],
      {
        id = id,
        title = task.title,
        description = task.description,
        status = task.status,
        priority = task.priority,
        due_date = task.due_date,
        due_time = task.due_time,
        now = os.time(),
      }
    )
    self:_set_tags(id, task.tags)
    return self:get(id)
  end)
end

function M:set_status(id, status)
  local now = os.time()
  self.db:eval(
    [[
    UPDATE tasks SET status = :status,
      completed_at = CASE WHEN :status = 'done' THEN :now ELSE NULL END,
      updated_at = :now
    WHERE id = :id
  ]],
    { id = id, status = status, now = now }
  )
  return self:get(id)
end

function M:archive(id)
  local now = os.time()
  self.db:eval("UPDATE tasks SET archived_at = :now, updated_at = :now WHERE id = :id", { id = id, now = now })
  return self:get(id)
end

function M:restore(id)
  self.db:eval("UPDATE tasks SET archived_at = NULL, updated_at = :now WHERE id = :id", {
    id = id,
    now = os.time(),
  })
  return self:get(id)
end

return M
