local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local passed, failed, skipped = 0, 0, 0

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok - " .. name)
  else
    failed = failed + 1
    print("not ok - " .. name .. "\n" .. err)
  end
end

local function skip(name, reason)
  skipped = skipped + 1
  print("skip - " .. name .. " (" .. reason .. ")")
end

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
    )
  end
end

test("configuration defaults and validation", function()
  local config = require("todo.config")
  local cfg = config.setup({ language = "zh-CN", ui = { default_mode = "sidebar" } })
  eq(cfg.language, "zh-CN")
  eq(cfg.ui.default_mode, "sidebar")
  local ok = pcall(config.setup, { language = "fr" })
  eq(ok, false)
  eq(pcall(config.setup, { ui = { float = { width = 80 } } }), false)
  config.setup({ keymaps = { enabled = false } })
end)

test("command completion distinguishes subcommands and arguments", function()
  local commands = require("todo.commands")
  eq(commands.complete("op", ":Todo op"), { "open" })
  eq(commands.complete("s", ":Todo open s"), { "sidebar" })
end)

test("model validates and normalizes input", function()
  local model = require("todo.model")
  local task = assert(model.validate({
    title = "  Ship plugin  ",
    priority = "P1",
    deadline = "2026-08-02 09:30",
    tags = "Lua, nvim, lua",
    description = "notes",
  }))
  eq(task.title, "Ship plugin")
  eq(task.priority, 1)
  eq(task.tags, { "Lua", "nvim" })
  eq(task.due_date, "2026-08-02")
  eq(task.due_time, "09:30")
  local invalid, errors = model.validate({ title = "", priority = "P9", deadline = "2026-02-30" })
  eq(invalid, nil)
  assert(errors.title and errors.priority and errors.deadline)
end)

test("urgency combines deadline and priority deterministically", function()
  local urgency = require("todo.urgency")
  local now = os.time({ year = 2026, month = 8, day = 1, hour = 12, min = 0, sec = 0 })
  local tasks = {
    {
      id = 1,
      title = "overdue",
      status = "todo",
      priority = 3,
      due_date = "2026-07-31",
      due_time = "12:00",
      created_at = 1,
    },
    {
      id = 2,
      title = "today p0",
      status = "todo",
      priority = 0,
      due_date = "2026-08-01",
      due_time = "18:00",
      created_at = 2,
    },
    { id = 3, title = "no due p1", status = "in_progress", priority = 1, created_at = 3 },
    { id = 4, title = "no due p2", status = "todo", priority = 2, created_at = 4 },
  }
  local result = urgency.sort(tasks, now)
  eq(
    vim.tbl_map(function(task)
      return task.id
    end, result),
    { 1, 2, 3 }
  )
  eq(result[1].urgency.level, "overdue")
  eq(result[3].urgency.level, "priority_only")
end)

local function memory_store(tasks)
  local store = { rows = tasks or {}, next_id = 100 }
  function store:list(opts)
    return vim.tbl_filter(function(task)
      return (opts.archived and task.archived_at ~= nil) or (not opts.archived and task.archived_at == nil)
    end, vim.deepcopy(self.rows))
  end
  function store:get(id)
    for _, task in ipairs(self.rows) do
      if task.id == id then
        return task
      end
    end
  end
  function store:create(task)
    task = vim.deepcopy(task)
    task.id = self.next_id
    task.created_at = os.time()
    task.updated_at = task.created_at
    self.next_id = self.next_id + 1
    self.rows[#self.rows + 1] = task
    return task
  end
  function store:update(id, task)
    task.id = id
    return task
  end
  function store:set_status(id, status)
    local task = self:get(id)
    task.status = status
    return task
  end
  function store:archive(id)
    local task = self:get(id)
    task.archived_at = os.time()
    return task
  end
  function store:restore(id)
    local task = self:get(id)
    task.archived_at = nil
    return task
  end
  return store
end

test("service searches and combines filters", function()
  local store = memory_store({
    {
      id = 1,
      title = "Write Lua",
      description = "plugin",
      status = "todo",
      priority = 0,
      tags = { "nvim" },
      created_at = 1,
    },
    {
      id = 2,
      title = "Buy milk",
      description = "shop",
      status = "done",
      priority = 2,
      tags = { "home" },
      created_at = 2,
    },
  })
  local service = require("todo.service").new(store)
  eq(#service:list("active", { search = "lua", priority = "P0", tag = "NVIM" }), 1)
  eq(#service:list("active", { status = "done" }), 1)
  local created = assert(service:create({ title = "New", priority = "P2", tags = "one,two" }))
  eq(created.id, 100)
end)

test("native panel opens in both modes with shared renderer", function()
  require("todo.config").setup({ keymaps = { enabled = false }, ui = { default_mode = "float" } })
  local fake_service = require("todo.service").new(memory_store({
    {
      id = 1,
      title = "Panel task",
      description = "Visible",
      status = "todo",
      priority = 1,
      tags = { "ui" },
      created_at = 1,
    },
  }))
  package.loaded.todo = {
    _service = function()
      return fake_service
    end,
  }
  package.loaded["todo.ui.panel"] = nil
  local panel = require("todo.ui.panel")
  panel.open({ mode = "float", view = "active" })
  assert(panel.is_open())
  eq(panel.inspect_state().tasks[1].title, "Panel task")
  panel.close()
  panel.open({ mode = "sidebar", view = "active" })
  assert(panel.is_open())
  panel.close()
  package.loaded.todo = nil
end)

local sqlite_ok = pcall(require, "sqlite.db")
if sqlite_ok then
  test("SQLite migrations and CRUD", function()
    local path = vim.fn.tempname() .. ".db"
    local store = require("todo.store").open(path)
    local service = require("todo.service").new(store)
    eq(store:list({ archived = false }), {})
    local created = assert(service:create({
      title = "Persist",
      description = "db",
      status = "todo",
      priority = "P1",
      deadline = "2026-08-03",
      tags = { "SQLite", "nvim" },
    }))
    eq(store:get(created.id).tags, { "nvim", "SQLite" })
    assert(service:set_status(created.id, "done"))
    assert(service:archive(created.id))
    eq(#store:list({ archived = true }), 1)
    assert(service:restore(created.id))
    eq(#store:list({ archived = false }), 1)
    local no_deadline = assert(service:create({ title = "No due date", priority = "P2" }))
    eq(store:get(no_deadline.id).due_date, nil)
    local updated = assert(service:update(created.id, {
      title = "Deadline removed",
      priority = "P1",
      status = "done",
      deadline = "",
      tags = {},
    }))
    eq(updated.due_date, nil)
    store:close()
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do
      os.remove(path .. suffix)
    end
  end)
else
  skip("SQLite migrations and CRUD", "kkharji/sqlite.lua is not on runtimepath")
end

print(string.format("\n%d passed, %d failed, %d skipped", passed, failed, skipped))
if failed > 0 then
  vim.cmd("cquit " .. failed)
end
vim.cmd("qa!")
