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
  config.setup({ keymaps = { toggle = false } })
end)

test("keymaps accept full key strings and false", function()
  local config = require("todo.config")

  config.setup({
    keymaps = {
      toggle = "<C-t>",
      add = false,
      manage_tags = "<leader>tg",
    },
    icons = {
      toggle = { icon = "!", color = "red" },
      add = "",
    },
  })
  local km = config.get().keymaps
  eq(km.toggle, "<C-t>")
  eq(km.add, false)
  eq(km.manage_tags, "<leader>tg")
  eq(km.open_float, "<leader>Tf", "missing keys keep defaults")
  eq(km.open_sidebar, "<leader>Ts")
  eq(km.open_emergency, "<leader>Te")
  eq(config.get().icons.toggle, { icon = "!", color = "red" })
  eq(config.get().icons.add, "")
end)

test("keymaps: register, disable, and cleanup across re-configurations", function()
  local config = require("todo.config")
  local which_key_specs = {}
  package.loaded["which-key"] = {
    add = function(specs)
      which_key_specs[#which_key_specs + 1] = specs
    end,
  }
  config.setup({
    keymaps = { toggle = "<C-x>", add = "<C-a>" },
    icons = {
      toggle = { icon = "✦", color = "yellow" },
      add = { icon = "✚", color = "green" },
    },
  })

  local M = require("todo")
  M._bootstrap()

  local function registered(lhs)
    local d = vim.fn.maparg(lhs, "n", false, true)
    return d.lhs and d.lhs ~= ""
  end

  local function desc(lhs)
    return vim.fn.maparg(lhs, "n", false, true).desc or ""
  end

  assert(registered("<C-x>"), "<C-x> should be mapped")
  eq(desc("<C-x>"), "todo.nvim: toggle")
  assert(registered("<C-a>"), "<C-a> should be mapped")
  eq(desc("<C-a>"), "todo.nvim: add task")
  local specs = which_key_specs[#which_key_specs]
  local by_lhs = {}
  for _, spec in ipairs(specs) do
    by_lhs[spec[1]] = spec
  end
  eq(by_lhs["<C-x>"].icon, { icon = "✦", color = "yellow" })
  eq(by_lhs["<C-a>"].icon, { icon = "✚", color = "green" })

  -- Reconfigure without add -> old maps should be cleaned up
  config.setup({ keymaps = { toggle = "<C-y>", add = false } })
  M._bootstrap()

  assert(registered("<C-y>"), "<C-y> should be mapped after reconfig")
  assert(not registered("<C-x>"), "<C-x> should be cleaned up")
  assert(not registered("<C-a>"), "<C-a> should be cleaned up when disabled")
  package.loaded["which-key"] = nil
end)

test("keymaps: reject non-string, non-false values", function()
  local config = require("todo.config")
  eq(pcall(config.setup, { keymaps = { toggle = 1 } }), false)
  eq(pcall(config.setup, { keymaps = { toggle = true } }), false)
  eq(pcall(config.setup, { keymaps = { toggle = {} } }), false)
  eq(pcall(config.setup, { keymaps = { toggle = "" } }), false, "empty string should be rejected")
  eq(pcall(config.setup, { keymaps = { toggle = false } }), true)
  eq(pcall(config.setup, { keymaps = { toggle = "<leader>t" } }), true)
end)

test("keymaps: non-conflicting with pre-existing user mappings", function()
  local config = require("todo.config")
  vim.keymap.set("n", "<C-q>", "<Nop>", { silent = true, desc = "user: close" })
  config.setup({ keymaps = { toggle = "<C-q>", add = false } })
  require("todo")._bootstrap()
  -- The warn notify is scheduled; just verify nothing exploded.
end)

test("keymaps: partial override leaves other keys at defaults", function()
  local config = require("todo.config")
  config.setup({ keymaps = { toggle = "<leader>X" } })
  local km = config.get().keymaps
  eq(km.toggle, "<leader>X")
  eq(km.add, "<leader>Ta")
  eq(km.open_float, "<leader>Tf")
  eq(km.open_sidebar, "<leader>Ts")
  eq(km.open_emergency, "<leader>Te")
  eq(km.manage_tags, "<leader>Tg")
end)

test("keymaps: icons missing from config fall back to defaults", function()
  local config = require("todo.config")
  config.setup({ icons = { toggle = "X" } })
  eq(config.get().icons.toggle, "X")
  eq(config.get().icons.add, { icon = "\u{f067}", color = "green" })
end)

test("keymaps: validate which-key icon specs", function()
  local config = require("todo.config")
  eq(pcall(config.setup, { icons = { toggle = { icon = "X", color = "red" } } }), true)
  eq(pcall(config.setup, { icons = { toggle = { icon = "X", color = "pink" } } }), false)
  eq(pcall(config.setup, { icons = { toggle = { color = "red" } } }), true)
  eq(config.get().icons.toggle, { icon = "\u{f204}", color = "red" })
  eq(pcall(config.setup, { icons = { toggle = false } }), true)
end)

test("keymaps: health check iterates over configured keymaps", function()
  local config = require("todo.config")
  config.setup({
    keymaps = { toggle = "<leader>Tt", add = false, manage_tags = "<leader>Tg" },
  })
  require("todo")._bootstrap()

  -- health should handle false entries without error
  local ok, err = pcall(require, "todo.health")
  assert(ok, "health module loaded: " .. tostring(err))
end)

test("command completion distinguishes subcommands and arguments", function()
  local commands = require("todo.commands")
  eq(commands.complete("op", ":Todo op"), { "open" })
  eq(commands.complete("ta", ":Todo ta"), { "tags" })
  eq(commands.complete("s", ":Todo open s"), { "sidebar" })
  eq(commands.complete("del", ":Todo del"), { "delete" })
end)

test("plugin UI source contains no mouse or Ctrl-Space mappings", function()
  for _, path in ipairs(vim.fn.glob(root .. "/lua/**/*.lua", false, true)) do
    local source = table.concat(vim.fn.readfile(path), "\n")
    assert(not source:find("<LeftMouse>", 1, true), "mouse mapping remains in " .. path)
    assert(not source:find("getmousepos", 1, true), "mouse handling remains in " .. path)
    assert(not source:find("<C-Space>", 1, true), "Ctrl-Space mapping remains in " .. path)
  end
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

test("form state tracks fields, presets, tags, and dirty state", function()
  local FormState = require("todo.ui.form_state")
  local state = FormState.new({ title = "Original", priority = 1, tags = { "nvim" } })
  eq(state:is_dirty(), false)
  state:set("title", "Changed")
  eq(state:is_dirty(), true)
  state:add_tag("Lua")
  state:add_tag("lua")
  eq(state:get("tags"), { "Lua", "nvim" })
  local now = os.time({ year = 2026, month = 8, day = 1, hour = 9, min = 0, sec = 0 })
  eq(state:set_deadline_preset("tomorrow", now), "2026-08-02")
  state:remove_last_tag()
  eq(state:get("tags"), { "Lua" })
  assert(state:validate())
end)

test("calendar state navigates months, leap days, and optional time", function()
  local CalendarState = require("todo.ui.calendar_state")
  local now = os.time({ year = 2026, month = 8, day = 1, hour = 9, min = 0, sec = 0 })
  local calendar = CalendarState.new("2028-02-29 18:00", now)
  eq(calendar:value(), "2028-02-29 18:00")
  eq(calendar:days_in_month(), 29)
  calendar:shift_month(1)
  eq(calendar:value(), "2028-03-29 18:00")
  calendar:move_days(3)
  eq(calendar:value(), "2028-04-01 18:00")
  calendar:set_time("")
  eq(calendar:value(), "2028-04-01")
  eq(#calendar:cells(), 42)
end)

test("time state supports arbitrary HHMM input and fine adjustment", function()
  local TimeState = require("todo.ui.time_state")
  local time = TimeState.new("2026-08-01 18:07")
  eq(time:value(), "18:07")
  time:move(1)
  eq(time:value(), "19:07")
  time:switch(1):move(-5)
  eq(time:value(), "19:02")
  time.field = "hour"
  eq(time:input_digit(0), nil)
  eq(time:input_digit(9), true)
  eq(time:input_digit(3), nil)
  eq(time:input_digit(7), true)
  eq(time:value(), "09:37")
  time.field = "hour"
  time:input_digit(2)
  eq(time:input_digit(9), false)
  eq(time:value(), "09:37")
end)

test("dashboard viewmodel groups statuses and truncates Unicode", function()
  local viewmodel = require("todo.ui.viewmodel")
  local tasks = {
    { id = 1, status = "todo" },
    { id = 2, status = "in_progress" },
    { id = 3, status = "todo" },
    { id = 4, status = "done" },
  }
  local sections = viewmodel.sections(tasks, "active")
  eq(
    vim.tbl_map(function(section)
      return section.key
    end, sections),
    { "in_progress", "todo", "done" }
  )
  eq(#sections[2].tasks, 2)
  local truncated = viewmodel.truncate("这是一个很长的任务标题", 10)
  assert(vim.fn.strdisplaywidth(truncated) <= 10)
  assert(vim.endswith(truncated, "…"))
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
  function store:delete_archived(id)
    for index, task in ipairs(self.rows) do
      if task.id == id and task.archived_at then
        table.remove(self.rows, index)
        return true
      end
    end
    return false
  end
  function store:list_tags()
    return { "existing", "work" }
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

test("service permanently deletes archived tasks only", function()
  local store = memory_store({
    { id = 1, title = "Active", archived_at = nil },
    { id = 2, title = "Archived", archived_at = 10 },
  })
  local service = require("todo.service").new(store)
  local deleted, active_error = service:delete_archived(1)
  eq(deleted, nil)
  eq(active_error, { archived = "required" })
  assert(service:delete_archived(2))
  eq(store:get(2), nil)
  local missing, missing_error = service:delete_archived(999)
  eq(missing, nil)
  eq(missing_error, { id = "not_found" })
end)

local nui_ok = pcall(require, "nui.popup")
if nui_ok then
  test("NUI dashboard opens in responsive float and sidebar modes", function()
    require("todo.config").setup({ keymaps = { toggle = false }, ui = { default_mode = "float" } })
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
    vim.wait(20)
    assert(panel.is_open())
    eq(panel.inspect_state().tasks[1].title, "Panel task")
    eq(panel.inspect_state().owner.wide, false)
    local float_lines = vim.api.nvim_buf_get_lines(panel.inspect_state().owner.list.bufnr, 0, -1, false)
    assert(vim.iter(float_lines):any(function(line)
      return line:find("Panel task", 1, true) ~= nil
    end))
    panel.close()
    panel.open({ mode = "sidebar", view = "active" })
    vim.wait(20)
    assert(panel.is_open())
    local sidebar_state = panel.inspect_state()
    local sidebar_width = vim.api.nvim_win_get_width(sidebar_state.owner.split.winid)
    local sidebar_lines = vim.api.nvim_buf_get_lines(sidebar_state.owner.split.bufnr, 0, -1, false)
    eq(sidebar_state.tab_line, 2)
    for _, line in ipairs(sidebar_lines) do
      assert(vim.fn.strdisplaywidth(line) <= sidebar_width, "sidebar line exceeds window width: " .. line)
    end
    assert(sidebar_lines[#sidebar_lines]:find("[a +]", 1, true))
    vim.api.nvim_set_current_win(sidebar_state.owner.split.winid)
    vim.fn.feedkeys("a", "xt")
    assert(
      vim.wait(100, function()
        return require("todo.ui.form").inspect_state() ~= nil
      end),
      "add form did not open"
    )
    assert(not panel.is_open(), "dashboard should be suspended while the form is open")
    vim.wait(20)
    require("todo.ui.form").close(true)
    assert(
      vim.wait(100, function()
        return panel.is_open()
      end),
      "dashboard did not resume after the form closed"
    )
    eq(panel.inspect_state().mode, "sidebar")
    eq(panel.inspect_state().view, "active")
    panel.close()
    package.loaded.todo = nil
  end)

  test("NUI form mounts structured fields and closes cleanly", function()
    local fake_service = require("todo.service").new(memory_store({}))
    package.loaded.todo = {
      _service = function()
        return fake_service
      end,
    }
    package.loaded["todo.ui.form"] = nil
    local form = require("todo.ui.form")
    local close_reason
    form.open({ title = "Structured form", priority = 2 }, function(input)
      return fake_service:create(input)
    end, {
      on_close = function(reason)
        close_reason = reason
      end,
    })
    local form_state = assert(form.inspect_state())
    eq(form_state.state:get("title"), "Structured form")
    assert(form_state.layout)
    vim.wait(20)
    local priority_line = vim.api.nvim_buf_get_lines(form_state.components.priority.bufnr, 0, 1, false)[1]
    for value = 0, 3 do
      assert(priority_line:find("P" .. value, 1, true), "priority selector does not show every choice")
    end
    vim.api.nvim_set_current_win(form_state.components.priority.winid)
    vim.cmd("stopinsert")
    vim.fn.feedkeys("0", "xt")
    assert(
      vim.wait(100, function()
        return form_state.state:get("priority") == "P0"
      end),
      "priority number shortcut did not select P0"
    )
    local status_line = vim.api.nvim_buf_get_lines(form_state.components.status.bufnr, 0, 1, false)[1]
    assert(status_line:find("Todo", 1, true) and status_line:find("In progress", 1, true))
    vim.api.nvim_set_current_win(form_state.components.status.winid)
    vim.fn.feedkeys("2", "xt")
    assert(
      vim.wait(100, function()
        return form_state.state:get("status") == "in_progress"
      end),
      "status number shortcut did not select in-progress"
    )
    form_state.open_calendar()
    assert(form_state.calendar_state and form_state.choose_calendar_date)
    local calendar_lines = vim.api.nvim_buf_get_lines(form_state.transient.bufnr, 0, -1, false)
    for _, line in ipairs(calendar_lines) do
      assert(vim.fn.strdisplaywidth(line) <= 32, "calendar line exceeds popup width: " .. line)
    end
    local expected_deadline = form_state.calendar_state:value()
    form_state.choose_calendar_date()
    assert(
      vim.wait(100, function()
        return form_state.state:get("deadline") == expected_deadline
      end),
      "calendar did not update the deadline field"
    )
    local deadline_date = assert(expected_deadline:match("^(%d%d%d%d%-%d%d%-%d%d)"))
    form_state.open_time_picker(require("todo.ui.calendar_state").new(expected_deadline))
    assert(form_state.time_state and form_state.apply_time, "arbitrary time picker did not open")
    for _, line in ipairs(vim.api.nvim_buf_get_lines(form_state.transient.bufnr, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) <= 44, "time picker line exceeds popup width: " .. line)
    end
    for _, digit in ipairs({ 0, 7, 4, 3 }) do
      form_state.time_state:input_digit(digit)
    end
    form_state.apply_time()
    assert(
      vim.wait(100, function()
        return form_state.state:get("deadline") == deadline_date .. " 07:43"
      end),
      "time picker did not accept arbitrary HHMM input"
    )
    assert(form_state.components.quick == nil, "removed quick-deadline row is still mounted")
    for _, component in pairs(form_state.components) do
      for _, mode in ipairs({ "n", "i" }) do
        for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(component.bufnr, mode)) do
          assert(mapping.lhs ~= "<LeftMouse>", "form must not register mouse mappings")
        end
      end
    end
    vim.api.nvim_set_current_win(form_state.components.tag_input.winid)
    local tag_prompt = vim.api.nvim_buf_get_lines(form_state.components.tag_chips.bufnr, 1, 2, false)[1]
    assert(tag_prompt:find("choose existing", 1, true), "tag panel keyboard path is not visible")
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(form_state.components.tag_input.bufnr, "i")) do
      assert(mapping.lhs ~= "<Esc>", "Escape must retain its native Insert-mode meaning")
    end
    form_state.open_tag_panel()
    local tag_panel = require("todo.ui.tag_panel")
    assert(tag_panel.is_open() and #tag_panel.inspect_state().visible >= 2, "tag selector panel did not open")
    local tag_panel_state = tag_panel.inspect_state()
    local panel_keys = {}
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(tag_panel_state.popup.bufnr, "n")) do
      assert(mapping.lhs ~= "<LeftMouse>", "tag panel must not register mouse mappings")
      panel_keys[mapping.lhs] = true
    end
    for _, key in ipairs({ "a", "r", "d", "/", "q", " " }) do
      assert(panel_keys[key], "tag panel is missing action mapping: " .. key)
    end
    local tag_panel_width = vim.api.nvim_win_get_width(tag_panel_state.popup.winid)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(tag_panel_state.popup.bufnr, 0, -1, false)) do
      assert(vim.fn.strdisplaywidth(line) <= tag_panel_width, "tag panel line exceeds its width: " .. line)
    end
    tag_panel_state.toggle_current()
    assert(
      vim.wait(100, function()
        return vim.deep_equal(form_state.state:get("tags"), { "existing" })
      end),
      "tag panel did not select the focused tag"
    )
    tag_panel_state.toggle_current()
    assert(
      vim.wait(100, function()
        return vim.deep_equal(form_state.state:get("tags"), {})
      end),
      "tag panel did not deselect the focused tag"
    )
    tag_panel.close()
    vim.wait(20)
    vim.api.nvim_buf_set_lines(form_state.components.tag_input.bufnr, 0, -1, false, { "fresh" })
    vim.api.nvim_win_set_cursor(form_state.components.tag_input.winid, { 1, 5 })
    vim.wait(20)
    vim.bo[form_state.components.tag_input.bufnr].modifiable = false
    form_state.commit_tag()
    assert(
      vim.wait(100, function()
        return vim.deep_equal(form_state.state:get("tags"), { "fresh" })
          and vim.bo[form_state.components.tag_input.bufnr].modifiable
      end),
      "typing and committing a tag did not update the structured form: "
        .. vim.inspect({
          tags = form_state.state:get("tags"),
          input = vim.api.nvim_buf_get_lines(form_state.components.tag_input.bufnr, 0, -1, false),
        })
    )
    vim.api.nvim_set_current_win(form_state.components.description.winid)
    vim.api.nvim_buf_set_lines(form_state.components.description.bufnr, 0, -1, false, { "first line", "second line" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = form_state.components.description.bufnr })
    assert(
      vim.wait(100, function()
        return form_state.state:get("description") == "first line\nsecond line"
      end),
      "multi-line description input did not preserve newlines"
    )
    form.close(true)
    eq(form.inspect_state(), nil)
    assert(vim.wait(100, function()
      return close_reason ~= nil
    end))
    eq(close_reason, "forced")
    package.loaded.todo = nil
  end)
else
  skip("NUI dashboard and form", "nui.nvim is not on runtimepath")
end

local sqlite_ok = pcall(require, "sqlite.db")
if sqlite_ok then
  test("SQLite migrations and CRUD", function()
    local path = vim.fn.tempname() .. ".db"
    local store = require("todo.store").open(path)
    local service = require("todo.service").new(store)
    eq(store:list({ archived = false }), {})
    eq(service:stats(), { active = 0, emergency = 0, archived = 0 })
    local created = assert(service:create({
      title = "Persist",
      description = "db",
      status = "todo",
      priority = "P1",
      deadline = "2026-08-03",
      tags = { "SQLite", "nvim" },
    }))
    eq(store:get(created.id).tags, { "nvim", "SQLite" })
    eq(service:list_tags(), { "nvim", "SQLite" })
    eq(service:tag_stats(), {
      { name = "nvim", task_count = 1 },
      { name = "SQLite", task_count = 1 },
    })
    eq(service:create_tag("merged"), "merged")
    eq(service:rename_tag("SQLite", "merged"), "merged")
    eq(store:get(created.id).tags, { "merged", "nvim" })
    assert(service:delete_tag("merged"))
    eq(store:get(created.id).tags, { "nvim" })
    eq(service:stats(), { active = 1, emergency = 1, archived = 0 })
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
    local disposable = assert(service:create({ title = "Delete me", priority = "P3", tags = { "temporary" } }))
    local active_delete, active_delete_error = service:delete_archived(disposable.id)
    eq(active_delete, nil)
    eq(active_delete_error, { archived = "required" })
    assert(service:archive(disposable.id))
    assert(service:delete_archived(disposable.id))
    eq(store:get(disposable.id), nil)
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
