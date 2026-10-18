-- NUI integration tests for the postpone (normal `p`) action.
-- Run with: nvim --clean --headless --cmd 'set runtimepath+=.' -l spec/postpone_ui.lua
--
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

-- ---------------------------------------------------------------------------
-- Shared fixtures
-- ---------------------------------------------------------------------------

local BASE = os.time()

local function task(overrides)
    local value = {
        id = 1,
        kind = "task",
        title = "Overdue task",
        description = "desc",
        status = "todo",
        priority = 2,
        tags = {},
        due_date = os.date("%Y-%m-%d", BASE - 86400),
        due_time = "09:00",
        created_at = BASE - 100000,
        updated_at = BASE - 100000,
        sync_revision = "1",
    }
    for key, item in pairs(overrides or {}) do
        value[key] = item
    end
    return value
end

local function deadline_epoch(t)
    if not t.due_date or not t.due_time then
        return nil
    end
    local y, m, d = t.due_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local hh, mm = t.due_time:match("^(%d%d):(%d%d)$")
    if not (y and hh) then
        return nil
    end
    return os.time({
        year = tonumber(y),
        month = tonumber(m),
        day = tonumber(d),
        hour = tonumber(hh),
        min = tonumber(mm),
        sec = 0,
    })
end

-- In-memory store with the subset of the real store API the service and panel
-- touch, including revision-checked update and a write counter.
local function make_store(tasks)
    local records, order = {}, {}
    for _, value in ipairs(tasks) do
        records[value.id] = vim.deepcopy(value)
        order[#order + 1] = value.id
    end
    local store = { writes = 0 }

    function store:list(opts)
        local archived = opts and opts.archived == true
        local out = {}
        for _, id in ipairs(order) do
            local value = records[id]
            if value and (value.archived_at ~= nil) == archived then
                out[#out + 1] = vim.deepcopy(value)
            end
        end
        return out
    end

    function store:get(id)
        return records[id] and vim.deepcopy(records[id]) or nil
    end

    function store:update(id, value, expected_revision)
        local current = records[id]
        if not current then
            return nil
        end
        if expected_revision ~= nil and current.sync_revision ~= expected_revision then
            return nil
        end
        local updated = vim.deepcopy(value)
        updated.id = id
        updated.created_at = current.created_at
        updated.sync_revision = tostring((tonumber(current.sync_revision) or 0) + 1)
        updated.updated_at = os.time()
        records[id] = updated
        store.writes = store.writes + 1
        return vim.deepcopy(updated)
    end

    function store:set_status(id, status)
        local current = records[id]
        if not current then
            return nil
        end
        current.status = status
        current.sync_revision = tostring((tonumber(current.sync_revision) or 0) + 1)
        store.writes = store.writes + 1
        return vim.deepcopy(current)
    end

    function store:list_tags()
        return {}
    end

    function store:stats()
        local active, archived = 0, 0
        for _, id in ipairs(order) do
            if records[id] and records[id].archived_at then
                archived = archived + 1
            elseif records[id] then
                active = active + 1
            end
        end
        return { active = active, emergency = active, archived = archived, notices = 0 }
    end

    -- Test hooks: simulate a concurrent editor (revision bump) or a deletion.
    function store:bump(id)
        local current = records[id]
        current.sync_revision = tostring((tonumber(current.sync_revision) or 0) + 1)
    end

    function store:remove(id)
        records[id] = nil
    end

    return store
end

local SERVICE
local RECONCILE

local function reload_panel()
    package.loaded["todo.ui.panel"] = nil
    package.loaded.todo = {
        _service = function()
            return SERVICE
        end,
        _reconcile_reminders = function()
            RECONCILE = RECONCILE + 1
        end,
        _reschedule_reminders = function()
            RECONCILE = RECONCILE + 1
        end,
    }
    return require("todo.ui.panel")
end

local function scenario(tasks, opts)
    vim.cmd("stopinsert")
    local store = make_store(tasks)
    SERVICE = require("todo.service").new(store)
    RECONCILE = 0
    local panel = reload_panel()
    panel.open(vim.tbl_extend("force", { mode = "float", view = "active" }, opts or {}))
    vim.wait(40)
    local owner = panel.inspect_state().owner
    vim.api.nvim_set_current_win(owner.split and owner.split.winid or owner.list.winid)
    return store, SERVICE, panel
end

-- ---------------------------------------------------------------------------
-- Input/transient helpers
-- ---------------------------------------------------------------------------

local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function transient(panel)
    local owner = panel.inspect_state().owner
    local t = owner and owner.transient
    if t and t.bufnr and vim.api.nvim_buf_is_valid(t.bufnr) then
        return t
    end
    return nil
end

local function wait_transient(panel, timeout)
    local ok = vim.wait(timeout or 500, function()
        local input = transient(panel)
        return input ~= nil and vim.api.nvim_get_current_win() == input.winid
    end, 10)
    return ok and transient(panel) or nil
end

local function input_lines(component)
    return vim.api.nvim_buf_get_lines(component.bufnr, 0, -1, false)
end

local function set_input(component, value)
    vim.api.nvim_set_current_win(component.winid)
    vim.bo[component.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, { value })
end

local function submit(component)
    vim.api.nvim_set_current_win(component.winid)
    vim.cmd("startinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
end

local function leave_insert()
    vim.cmd("stopinsert")
end

local function list_win(panel)
    local owner = panel.inspect_state().owner
    return owner.list and owner.list.winid or (owner.split and owner.split.winid)
end

local function press_postpone(panel)
    vim.api.nvim_set_current_win(list_win(panel))
    press("p")
end

local function assert_deadline_near(updated, delta, t0, t1, label)
    local epoch = deadline_epoch(updated)
    assert(epoch, (label or "postpone") .. " should set a concrete deadline, got " .. vim.inspect(updated))
    assert(
        epoch >= t0 + delta - 1 and epoch <= t1 + delta + 60,
        string.format(
            "%s deadline %d out of expected [%d, %d]",
            label or "postpone",
            epoch,
            t0 + delta - 1,
            t1 + delta + 60
        )
    )
    eq(epoch % 60, 0, (label or "postpone") .. " deadline should land on a whole minute")
end

-- ---------------------------------------------------------------------------
-- Feature probe: skip cleanly while the panel has no normal `p` mapping.
-- ---------------------------------------------------------------------------

require("todo.config").setup({
    keymaps = { toggle = false },
    ui = { default_mode = "float", default_view = "active" },
})

if not pcall(require, "nui.popup") then
    skip("NUI postpone integration", "nui.nvim not available")
    print(string.format("\n%d passed, %d failed, %d skipped", passed, failed, skipped))
    vim.cmd("qa!")
    os.exit(0)
end

-- ---------------------------------------------------------------------------

test("p opens a NUI input defaulting to 1d and Enter postpones", function()
    local store, _, panel = scenario({ task() })
    eq(panel.inspect_state().selected_id, 1, "overdue task should be selected")
    press_postpone(panel)
    local input = assert(wait_transient(panel), "p should open the postpone input")
    eq(input_lines(input), { "1d" }, "input should default to 1d")
    eq(vim.api.nvim_get_current_win(), input.winid)

    local t0 = os.time()
    submit(input)
    assert(vim.wait(600, function()
        return store.writes > 0
    end), "Enter should submit the default duration")
    local t1 = os.time()
    assert_deadline_near(store:get(1), 86400, t0, t1, "default 1d")
    assert(RECONCILE >= 1, "a successful postpone should call init._reconcile_reminders")
    assert(panel.is_open(), "panel should stay open after a successful postpone")
    panel.close()
end)

test("custom positive duration now+value rounded up to the minute", function()
    local store, _, panel = scenario({ task() })
    press_postpone(panel)
    local input = assert(wait_transient(panel))
    set_input(input, "2h")
    local t0 = os.time()
    submit(input)
    assert(vim.wait(600, function()
        return store.writes > 0
    end), "custom duration should submit")
    local t1 = os.time()
    assert_deadline_near(store:get(1), 7200, t0, t1, "custom 2h")
    assert(RECONCILE >= 1, "custom postpone should reconcile reminders")
    panel.close()
end)

test("in_progress overdue tasks are postponable too", function()
    local store, _, panel = scenario({ task({ status = "in_progress" }) })
    press_postpone(panel)
    local input = assert(wait_transient(panel))
    submit(input)
    assert(vim.wait(600, function()
        return store.writes > 0
    end), "in_progress task should postpone")
    panel.close()
end)

test("cancel via Esc, Ctrl-q and q writes nothing and restores the origin", function()
    for _, keys in ipairs({ "<Esc>", "<C-q>", "q" }) do
        local store, _, panel = scenario({ task() })
        local before = store:get(1)
        local origin = vim.api.nvim_get_current_win()
        press_postpone(panel)
        local input = assert(wait_transient(panel), keys .. ": input should open")
        if keys == "q" then
            leave_insert()
        end
        press(keys)
        assert(vim.wait(400, function()
            return transient(panel) == nil
        end), keys .. " should close the postpone input")
        eq(store:get(1), before, keys .. " must not write")
        eq(store.writes, 0, keys .. " must not write")
        assert(vim.wait(200, function()
            return vim.api.nvim_get_current_win() == origin
        end), keys .. " should restore the originating window")
        panel.close()
    end
end)

test("invalid duration writes nothing and reopens prefilled", function()
    local store, _, panel = scenario({ task() })
    local before = store:get(1)
    press_postpone(panel)
    local input = assert(wait_transient(panel))
    set_input(input, "0m")
    submit(input)
    assert(vim.wait(600, function()
        local reopened = transient(panel)
        return reopened ~= nil and input_lines(reopened)[1] == "0m"
    end), "invalid duration should reopen the input prefilled with the bad value")
    eq(store:get(1), before, "invalid duration must not write")
    eq(store.writes, 0, "invalid duration must not write")
    panel.close()
end)

test("header has no postpone action", function()
    local store, _, panel = scenario({ task() })
    local header = assert(panel.inspect_state().owner.header, "float layout should expose a header")
    local before = store:get(1)
    vim.api.nvim_set_current_win(header.winid)
    eq(vim.fn.maparg("p", "n", false, true), {}, "header must not bind p")
    eq(transient(panel), nil, "p on the header must not open the postpone input")
    eq(store.writes, 0, "p on the header must not write")
    eq(store:get(1), before)
    panel.close()
end)

test("section cursor must not postpone the last selected task", function()
    local store, _, panel = scenario({ task() })
    local before = store:get(1)
    press("gg")
    local state = panel.inspect_state()
    eq(state.rows[state.cursor_row].kind, "section")
    eq(state.selected_id, 1)
    press("p")
    vim.wait(40)
    eq(transient(panel), nil)
    eq(store:get(1), before)
    eq(store.writes, 0)
    panel.close()
end)

test("future, completed and deadline-less tasks open no input", function()
    local cases = {
        { name = "future deadline", value = task({ due_date = os.date("%Y-%m-%d", BASE + 3 * 86400) }) },
        { name = "completed task", value = task({ status = "done" }) },
        { name = "cancelled task", value = task({ status = "cancelled" }) },
        { name = "no deadline", value = (function()
            local value = task()
            value.due_date, value.due_time = nil, nil
            return value
        end)() },
    }
    for _, case in ipairs(cases) do
        local store, _, panel = scenario({ case.value })
        local before = store:get(1)
        press_postpone(panel)
        vim.wait(150)
        eq(transient(panel), nil, case.name .. " must not open the postpone input")
        eq(store.writes, 0, case.name .. " must not write")
        eq(store:get(1), before)
        panel.close()
    end
end)

test("detail actions change with completed and active task states", function()
    for _, initial in ipairs({ "done", "cancelled" }) do
        local store, _, panel = scenario({ task({ status = initial }) })
        press("<CR>")
        local owner = panel.inspect_state().owner
        local overlay = assert(owner.detail_overlay)
        local function text()
            return table.concat(vim.api.nvim_buf_get_lines(overlay.bufnr, 0, -1, false), "\n")
        end
        assert(text():find("`s`", 1, true) and text():find("`x`", 1, true))
        assert(not text():find("`p`", 1, true))
        press("x")
        eq(store:get(1).status, "todo", "completed item x reopens as todo")
        press("s")
        eq(store:get(1).status, "in_progress")
        assert(text():find("`p`", 1, true), "overdue active task should offer postpone")
        assert(text():find("`s`", 1, true), "in progress s offers return to todo")
        press("u")
        eq(store:get(1).status, "todo")
        assert(text():find("`s`", 1, true) and not text():find("`u`", 1, true))
        panel.close()
    end
end)

test("revision conflict captured on open is refused without writing", function()
    local store, _, panel = scenario({ task() })
    press_postpone(panel)
    local input = assert(wait_transient(panel))
    store:bump(1)
    local concurrent = store:get(1)
    submit(input)
    vim.wait(300)
    eq(store:get(1), concurrent, "a stale revision must not overwrite the newer record")
    eq(store.writes, 0, "conflict must not write")
    assert(panel.is_open(), "panel should remain usable after a conflict")
    panel.close()
end)

test("deleting the task while the input is open is refused without crashing", function()
    local store, _, panel = scenario({ task() })
    press_postpone(panel)
    local input = assert(wait_transient(panel))
    store:remove(1)
    submit(input)
    vim.wait(300)
    eq(store:get(1), nil, "deleted task must stay gone")
    eq(store.writes, 0)
    assert(panel.is_open(), "panel should survive a not_found submit")
    panel.close()
end)

test("sidebar, narrow float, fixed detail and overlay all originate the input", function()
    -- Sidebar
    local store, _, panel = scenario({ task() }, { mode = "sidebar" })
    local sidebar = assert(panel.inspect_state().owner.split)
    local origin = vim.api.nvim_get_current_win()
    eq(origin, sidebar.winid)
    press("p")
    local input = assert(wait_transient(panel), "sidebar p should open the input")
    eq(vim.api.nvim_get_current_win(), input.winid)
    press("<Esc>")
    assert(vim.wait(400, function()
        return transient(panel) == nil and vim.api.nvim_get_current_win() == sidebar.winid
    end), "sidebar cancel should restore the split window")
    eq(store.writes, 0)
    panel.close()

    -- Narrow float list
    local store2, _, panel2 = scenario({ task() })
    eq(panel2.inspect_state().owner.wide, false, "default float should be narrow")
    press_postpone(panel2)
    local input2 = assert(wait_transient(panel2), "narrow float p should open the input")
    press("<Esc>")
    assert(vim.wait(400, function()
        return transient(panel2) == nil and vim.api.nvim_get_current_win() == list_win(panel2)
    end), "narrow float cancel should restore the list window")
    eq(store2.writes, 0)
    panel2.close()

    -- Fixed detail pane (temporarily widen the editor so the float goes wide)
    local original_columns = vim.o.columns
    local columns_ok = pcall(function()
        vim.o.columns = 140
    end)
    if columns_ok then
        require("todo.config").setup({
            keymaps = { toggle = false },
            ui = { default_mode = "float", default_view = "active", float = { width = 0.9 } },
        })
        local store3, _, panel3 = scenario({ task() })
        local state3 = panel3.inspect_state()
        assert(state3.owner.wide, "expected a wide dashboard at 140 columns")
        local detail = assert(state3.owner.detail)
        press("l")
        eq(vim.api.nvim_get_current_win(), detail.winid, "l should focus the fixed detail pane")
        press("p")
        local input3 = assert(wait_transient(panel3), "detail p should open the input")
        submit(input3)
        assert(vim.wait(600, function()
            return store3.writes > 0
        end), "detail submit should postpone")
        assert(RECONCILE >= 1, "detail submit should reconcile reminders")
        local updated = store3:get(1)
        assert(vim.wait(300, function()
            local lines = vim.api.nvim_buf_get_lines(detail.bufnr, 0, -1, false)
            return vim.iter(lines):any(function(line)
                return line:find(updated.due_date, 1, true) ~= nil
            end)
        end), "successful postpone should refresh the detail pane with the new deadline")
        panel3.close()
        vim.o.columns = original_columns
        require("todo.config").setup({
            keymaps = { toggle = false },
            ui = { default_mode = "float", default_view = "active" },
        })
    else
        skip("fixed detail postpone", "cannot resize the headless editor")
    end

    -- Detail overlay from a narrow float
    local store4, _, panel4 = scenario({ task() })
    press("<CR>")
    local overlay = assert(vim.wait(300, function()
        return panel4.inspect_state().owner.detail_overlay ~= nil
    end) and panel4.inspect_state().owner.detail_overlay, "overlay should open")
    eq(vim.api.nvim_get_current_win(), overlay.winid)
    press("p")
    local input4 = assert(wait_transient(panel4), "overlay p should open the input")
    press("<Esc>")
    assert(vim.wait(400, function()
        return transient(panel4) == nil and vim.api.nvim_get_current_win() == overlay.winid
    end), "overlay cancel should restore the overlay window")
    eq(store4.writes, 0)
    panel4.close()
end)

print(string.format("\n%d passed, %d failed, %d skipped", passed, failed, skipped))
if failed > 0 then
    os.exit(1)
end
vim.cmd("qa!")
