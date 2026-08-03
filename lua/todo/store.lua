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

local migration_v2 = {
    [[ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task'
    CHECK(kind IN ('task','notice'))]],
    [[CREATE TABLE IF NOT EXISTS reminders (
    task_id INTEGER PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    recurrence_type TEXT NOT NULL DEFAULT 'once'
      CHECK(recurrence_type IN ('once','daily','weekdays','weekly','interval')),
    recurrence_every INTEGER NOT NULL DEFAULT 1 CHECK(recurrence_every > 0),
    recurrence_unit TEXT CHECK(recurrence_unit IN ('minutes','hours','days')),
    weekdays TEXT NOT NULL DEFAULT '',
    repeat_interval_seconds INTEGER NOT NULL CHECK(repeat_interval_seconds > 0),
    scheduled_at INTEGER NOT NULL,
    next_reminder_at INTEGER NOT NULL,
    snoozed_until INTEGER,
    last_reminded_at INTEGER,
    occurrence_started_at INTEGER NOT NULL
  )]],
    [[CREATE TABLE IF NOT EXISTS todo_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )]],
    "CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(enabled, next_reminder_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_kind_archived ON tasks(kind, archived_at)",
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
    if version > 2 then
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
        version = 1
    end
    if version < 2 then
        transaction(db, function()
            for _, statement in ipairs(migration_v2) do
                db:execute(statement)
            end
            db:eval("INSERT INTO schema_migrations(version, applied_at) VALUES(:version, :applied_at)", {
                version = 2,
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

function M:_reminder_for(task_id)
    local row = query_one(self.db, "SELECT * FROM reminders WHERE task_id = :task_id", { task_id = task_id })
    if not row then
        return nil
    end
    local weekdays = {}
    for value in tostring(row.weekdays or ""):gmatch("%d+") do
        weekdays[#weekdays + 1] = tonumber(value)
    end
    return {
        enabled = tonumber(row.enabled) == 1,
        recurrence = {
            kind = row.recurrence_type,
            every = tonumber(row.recurrence_every),
            unit = row.recurrence_unit,
            weekdays = weekdays,
        },
        repeat_interval_seconds = tonumber(row.repeat_interval_seconds),
        scheduled_at = tonumber(row.scheduled_at),
        next_reminder_at = tonumber(row.next_reminder_at),
        snoozed_until = row.snoozed_until and tonumber(row.snoozed_until) or nil,
        last_reminded_at = row.last_reminded_at and tonumber(row.last_reminded_at) or nil,
        occurrence_started_at = tonumber(row.occurrence_started_at),
    }
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
        row.kind = row.kind or "task"
        row.tags = self:_tags_for(row.id)
        row.reminder = self:_reminder_for(row.id)
    end
    return rows
end

function M:list(opts)
    opts = opts or {}
    local predicate = opts.archived and "archived_at IS NOT NULL" or "archived_at IS NULL"
    if opts.kind then
        predicate = predicate .. " AND kind = :kind"
    end
    local rows =
        self.db:eval("SELECT * FROM tasks WHERE " .. predicate .. " ORDER BY created_at, id", { kind = opts.kind })
    return self:_hydrate(rows)
end

function M:list_tags()
    local rows = self.db:eval("SELECT name FROM tags ORDER BY lower(name), name")
    local result = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        result[#result + 1] = row.name
    end
    return result
end

function M:tag_stats()
    local rows = self.db:eval([[
    SELECT tags.name, COUNT(task_tags.task_id) AS task_count
    FROM tags
    LEFT JOIN task_tags ON task_tags.tag_id = tags.id
    GROUP BY tags.id, tags.name
    ORDER BY lower(tags.name), tags.name
  ]])
    local result = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        result[#result + 1] = { name = row.name, task_count = tonumber(row.task_count) or 0 }
    end
    return result
end

function M:create_tag(name)
    self.db:eval("INSERT OR IGNORE INTO tags(name) VALUES(:name)", { name = name })
    local row = query_one(self.db, "SELECT name FROM tags WHERE name = :name COLLATE NOCASE", { name = name })
    return row and row.name or nil
end

function M:rename_tag(old_name, new_name)
    return transaction(self.db, function()
        local source = query_one(self.db, "SELECT id FROM tags WHERE name = :name COLLATE NOCASE", { name = old_name })
        if not source then
            return nil
        end
        local target = query_one(self.db, "SELECT id FROM tags WHERE name = :name COLLATE NOCASE", { name = new_name })
        if target and tonumber(target.id) ~= tonumber(source.id) then
            self.db:eval(
                [[
        INSERT OR IGNORE INTO task_tags(task_id, tag_id)
        SELECT task_id, :target_id FROM task_tags WHERE tag_id = :source_id
      ]],
                { target_id = target.id, source_id = source.id }
            )
            self.db:eval("DELETE FROM tags WHERE id = :id", { id = source.id })
            return new_name
        end
        self.db:eval("UPDATE tags SET name = :new_name WHERE id = :id", { new_name = new_name, id = source.id })
        return new_name
    end)
end

function M:delete_tag(name)
    local row = query_one(self.db, "SELECT id FROM tags WHERE name = :name COLLATE NOCASE", { name = name })
    if not row then
        return false
    end
    self.db:eval("DELETE FROM tags WHERE id = :id", { id = row.id })
    return true
end

function M:stats()
    local row = query_one(
        self.db,
        [[
    SELECT
      SUM(CASE WHEN archived_at IS NULL AND kind = 'task' THEN 1 ELSE 0 END) AS active,
      SUM(CASE WHEN archived_at IS NULL
        AND kind = 'task'
        AND status IN ('todo', 'in_progress')
        AND (due_date IS NOT NULL OR priority <= 1)
        THEN 1 ELSE 0 END) AS emergency,
      SUM(CASE WHEN archived_at IS NOT NULL THEN 1 ELSE 0 END) AS archived,
      SUM(CASE WHEN archived_at IS NULL AND kind = 'notice' THEN 1 ELSE 0 END) AS notices
    FROM tasks
  ]]
    ) or {}
    return {
        active = tonumber(row.active) or 0,
        emergency = tonumber(row.emergency) or 0,
        archived = tonumber(row.archived) or 0,
        notices = tonumber(row.notices) or 0,
    }
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

function M:_set_reminder(task_id, reminder)
    if not reminder then
        self.db:eval("DELETE FROM reminders WHERE task_id = :task_id", { task_id = task_id })
        return
    end
    local rule = reminder.recurrence or { kind = "once", every = 1, weekdays = {} }
    self.db:eval(
        [[INSERT INTO reminders(
      task_id, enabled, recurrence_type, recurrence_every, recurrence_unit, weekdays,
      repeat_interval_seconds, scheduled_at, next_reminder_at, snoozed_until,
      last_reminded_at, occurrence_started_at
    ) VALUES(
      :task_id, :enabled, :recurrence_type, :recurrence_every, :recurrence_unit, :weekdays,
      :repeat_interval_seconds, :scheduled_at, :next_reminder_at, :snoozed_until,
      :last_reminded_at, :occurrence_started_at
    ) ON CONFLICT(task_id) DO UPDATE SET
      enabled = excluded.enabled,
      recurrence_type = excluded.recurrence_type,
      recurrence_every = excluded.recurrence_every,
      recurrence_unit = excluded.recurrence_unit,
      weekdays = excluded.weekdays,
      repeat_interval_seconds = excluded.repeat_interval_seconds,
      scheduled_at = excluded.scheduled_at,
      next_reminder_at = excluded.next_reminder_at,
      snoozed_until = excluded.snoozed_until,
      last_reminded_at = excluded.last_reminded_at,
      occurrence_started_at = excluded.occurrence_started_at]],
        {
            task_id = task_id,
            enabled = reminder.enabled == false and 0 or 1,
            recurrence_type = rule.kind or "once",
            recurrence_every = rule.every or 1,
            recurrence_unit = rule.unit,
            weekdays = table.concat(rule.weekdays or {}, ","),
            repeat_interval_seconds = reminder.repeat_interval_seconds,
            scheduled_at = reminder.scheduled_at,
            next_reminder_at = reminder.next_reminder_at,
            snoozed_until = reminder.snoozed_until,
            last_reminded_at = reminder.last_reminded_at,
            occurrence_started_at = reminder.occurrence_started_at or reminder.scheduled_at,
        }
    )
end

function M:create(task)
    return transaction(self.db, function()
        local now = os.time()
        self.db:eval(
            [[
      INSERT INTO tasks(kind, title, description, status, priority, due_date, due_time, created_at, updated_at)
      VALUES(:kind, :title, :description, :status, :priority, :due_date, :due_time, :created_at, :updated_at)
    ]],
            {
                kind = task.kind or "task",
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
        self:_set_reminder(id, task.reminder)
        return self:get(id)
    end)
end

function M:update(id, task)
    return transaction(self.db, function()
        self.db:eval(
            [[
      UPDATE tasks SET
        kind = :kind,
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
                kind = task.kind or "task",
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
        self:_set_reminder(id, task.reminder)
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
    if status == "done" or status == "cancelled" then
        self.db:eval("UPDATE reminders SET enabled = 0 WHERE task_id = :id", { id = id })
    elseif status == "todo" or status == "in_progress" then
        self.db:eval("UPDATE reminders SET enabled = 1 WHERE task_id = :id", { id = id })
    end
    return self:get(id)
end

function M:archive(id)
    local now = os.time()
    self.db:eval("UPDATE tasks SET archived_at = :now, updated_at = :now WHERE id = :id", { id = id, now = now })
    self.db:eval("UPDATE reminders SET enabled = 0 WHERE task_id = :id", { id = id })
    return self:get(id)
end

function M:restore(id)
    self.db:eval("UPDATE tasks SET archived_at = NULL, updated_at = :now WHERE id = :id", {
        id = id,
        now = os.time(),
    })
    self.db:eval("UPDATE reminders SET enabled = 1 WHERE task_id = :id", { id = id })
    return self:get(id)
end

function M:due_reminders(now)
    local rows = self.db:eval(
        [[SELECT tasks.* FROM tasks
      JOIN reminders ON reminders.task_id = tasks.id
      WHERE reminders.enabled = 1
        AND reminders.next_reminder_at <= :now
        AND tasks.archived_at IS NULL
        AND tasks.status IN ('todo','in_progress')
      ORDER BY reminders.next_reminder_at, tasks.id]],
        { now = now }
    )
    return self:_hydrate(rows)
end

function M:next_reminder_time()
    local row = query_one(
        self.db,
        [[SELECT MIN(reminders.next_reminder_at) AS next_at FROM reminders
      JOIN tasks ON tasks.id = reminders.task_id
      WHERE reminders.enabled = 1 AND tasks.archived_at IS NULL
        AND tasks.status IN ('todo','in_progress')]]
    )
    return row and row.next_at and tonumber(row.next_at) or nil
end

function M:mark_reminded(id, now)
    self.db:eval(
        [[UPDATE reminders SET
      last_reminded_at = :now,
      next_reminder_at = :now + repeat_interval_seconds,
      snoozed_until = NULL
      WHERE task_id = :id AND enabled = 1]],
        { id = id, now = now }
    )
    return self:get(id)
end

function M:snooze(id, until_at)
    self.db:eval(
        "UPDATE reminders SET next_reminder_at = :until_at, snoozed_until = :until_at WHERE task_id = :id",
        { id = id, until_at = until_at }
    )
    return self:get(id)
end

function M:advance_occurrence(id, next_at, now)
    if next_at then
        self.db:eval(
            [[UPDATE reminders SET scheduled_at = :next_at, next_reminder_at = :next_at,
        occurrence_started_at = :next_at, snoozed_until = NULL, last_reminded_at = NULL
        WHERE task_id = :id]],
            { id = id, next_at = next_at }
        )
    else
        self.db:eval("UPDATE reminders SET enabled = 0 WHERE task_id = :id", { id = id })
        self.db:eval(
            [[UPDATE tasks SET status = 'done', completed_at = :now, updated_at = :now WHERE id = :id]],
            { id = id, now = now }
        )
    end
    return self:get(id)
end

function M:set_reminder_enabled(id, enabled)
    self.db:eval("UPDATE reminders SET enabled = :enabled WHERE task_id = :id", {
        id = id,
        enabled = enabled and 1 or 0,
    })
    return self:get(id)
end

function M:get_setting(key)
    local row = query_one(self.db, "SELECT value FROM todo_settings WHERE key = :key", { key = key })
    return row and row.value or nil
end

function M:set_setting(key, value)
    self.db:eval(
        [[INSERT INTO todo_settings(key, value) VALUES(:key, :value)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value]],
        { key = key, value = tostring(value) }
    )
    return tostring(value)
end

function M:delete_archived(id)
    local task = self:get(id)
    if not task or not task.archived_at then
        return false
    end
    self.db:eval("DELETE FROM tasks WHERE id = :id AND archived_at IS NOT NULL", { id = id })
    return self:get(id) == nil
end

return M
