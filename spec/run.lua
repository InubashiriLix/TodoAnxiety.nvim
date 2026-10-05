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
            (message or "values differ")
            .. "\nexpected: "
            .. vim.inspect(expected)
            .. "\nactual: "
            .. vim.inspect(actual)
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
    eq(cfg.ui.markdown, true, "markdown rendering should default to on")
    eq(config.setup({ ui = { markdown = false } }).ui.markdown, false)
    eq(pcall(config.setup, { ui = { markdown = "yes" } }), false)
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
    eq(commands.complete("by_", ":Todo open by_"), { "by_urgency", "by_time", "by_tag" })
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
        reminder_interval = "5m",
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

test("duration, recurrence, and notice model are deterministic", function()
    local duration = require("todo.duration")
    local recurrence = require("todo.recurrence")
    local model = require("todo.model")
    eq(duration.parse("30s"), 30)
    eq(duration.parse("5m"), 300)
    eq(duration.parse("2h"), 7200)
    eq(duration.parse("1d2h3m4s"), 93784)
    eq(duration.format(7200), "2h")
    eq(duration.format(93784), "1d2h3m4s")
    eq(duration.parse("soon"), nil)

    local monday = os.time({ year = 2026, month = 8, day = 3, hour = 9, min = 0, sec = 0 })
    eq(recurrence.next_after({ kind = "daily", every = 1 }, monday, monday), monday + 86400)
    eq(
        os.date("%Y-%m-%d", recurrence.next_after({ kind = "weekly", weekdays = { 2, 4 }, every = 1 }, monday, monday)),
        "2026-08-05"
    )
    eq(recurrence.next_after({ kind = "interval", every = 2, unit = "hours" }, monday, monday + 1), monday + 7200)

    local notice = assert(model.validate({
        kind = "notice",
        title = "Take a shower",
        trigger = "5m",
        reminder_interval = "2m",
        recurrence = { kind = "once" },
        now = monday,
    }))
    eq(notice.kind, "notice")
    eq(notice.reminder.scheduled_at, monday + 300)
    eq(notice.reminder.repeat_interval_seconds, 120)
end)

test("duration picker state normalizes all four units", function()
    local DurationState = require("todo.ui.duration_state")
    local state = DurationState.new("1d23h59m58s")
    eq(state:value(), 172798)
    state.field_index = 4
    state:move(5)
    eq(state:formatted(), "2d3s")
    state:move(-5)
    eq(state:formatted(), "1d23h59m58s")
    state.field_index = 2
    state:input_digit(2)
    state:input_digit(9)
    eq(state:formatted(), "2d5h59m58s")
end)

test("scheduler persists repeat time before presenting", function()
    local now = 1000
    local task = { id = 7, title = "Alarm", reminder = { repeat_interval_seconds = 300 } }
    local marked, presented, sounds = 0, 0, 0
    local service = {}
    function service:due_reminders(at)
        return at == now and { task } or {}
    end

    function service:mark_reminded(id, at)
        marked = marked + 1
        eq({ id, at }, { 7, now })
        return task
    end

    function service:next_reminder_time()
        return now + 300
    end

    local timer = { closing = false }
    function timer:stop() end

    function timer:start(delay)
        self.delay = delay
    end

    function timer:is_closing()
        return self.closing
    end

    function timer:close()
        self.closing = true
    end

    local callback
    local scheduler = require("todo.scheduler").new(service, {
        now = function()
            return now
        end,
        timer = timer,
        play_sound = function()
            sounds = sounds + 1
        end,
        presenter = function(_, done)
            presented = presented + 1
            callback = done
        end,
    })
    scheduler:start()
    eq(marked, 1)
    eq(presented, 1)
    eq(sounds, 1)
    eq(timer.delay, 300000)
    scheduler:tick()
    eq(marked, 1, "an open reminder must not be queued twice")
    eq(presented, 1)
    callback("dismiss")
    scheduler:stop()
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
    state:set("reminder_interval", "5m")
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
    eq(time:input_digit(9), true)
    eq(time:value(), "05:37")
    eq(time.day_offset, 1)

    local rollover = TimeState.new("2026-08-01 23:58")
    rollover.field = "minute"
    rollover:move(5)
    eq(rollover:value(), "00:03")
    eq(rollover.day_offset, 1)
    rollover:move(-5)
    eq(rollover:value(), "23:58")
    eq(rollover.day_offset, 0)
    rollover.field = "hour"
    rollover.hour = 0
    rollover.minute = 10
    rollover:move(-1)
    eq(rollover:value(), "23:10")
    eq(rollover.day_offset, -1)
end)

test("detail markdown keeps the description verbatim", function()
    require("todo.config").setup({})
    local markdown = require("todo.ui.markdown")
    local now = os.time()
    local task = {
        id = 1,
        kind = "task",
        title = "Fix login timeout",
        description = "Notes\n\n- [ ] reproduce\n- [x] grab logs\n\n```lua\nlocal t = 1\n```",
        status = "in_progress",
        priority = 1,
        due_date = "2099-01-02",
        due_time = "18:00",
        tags = { "backend", "auth" },
        created_at = now,
        updated_at = now,
    }
    local lines = markdown.task_lines(task)
    eq(lines[1], "# Fix login timeout")
    local function has(needle)
        return vim.iter(lines):any(function(line)
            return line:find(needle, 1, true) ~= nil
        end)
    end
    assert(has("**Status** In progress"), "expected a bold status field")
    assert(has("**Priority** P1"), "expected a bold priority field")
    assert(has("`#backend` `#auth`"), "expected tags as inline code")
    assert(has("## Description"), "expected a description heading")
    assert(vim.tbl_contains(lines, "---"), "expected a horizontal rule")
    -- The markdown a user typed must survive untouched: no escaping, no indent.
    assert(vim.tbl_contains(lines, "- [ ] reproduce"), "expected verbatim checkbox line")
    assert(vim.tbl_contains(lines, "```lua"), "expected verbatim code fence")
    assert(has("`e` Edit"), "expected a quoted action hint")
    local without_actions = markdown.task_lines(task, { actions = false })
    eq(without_actions[#without_actions]:sub(1, 1), "*", "actions = false should end on the timestamp line")

    local empty = markdown.task_lines({
        id = 2,
        title = "Bare",
        description = "",
        status = "todo",
        priority = 3,
        tags = {},
        created_at = now,
        updated_at = now,
    })
    assert(vim.tbl_contains(empty, "*No description*"), "expected an italic placeholder")

    eq(markdown.task_lines(nil), { "", "> " .. require("todo.i18n").t("no_tasks") })

    local notice = markdown.task_lines({
        id = 3,
        kind = "notice",
        title = "Shower",
        description = "",
        status = "todo",
        priority = 2,
        tags = {},
        created_at = now,
        updated_at = now,
        reminder = {
            scheduled_at = now,
            next_reminder_at = now,
            repeat_interval_seconds = 300,
            recurrence = { kind = "daily" },
        },
    })
    assert(
        vim.iter(notice):any(function(line)
            return line:find("**Trigger**", 1, true) ~= nil
        end),
        "expected the notice trigger field"
    )
    assert(
        vim.iter(notice):any(function(line)
            return line:find("5m", 1, true) ~= nil
        end),
        "expected the formatted repeat interval"
    )
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

test("grouping buckets tasks by urgency, time remaining, and tag", function()
    local grouping = require("todo.ui.grouping")
    require("todo.config").setup({ language = "en" })
    local now = os.time({ year = 2026, month = 8, day = 6, hour = 12 })
    local function at(offset)
        return os.date("%Y-%m-%d", now + offset)
    end
    local tasks = {
        {
            id = 1,
            title = "late",
            status = "todo",
            priority = 1,
            tags = { "work" },
            due_date = at(-3 * 86400),
        },
        { id = 2, title = "soon",   status = "in_progress", priority = 2, tags = { "work", "home" }, due_date = at(0) },
        {
            id = 3,
            title = "week",
            status = "todo",
            priority = 2,
            tags = {},
            due_date = at(4 * 86400),
        },
        {
            id = 4,
            title = "far",
            status = "todo",
            priority = 3,
            tags = { "home" },
            due_date = at(30 * 86400),
        },
        { id = 5, title = "nodate", status = "todo",        priority = 3, tags = {} },
    }

    local keys = function(sections)
        return vim.tbl_map(function(section)
            return section.key
        end, sections)
    end

    local by_time = grouping.sections(vim.deepcopy(tasks), "by_time", now)
    eq(keys(by_time), { "overdue", "today", "this_week", "later", "no_deadline" })

    local by_urgency = grouping.sections(vim.deepcopy(tasks), "by_urgency", now)
    eq(by_urgency[1].key, "overdue")
    -- Deadline-less tasks land in priority_only, urgency.calculate's label for them.
    eq(keys(by_urgency)[#by_urgency], "priority_only")

    local by_tag = grouping.sections(vim.deepcopy(tasks), "by_tag", now)
    eq(keys(by_tag), { "tag:home", "tag:work", "untagged" })
    -- A task with two tags appears under each of them.
    eq(
        vim.tbl_map(function(task)
            return task.title
        end, by_tag[1].tasks),
        { "soon", "far" }
    )
    eq(#by_tag[2].tasks, 2)
    eq(by_tag[1].depth, 1)

    local rows = grouping.rows(by_tag, { ["tag:home"] = true })
    eq(rows[1].kind, "section")
    eq(rows[1].collapsed, true)
    eq(rows[1].count, 2)
    -- Collapsed section contributes no task rows; the next row is the next header.
    eq(rows[2].kind, "section")
    eq(rows[2].key, "tag:work")
    eq(rows[3].kind, "task")
    eq(rows[3].section_key, "tag:work")

    eq(grouping.relative(now + 3 * 86400 + 4 * 3600, now), "in 3d 4h")
    eq(grouping.relative(now - 2 * 86400, now), "overdue 2d")
    eq(grouping.relative(nil, now), nil)
    assert(grouping.is_view("by_tag") and not grouping.is_view("nonsense"))
end)

test("urgency.rank keeps non-candidates that urgency.sort drops", function()
    local urgency = require("todo.urgency")
    local tasks = {
        { id = 1, title = "p3 no deadline", status = "todo", priority = 3 },
        { id = 2, title = "p0 no deadline", status = "todo", priority = 0 },
    }
    eq(#urgency.sort(vim.deepcopy(tasks)), 1)
    local ranked = urgency.rank(vim.deepcopy(tasks))
    eq(#ranked, 2)
    eq(ranked[1].title, "p0 no deadline")
    assert(ranked[1].urgency.score > ranked[2].urgency.score)
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
        { id = 4, title = "no due p2", status = "todo",        priority = 2, created_at = 4 },
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

test("service sorts the regrouped views and drops closed tasks", function()
    local now = os.time({ year = 2026, month = 8, day = 6, hour = 12 })
    local service = require("todo.service").new(memory_store({
        {
            id = 1,
            title = "b",
            description = "",
            status = "todo",
            priority = 2,
            tags = {},
            due_date = os.date("%Y-%m-%d", now + 5 * 86400),
        },
        {
            id = 2,
            title = "a",
            description = "",
            status = "todo",
            priority = 2,
            tags = {},
            due_date = os.date("%Y-%m-%d", now + 86400),
        },
        { id = 3, title = "c", description = "", status = "done",      priority = 0, tags = {} },
        { id = 4, title = "d", description = "", status = "cancelled", priority = 0, tags = {} },
        { id = 5, title = "e", description = "", status = "todo",      priority = 0, tags = {} },
    }))
    local titles = function(view)
        return vim.tbl_map(function(task)
            return task.title
        end, service:list(view, {}, now))
    end
    -- No deadline sorts last; done/cancelled never appear.
    eq(titles("by_time"), { "a", "b", "e" })
    -- by_tag orders by priority then title.
    eq(titles("by_tag"), { "e", "a", "b" })
    -- by_urgency keeps every open task, unlike the emergency view's filter.
    eq(#titles("by_urgency"), 3)
    eq(titles("by_urgency")[1], "a")
    -- Filters still apply on top of the new views.
    eq(titles("by_time"), { "a", "b", "e" })
    eq(
        vim.tbl_map(function(task)
            return task.title
        end, service:list("by_time", { search = "a" }, now)),
        { "a" }
    )
end)

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
        { id = 1, title = "Active",   archived_at = nil },
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
        local external_win = vim.api.nvim_get_current_win()
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

        vim.fn.feedkeys("/", "xt")
        assert(
            vim.wait(100, function()
                local transient = panel.inspect_state().owner.transient
                return transient ~= nil and vim.api.nvim_get_current_win() == transient.winid
            end),
            "search input did not open"
        )
        vim.api.nvim_set_current_win(panel.inspect_state().owner.list.winid)
        assert(
            vim.wait(100, function()
                return panel.is_open() and panel.inspect_state().owner.transient == nil
            end),
            "search input should close when focus returns to the dashboard"
        )

        vim.api.nvim_set_current_win(external_win)
        assert(
            vim.wait(100, function()
                return not panel.is_open()
            end),
            "floating dashboard should close whenever focus enters a regular window"
        )

        panel.open({ mode = "float", view = "active" })
        vim.fn.feedkeys("/", "xt")
        assert(
            vim.wait(100, function()
                local transient = panel.inspect_state().owner.transient
                return transient ~= nil and vim.api.nvim_get_current_win() == transient.winid
            end),
            "search input did not reopen"
        )
        vim.api.nvim_set_current_win(external_win)
        assert(
            vim.wait(100, function()
                return not panel.is_open()
            end),
            "floating dashboard should close when search focus leaves todo.nvim"
        )

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
        vim.fn.feedkeys("/", "xt")
        assert(
            vim.wait(100, function()
                local transient = panel.inspect_state().owner.transient
                return transient ~= nil and vim.api.nvim_get_current_win() == transient.winid
            end),
            "sidebar search input did not open"
        )
        vim.api.nvim_set_current_win(external_win)
        assert(
            vim.wait(100, function()
                return panel.is_open() and panel.inspect_state().owner.transient == nil
            end),
            "sidebar should remain while its unfocused search input closes"
        )
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

    test("NUI dashboard folds tag sections and Esc unwinds search and filters", function()
        require("todo.config").setup({ keymaps = { toggle = false }, ui = { default_mode = "float" } })
        local fake_service = require("todo.service").new(memory_store({
            {
                id = 1,
                title = "Alpha",
                description = "",
                status = "todo",
                priority = 1,
                tags = { "work" },
                created_at = 1,
            },
            {
                id = 2,
                title = "Beta",
                description = "",
                status = "todo",
                priority = 2,
                tags = { "home" },
                created_at = 2,
            },
        }))
        package.loaded.todo = {
            _service = function()
                return fake_service
            end,
        }
        package.loaded["todo.ui.panel"] = nil
        local panel = require("todo.ui.panel")
        panel.open({ mode = "float", view = "by_tag" })
        vim.wait(20)
        local state = panel.inspect_state()
        eq(state.view, "by_tag")
        eq(
            vim.tbl_map(function(row)
                return row.kind == "section" and row.key or row.task.title
            end, state.rows),
            { "tag:home", "Beta", "tag:work", "Alpha" }
        )
        -- Cursor starts on the first task row, not the section header.
        eq(state.cursor_row, 2)
        eq(state.selected_id, 2)

        local list_win = state.owner.list.winid
        vim.api.nvim_set_current_win(list_win)
        -- Tab folds the section holding the highlighted task and lands on its header.
        vim.fn.feedkeys("\t", "xt")
        vim.wait(20)
        eq(panel.inspect_state().collapsed.by_tag["tag:home"], true)
        eq(panel.inspect_state().cursor_row, 1)
        eq(
            vim.tbl_map(function(row)
                return row.kind == "section" and row.key or row.task.title
            end, panel.inspect_state().rows),
            { "tag:home", "tag:work", "Alpha" }
        )
        local folded_lines = vim.api.nvim_buf_get_lines(panel.inspect_state().owner.list.bufnr, 0, -1, false)
        assert(
            vim.iter(folded_lines):any(function(line)
                return line:find("▸", 1, true) ~= nil
            end),
            "collapsed marker missing"
        )
        assert(not vim.iter(folded_lines):any(function(line)
            return line:find("Beta", 1, true) ~= nil
        end), "collapsed section still shows its tasks")

        vim.fn.feedkeys("zR", "xt")
        vim.wait(20)
        eq(panel.inspect_state().collapsed.by_tag["tag:home"], nil)
        vim.fn.feedkeys("zM", "xt")
        vim.wait(20)
        eq(#panel.inspect_state().rows, 2)

        -- Esc in the search input clears the query and returns focus to the list.
        vim.fn.feedkeys("zR", "xt")
        vim.wait(20)
        vim.fn.feedkeys("/", "xt")
        assert(
            vim.wait(100, function()
                local transient = panel.inspect_state().owner.transient
                return transient ~= nil and vim.api.nvim_get_current_win() == transient.winid
            end),
            "search input did not open"
        )
        vim.cmd("startinsert")
        vim.fn.feedkeys("Alpha", "xt")
        assert(
            vim.wait(100, function()
                local search = panel.inspect_state().filters.search
                return search ~= nil and search ~= ""
            end),
            "typing did not populate the search filter"
        )
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
        assert(
            vim.wait(200, function()
                return panel.is_open()
                    and panel.inspect_state().owner.transient == nil
                    and panel.inspect_state().filters.search == nil
            end),
            "Esc should drop the search input and clear the query"
        )
        eq(vim.api.nvim_get_current_win(), panel.inspect_state().owner.list.winid)

        -- Esc on the list clears remaining filters before it closes the panel.
        panel.inspect_state().filters.tag = "work"
        panel.refresh()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
        vim.wait(30)
        assert(panel.is_open(), "first Esc should clear filters, not close")
        eq(panel.inspect_state().filters, {})
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
        assert(
            vim.wait(200, function()
                return not panel.is_open()
            end),
            "second Esc should close the dashboard"
        )
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
        vim.api.nvim_set_current_win(form_state.components.title.winid)
        vim.cmd("startinsert")
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt")
        assert(
            vim.wait(100, function()
                return form.inspect_state() == form_state
                    and vim.api.nvim_get_current_win() == form_state.components.priority.winid
            end),
            "Enter in the task title did not advance focus"
        )
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
        vim.api.nvim_buf_set_lines(
            form_state.components.description.bufnr,
            0,
            -1,
            false,
            { "first line", "second line" }
        )
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

    test("NUI notice form and forced reminder popup are keyboard driven", function()
        local fake_service = require("todo.service").new(memory_store({}))
        local notice_form = require("todo.ui.notice_form")
        local saved
        notice_form.open({}, function(input)
            saved = assert(fake_service:create(input))
            return saved
        end, { default_interval = "5m" })
        local state = assert(notice_form.inspect_state())
        assert(state.components.trigger and state.components.interval and state.components.recurrence)
        vim.api.nvim_set_current_win(state.components.title.winid)
        vim.cmd("startinsert")
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt")
        assert(
            vim.wait(100, function()
                return notice_form.inspect_state() == state
                    and vim.api.nvim_get_current_win() == state.components.trigger.winid
            end),
            "Enter in a single-line notice field did not advance focus"
        )

        state.open_duration_picker()
        assert(state.duration_picker and state.transient, "repeat interval picker did not open")
        local duration_marks = vim.api.nvim_buf_get_extmarks(state.transient.bufnr, state.transient.ns_id, 0, -1, {})
        assert(#duration_marks == 4, "repeat interval picker did not render four selectable units")
        state.duration_picker.state.days = 0
        state.duration_picker.state.hours = 0
        state.duration_picker.state.minutes = 1
        state.duration_picker.state.seconds = 30
        state.duration_picker.apply()
        eq(state.fields.reminder_interval, "1m30s")
        assert(state.transient == nil)

        state.open_calendar()
        assert(state.calendar_state and state.transient, "notice calendar did not open")
        local calendar_marks = vim.api.nvim_buf_get_extmarks(state.transient.bufnr, state.transient.ns_id, 0, -1, {})
        assert(#calendar_marks > 0, "notice calendar did not highlight its selected date")
        vim.fn.feedkeys("q", "xt")
        assert(vim.wait(100, function()
            return state.transient == nil
        end))

        state.open_calendar(true)
        assert(state.time_state and state.transient, "direct time picker did not open for today's date")
        local time_marks = vim.api.nvim_buf_get_extmarks(state.transient.bufnr, state.transient.ns_id, 0, -1, {})
        assert(#time_marks >= 3, "notice time picker did not highlight date/hour/minute fields")
        vim.fn.feedkeys("q", "xt")
        assert(vim.wait(100, function()
            return state.transient == nil
        end))

        state.fields.title = "Take a shower"
        state.fields.trigger = "5m"
        state.fields.reminder_interval = "2m"
        state.fields.recurrence = "interval"
        state.fields.recurrence_spec = "1h"
        state.save()
        assert(
            vim.wait(100, function()
                return notice_form.inspect_state() == nil and saved ~= nil
            end),
            "notice form did not save"
        )
        eq(saved.kind, "notice")
        eq(saved.reminder.repeat_interval_seconds, 120)
        eq(saved.reminder.recurrence, { kind = "interval", every = 1, unit = "hours", weekdays = {} })

        local origin_win = vim.api.nvim_get_current_win()
        local action
        local reminder_popup = require("todo.ui.reminder_popup")
        reminder_popup.show(saved, function(value)
            action = value
        end)
        assert(
            vim.wait(100, function()
                local popup_state = reminder_popup.inspect_state()
                return popup_state and vim.api.nvim_get_current_win() == popup_state.component.winid
            end),
            "reminder popup did not force focus"
        )
        vim.fn.feedkeys("q", "xt")
        assert(
            vim.wait(100, function()
                return action == "dismiss" and reminder_popup.inspect_state() == nil
            end),
            "reminder popup did not dismiss"
        )
        eq(vim.api.nvim_get_current_win(), origin_win)
    end)
else
    skip("NUI dashboard and form", "nui.nvim is not on runtimepath")
end

local sqlite_ok = pcall(require, "sqlite.db")
if sqlite_ok then
    test("SQLite v1 databases migrate to sync schema v3", function()
        local path = vim.fn.tempname() .. ".db"
        local sqlite = require("sqlite.db")
        local db = sqlite:open(path)
        db:execute([[CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)]])
        db:eval("INSERT INTO schema_migrations(version, applied_at) VALUES(1, :now)", { now = os.time() })
        db:execute([[CREATE TABLE tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'todo',
      priority INTEGER NOT NULL DEFAULT 2, due_date TEXT, due_time TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      completed_at INTEGER, archived_at INTEGER
    )]])
        db:execute([[CREATE TABLE tags (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)]])
        db:execute([[CREATE TABLE task_tags (task_id INTEGER NOT NULL, tag_id INTEGER NOT NULL,
      PRIMARY KEY(task_id, tag_id))]])
        db:eval([[INSERT INTO tasks(title, created_at, updated_at) VALUES('Legacy', :now, :now)]], { now = os.time() })
        db:close()

        local store = require("todo.store").open(path)
        local legacy = assert(store:get(1))
        eq(legacy.kind, "task")
        eq(legacy.reminder, nil)
        local version = store.db:eval("SELECT MAX(version) AS version FROM schema_migrations")[1]
        eq(tonumber(version.version), 3)
        local backups = vim.fn.glob(path .. ".pre-sync-*.db", false, true)
        eq(#backups, 1)
        local backup = sqlite:open(backups[1])
        eq(backup:eval("SELECT title FROM tasks")[1].title, "Legacy")
        eq(tonumber(backup:eval("SELECT MAX(version) AS version FROM schema_migrations")[1].version), 1)
        backup:close()
        os.remove(backups[1])
        store:close()
        for _, suffix in ipairs({ "", "-wal", "-shm" }) do
            os.remove(path .. suffix)
        end
    end)

    test("SQLite migrations and CRUD", function()
        local path = vim.fn.tempname() .. ".db"
        local store = require("todo.store").open(path)
        local service = require("todo.service").new(store)
        eq(store:list({ archived = false }), {})
        eq(service:stats(), { active = 0, emergency = 0, notices = 0, archived = 0 })
        local created = assert(service:create({
            title = "Persist",
            description = "db",
            status = "todo",
            priority = "P1",
            deadline = "2026-08-03",
            reminder_interval = "5m",
            tags = { "SQLite", "nvim" },
        }))
        eq(store:get(created.id).tags, { "nvim", "SQLite" })
        eq(service:list_tags(), { "nvim", "SQLite" })
        eq(service:tag_stats(), {
            { name = "nvim",   task_count = 1 },
            { name = "SQLite", task_count = 1 },
        })
        eq(service:create_tag("merged"), "merged")
        eq(service:rename_tag("SQLite", "merged"), "merged")
        eq(store:get(created.id).tags, { "merged", "nvim" })
        assert(service:delete_tag("merged"))
        eq(store:get(created.id).tags, { "nvim" })
        eq(service:stats(), { active = 1, emergency = 1, notices = 0, archived = 0 })
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
        local notice_now = os.time({ year = 2026, month = 8, day = 3, hour = 10, min = 0, sec = 0 })
        local notice = assert(service:create({
            kind = "notice",
            title = "Shower",
            trigger = "5m",
            reminder_interval = "2m",
            recurrence = { kind = "interval", every = 1, unit = "hours" },
            now = notice_now,
        }))
        eq(notice.kind, "notice")
        eq(notice.reminder.scheduled_at, notice_now + 300)
        eq(service:stats(), { active = 2, emergency = 0, notices = 1, archived = 0 })
        eq(service:due_reminders(notice_now + 299), {})
        eq(service:due_reminders(notice_now + 300)[1].id, notice.id)
        local reminded = assert(service:mark_reminded(notice.id, notice_now + 300))
        eq(reminded.reminder.next_reminder_at, notice_now + 420)
        local advanced = assert(service:complete_reminder(notice.id, notice_now + 301))
        eq(advanced.reminder.scheduled_at, notice_now + 3900)
        eq(service:last_reminder_interval(), 120)
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
