-- Pure regression tests for todo.ui.actions and todo.ui.hints (no NUI/forms/scanning).
-- Both core modules must load successfully.
--   nvim --clean --headless --cmd "set runtimepath+=$PWD" -l spec/context_actions.lua

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local P, F, S = 0, 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        P = P + 1
        print("ok - " .. name)
    else
        F = F + 1
        print("not ok - " .. name .. "\n" .. err)
    end
end
local function skip(name, reason)
    S = S + 1
    print("skip - " .. name .. " (" .. reason .. ")")
end
local function truthy(v, msg)
    if not v then
        error(msg or "expected truthy", 2)
    end
end
local function falsy(v, msg)
    if v then
        error(msg or "expected falsy", 2)
    end
end
local function eq(a, b, msg)
    if not vim.deep_equal(a, b) then
        error((msg or "values differ") .. "\nexpected " .. vim.inspect(b) .. "\nactual " .. vim.inspect(a))
    end
end

local NOW = 1700000000 -- fixed clock; every case is wall-clock independent

local function make_task(o)
    o = o or {}
    local t = {
        id = o.id or 1,
        kind = o.kind or "task",
        title = o.title or "Sample task",
        status = o.status or "todo",
        priority = o.priority or 1,
        tags = o.tags or {},
        created_at = NOW - 10000,
        updated_at = NOW - 1000,
    }
    if o.archived then
        t.archived, t.archived_at = true, NOW - 100
    end
    if o.overdue then
        t.deadline, t.due_date, t.due_time = NOW - 3600, "2023-11-13", "00:00"
    elseif o.future then
        t.deadline, t.due_date, t.due_time = NOW + 86400, "2999-01-01", "12:00"
    end
    return t
end

local function by_key(ds, k)
    for _, d in ipairs(ds or {}) do
        if d.key == k then
            return d
        end
    end
end
local function sorted_keys(ds)
    local r = {}
    for _, d in ipairs(ds or {}) do
        r[#r + 1] = d.key
    end
    table.sort(r)
    return r
end
local function assert_shape(ds)
    truthy(ds and #ds > 0, "expected action descriptors")
    for _, d in ipairs(ds) do
        truthy(type(d.id) == "string" and d.id ~= "", "id must be a nonempty string")
        truthy(type(d.key) == "string" and d.key ~= "", "key must be a nonempty string")
        truthy(type(d.label) == "string" and d.label ~= "", "label missing for " .. tostring(d.id))
        truthy(d.group == nil or type(d.group) == "string", "group must be a string for " .. tostring(d.id))
        truthy(type(d.modes) == "table" and next(d.modes) ~= nil, "modes missing for " .. tostring(d.id))
    end
end
local function assert_matrix(ds, exp, label)
    assert_shape(ds)
    local set = {}
    for _, d in ipairs(ds) do
        set[d.key] = true
    end
    for _, k in ipairs(exp) do
        truthy(set[k], label .. " should offer '" .. k .. "' (got " .. vim.inspect(sorted_keys(ds)) .. ")")
    end
    eq(#ds, #exp, label .. " unexpected actions " .. vim.inspect(sorted_keys(ds)))
end

local actions = require("todo.ui.actions")
local hints = require("todo.ui.hints")
local ok_actions, ok_hints = true, true

if ok_actions then
    test("task_actions returns well-formed descriptors for every state", function()
        assert_matrix(actions.task_actions(make_task({ future = true }), NOW), { "e", "s", "x", "c", "A" }, "open")
        assert_matrix(
            actions.task_actions(make_task({ status = "in_progress", future = true }), NOW),
            { "e", "s", "x", "c", "A" },
            "in_progress"
        )
        for _, s in ipairs({ "done", "cancelled" }) do
            assert_matrix(
                actions.task_actions(make_task({ status = s, future = true }), NOW),
                { "e", "s", "x", "A" },
                s
            )
        end
        assert_matrix(
            actions.task_actions(make_task({ overdue = true }), NOW),
            { "e", "s", "x", "c", "A", "p" },
            "overdue"
        )
        assert_matrix(actions.task_actions(make_task({ archived = true }), NOW), { "e", "A", "D" }, "archived")
    end)

    test("notice actions take precedence over start/postpone", function()
        local open = actions.task_actions(make_task({ kind = "notice", overdue = true }), NOW)
        assert_matrix(open, { "e", "x", "A" }, "open notice")
        falsy(by_key(open, "p"), "open notice must not postpone")
        falsy(by_key(open, "s"), "open notice must not start")
        local closed = actions.task_actions(make_task({ kind = "notice", status = "done", overdue = true }), NOW)
        assert_matrix(closed, { "e", "A" }, "closed notice")
        falsy(by_key(closed, "p") or by_key(closed, "s") or by_key(closed, "x"), "closed notice extras")
    end)

    test("nil task yields no task actions", function()
        local result = actions.task_actions(nil, NOW)
        truthy(result == nil or #result == 0, "nil task must not produce actions")
    end)

    test("allowed mirrors descriptors and denies cross-state ids", function()
        local open, progress = make_task({ future = true }), make_task({ status = "in_progress", future = true })
        local overdue, archived = make_task({ overdue = true }), make_task({ archived = true })
        local closed, notice =
            make_task({ status = "done", future = true }), make_task({ kind = "notice", overdue = true })
        local id = function(state, key)
            return assert(by_key(actions.task_actions(state, NOW), key)).id
        end
        for _, state in ipairs({ open, progress, overdue, archived, closed, notice }) do
            for _, d in ipairs(actions.task_actions(state, NOW)) do
                eq(actions.allowed(state, d.id, NOW), true, "descriptor id must be allowed: " .. d.id)
            end
            eq(type(actions.allowed(state, "no-such-action", NOW)), "boolean")
        end
        eq(actions.allowed(archived, id(open, "s"), NOW), false, "archived cannot start")
        eq(actions.allowed(archived, id(open, "x"), NOW), false, "archived cannot complete")
        eq(actions.allowed(open, id(archived, "A"), NOW), false, "open cannot restore")
        eq(actions.allowed(open, id(archived, "D"), NOW), false, "open cannot delete")
        eq(actions.allowed(open, id(progress, "s"), NOW), false, "open cannot reopen")
        eq(actions.allowed(open, id(overdue, "p"), NOW), false, "future task cannot postpone")
        eq(actions.allowed(notice, id(open, "s"), NOW), false, "notice cannot start")
        eq(actions.allowed(notice, id(overdue, "p"), NOW), false, "notice cannot postpone")
        eq(actions.allowed(overdue, id(overdue, "p"), NOW), true, "overdue can postpone")
        eq(actions.allowed(progress, id(progress, "s"), NOW), true, "in_progress can reopen")
    end)
end

if ok_hints then
    local function sample_actions()
        return {
            { id = "edit", key = "e", label = "Edit", group = "modify", modes = { "n" } },
            { id = "start", key = "s", label = "Start", group = "state", modes = { "n" } },
            { id = "done", key = "x", label = "Complete", group = "state", modes = { "n" } },
            { id = "cancel", key = "c", label = "Cancel", group = "state", modes = { "n" } },
            { id = "archive", key = "A", label = "Archive", group = "storage", modes = { "n" } },
            { id = "postpone", key = "p", label = "Postpone", group = "time", modes = { "n" } },
        }
    end
    local function display(lines, width)
        for _, line in ipairs(lines) do
            truthy(vim.fn.strdisplaywidth(line) <= width, "line exceeds width: " .. line)
        end
    end

    test("hints.lines wraps within display width and keeps tokens intact", function()
        local lines = hints.lines(sample_actions(), 100, 5)
        truthy(#lines <= 5, "expected at most 5 lines")
        local joined = table.concat(lines, "\n")
        for _, d in ipairs(sample_actions()) do
            truthy(joined:find(d.label, 1, true), "label token was broken: " .. d.label)
        end
        truthy(joined:find("e", 1, true) and joined:find("p", 1, true), "keys must appear")
        display(lines, 100)
    end)

    test("hints.lines counts Unicode display width, not bytes", function()
        local actions = {
            { id = "edit", key = "e", label = "编辑", group = "modify", modes = { "n" } },
            { id = "done", key = "x", label = "完成", group = "state", modes = { "n" } },
            { id = "archive", key = "A", label = "归档", group = "storage", modes = { "n" } },
        }
        local lines = hints.lines(actions, 20, 3)
        display(lines, 20)
        for _, line in ipairs(lines) do
            eq(vim.fn.strwidth(line), vim.fn.strdisplaywidth(line), "wide chars counted as bytes: " .. line)
        end
    end)

    test("hints.lines adds a help fallback when the bar overflows", function()
        local lines = hints.lines(sample_actions(), 8, 3)
        truthy(#lines <= 3, "must honor max_lines on a small screen")
        display(lines, 8)
        local joined = table.concat(lines, "\n"):lower()
        truthy(joined:find("help", 1, true) or joined:find("?", 1, true), "expected a help fallback hint")
    end)

    test("hints.lines honors max_lines and stays readable", function()
        local lines = hints.lines(sample_actions(), 40, 1)
        truthy(#lines <= 1, "single-line budget must be respected")
        truthy(type(lines[1]) == "string" and #lines[1] > 0, "expected a nonempty hint line")
    end)
end

print(string.format("\n%d passed, %d failed, %d skipped", P, F, S))
if F > 0 then
    vim.cmd("cquit " .. F)
end
vim.cmd("qa!")
