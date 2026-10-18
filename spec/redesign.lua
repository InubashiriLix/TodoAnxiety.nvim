package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local config = require("todo.config")
config.setup({
    language = "zh-CN",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-redesign-key" },
})
local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local planner = require("todo.planning").new(ws, svc)
local memory = require("todo.memory").new(ws, svc)
local P, F = 0, 0
local reports = {}
vim.notify = function() end
local function test(name, fn)
    local ok, e = xpcall(fn, debug.traceback)
    if ok then
        P = P + 1
        reports[#reports + 1] = "ok - " .. name
    else
        F = F + 1
        reports[#reports + 1] = "not ok - " .. name .. "\n" .. e
    end
end
local function press(k)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt")
    vim.wait(35)
end
local function resize(w, h)
    vim.o.columns = w
    vim.o.lines = h
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.wait(80)
end
local function response(value)
    return {
        choices = { { finish_reason = "stop", message = { content = vim.json.encode(value) } } },
        usage = { prompt_tokens = 10, completion_tokens = 5 },
    }
end
local task =
    assert(svc:create({ title = "数据库重构", description = "检索中文任务描述，迁移索引。" }))
test("manual sync is idle; optional auto stops after one upload; empty pulls never notify", function()
    local calls, events, pushes = 0, 0, 0
    local cloud = require("todo.cloud")
    local progress = require("todo.ui.network_progress")
    local original = progress.start
    progress.start = function()
        error("quiet sync must not create popup")
    end
    local opts = vim.tbl_extend("force", config.get().sync, {
        enabled = true,
        provider = "server",
        url = "https://example.invalid",
        token = "mock",
        auto = false,
        interval_seconds = 0,
        debounce_ms = 1,
        transport = function(r, cb)
            calls = calls + 1
            if r.url:find("/status", 1, true) then
                cb(nil, { version = 2 })
            elseif r.url:find("/pull", 1, true) then
                cb(nil, { version = 2, cursor = 0, operations = {} })
            elseif r.url:find("/push", 1, true) then
                pushes = pushes + 1
                local changes = {}
                for _, c in ipairs(r.body.changes) do
                    changes[#changes + 1] = { kind = c.kind, key = c.key, version = c.base_version + 1 }
                end
                cb(nil, { version = 2, changes = changes })
            else
                error("unexpected request")
            end
            return { running = false, cancel = function() end }
        end,
    })
    local stop = cloud.start_auto(ws, opts)
    vim.api.nvim_exec_autocmds("FocusGained", {})
    ws:notify()
    vim.wait(80)
    assert(calls == 0, "manual mode emitted network IO")
    stop()
    local event = vim.api.nvim_create_autocmd("User", {
        pattern = "TodoWorkspaceChanged",
        callback = function()
            events = events + 1
        end,
    })
    ws:import_page({ version = 2, cursor = 0, operations = {} })
    assert(events == 0, "empty pull emitted workspace change")
    opts.auto = true
    stop = cloud.start_auto(ws, opts)
    vim.wait(100)
    assert(pushes >= 1 and ws:cloud_status().pending == 0)
    local settled = calls
    vim.api.nvim_exec_autocmds("FocusGained", {})
    ws:notify()
    vim.wait(120)
    assert(calls == settled, "sync loop after empty pull / focus")
    stop()
    progress.start = original
    vim.api.nvim_del_autocmd(event)
end)
test("v1 pending operation gets a new ID after pull, preserving CAS and values", function()
    ws:put("profile", "migration", { value = 1 })
    local op = ws:export_pending()
    op.version = 1
    store:set_setting("cloud_flight", require("todo.sync.codec").encode(op))
    ws:import_page({ version = 2, cursor = 0, operations = {} })
    ws:upgrade_flight()
    local migrated = ws:export_pending()
    assert(migrated.operation_id ~= op.operation_id and migrated.version == 2)
    assert(vim.deep_equal(migrated.changes, op.changes))
    store:set_setting("cloud_flight", "")
end)
test("memory uses exact quotes, retains pending inferences and enforces dates/deletion", function()
    local session = {
        id = "session",
        date = planner:date(),
        messages = {
            {
                id = "source",
                role = "user",
                content = "我希望先处理数据库重构；今天只有两个小时。",
            },
        },
    }
    memory:capture(session, {
        {
            source_id = "source",
            quote = "我希望先处理数据库重构",
            text = "invented paraphrase",
            scope = "global",
        },
        { source_id = "source", text = "用户讨厌写文档", inferred = true, scope = "global" },
    })
    assert(#memory:list(true) == 2 and #memory:list() == 1)
    local confirmed = memory:list()[1]
    assert(confirmed.value.text == "我希望先处理数据库重构")
    local found = memory:search("数据库", "task", 8, session.date)
    assert(#found > 0 and found[1].id == task.sync_uuid, "CJK local search failed")
    local dated = memory:save("当天限制", { scope = "2000-01-01" })
    assert(not pcall(memory.lookup, memory, { tool = "get_memory", args = { id = dated } }, session), "date leak")
    ws:put("conversation", "summary", { summary = "我希望先处理数据库重构", messages = {} })
    memory:remove(confirmed.id)
    assert(not ws:get("conversation", "summary").summary)
    memory:capture(
        session,
        { { source_id = "source", quote = "我希望先处理数据库重构", text = "ignored", scope = "global" } }
    )
    assert(not ws:get("memory", confirmed.id), "forgotten source recreated memory")
end)
test("large context uses read-only task retrieval before drafting and counts every request", function()
    config.setup({ reminders = { enabled = false }, ai = { enabled = true, api_key = "mock", context_tokens = 2048 } })
    local big = assert(svc:create({ title = "长描述", description = string.rep("数据库迁移。", 1000) }))
    local n = 0
    local ai = require("todo.ai").new(ws, svc, {
        transport = function(r, cb)
            n = n + 1
            if n == 1 then
                local context = vim.json.decode(r.body.messages[2].content:match("Workspace snapshot:\n(.*)"))
                assert(context.full_task_text == false)
                cb(
                    nil,
                    response({
                        action = "lookup",
                        calls = { { tool = "read_tasks", args = { ids = { task.sync_uuid } } } },
                    })
                )
            else
                cb(
                    nil,
                    response({
                        action = "draft",
                        summary = "根据完整描述编排",
                        changes = {
                            {
                                kind = "plan_add",
                                task_uuid = task.sync_uuid,
                                after = { task_uuid = task.sync_uuid, group = "now", minutes = 30 },
                            },
                        },
                    })
                )
            end
            return { running = false, cancel = function() end }
        end,
    })
    local s = ai:start()
    local err
    n = 0
    s = ai:start()
    err = nil
    ai:send(s.id, "请编排数据库重构", function(e)
        err = e
    end)
    assert(not err, err)
    assert(ai:resume(s.id).requests == 2 and ai:resume(s.id).draft_id)
    assert(svc.store:get(big.id).description == big.description)
    config.setup({ reminders = { enabled = false }, ai = { enabled = true, api_key = "mock" } })
end)
local todo = require("todo")
todo._service = function()
    return svc
end
test("question form persists >3 questions, annotations and single submission across resizes", function()
    resize(160, 50)
    local requests = 0
    local ai = require("todo.ai").new(ws, svc, {
        transport = function(r, cb)
            requests = requests + 1
            cb(nil, response({ action = "draft", summary = "收到所有回答", changes = {} }))
            return { running = false, cancel = function() end }
        end,
    })
    todo._ai = function()
        return ai
    end
    local s = ai:start()
    local questions = {}
    for i = 1, 5 do
        questions[i] = {
            id = "q" .. i,
            header = "问题" .. i,
            question = "选择第" .. i .. "项",
            multiple = i == 2,
            options = {
                { id = "a", label = "选项甲", description = "说明甲" },
                { id = "b", label = "选项乙" },
                { id = "c", label = "选项丙" },
            },
        }
    end
    s.round = require("todo.ai.questions").normalize({ questions = questions }, 8)
    s.questions = 1
    ws:put("conversation", s.id, s)
    local ui = require("todo.ui.planner")
    local owner = ui.questions(s.id)
    local original = owner.popup.bufnr
    press("<Space>")
    press("j")
    press("e")
    local editbuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(editbuf, 0, -1, false, { "未选中的乙也能解释" })
    for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 20, 6 }, { 160, 50 } }) do
        resize(size[1], size[2])
        assert(vim.api.nvim_get_current_buf() == editbuf, "resize stole editor focus")
        assert(vim.api.nvim_buf_get_lines(editbuf, 0, -1, false)[1] == "未选中的乙也能解释")
    end
    vim.cmd("stopinsert")
    press("<CR>")
    assert(owner.popup.bufnr == original and not owner.closed)
    local round = ai:resume(s.id).round
    assert(
        round.answers.q1.selected.a
            and not round.answers.q1.selected.b
            and round.answers.q1.notes.b == "未选中的乙也能解释"
    )
    press("<Tab>")
    press("<Space>")
    press("j")
    press("<Space>")
    assert(ai:resume(s.id).round.answers.q2.selected.a and ai:resume(s.id).round.answers.q2.selected.b)
    for _ = 3, 5 do
        press("<Tab>")
        press("<Space>")
    end
    press("q")
    assert(requests == 0 and ai:resume(s.id).questions == 1)
    owner = ui.questions(s.id)
    for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 20, 6 }, { 160, 50 } }) do
        resize(size[1], size[2])
        assert(not owner.closed)
    end
    press("w")
    press("<CR>")
    assert(requests == 1 and ai:resume(s.id).requests == 1)
    assert(ai:resume(s.id).messages[1].content:find("not selected", 1, true))
    ui.close()
end)
test("dashboard t toggles current plan and survives tiny windows without replacing buffers", function()
    resize(160, 50)
    local panel = require("todo.ui.panel")
    panel.open({ view = "active", mode = "float", selected_id = task.id })
    local owner = panel.inspect_state().owner
    local buf = owner.list.bufnr
    press("t")
    assert(#planner:today(planner:date()).items == 1)
    press("t")
    assert(#planner:today(planner:date()).items == 0)
    for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 20, 6 }, { 160, 50 } }) do
        resize(size[1], size[2])
        assert(panel.is_open() and panel.inspect_state().owner == owner and owner.list.bufnr == buf)
    end
    panel.close()
end)
test("task form keeps Markdown edits and native insert Tab while shrinking", function()
    resize(160, 50)
    local form = require("todo.ui.form")
    form.open(task, function()
        error("test must not save task")
    end)
    vim.wait(40)
    local owner = form.inspect_state()
    local buf = owner.components.description.bufnr
    vim.api.nvim_set_current_win(owner.components.description.winid)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "尚未保存的中文备注" })
    -- The normal field navigation records description as the active field.
    vim.api.nvim_set_current_win(owner.components.title.winid)
    for _ = 1, 6 do
        press("<Tab>")
    end
    assert(vim.api.nvim_get_current_buf() == buf)
    for _, size in ipairs({ { 80, 24 }, { 40, 12 }, { 20, 6 }, { 160, 50 } }) do
        resize(size[1], size[2])
        assert(form.inspect_state() == owner and vim.api.nvim_get_current_buf() == buf)
        assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "尚未保存的中文备注")
    end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
        assert(map.lhs ~= "<Tab>", "Markdown Tab was intercepted")
    end
    form.close(true)
end)
test("AI request cancellation survives chat resize", function()
    resize(160, 50)
    local cancelled = false
    local ai = require("todo.ai").new(ws, svc, {
        transport = function()
            return {
                cancel = function()
                    cancelled = true
                end,
            }
        end,
    })
    todo._ai = function()
        return ai
    end
    local s = ai:start()
    ai:send(s.id, "整理任务", function() end)
    local ui = require("todo.ui.planner")
    local owner = ui.chat({ session_id = s.id })
    resize(40, 12)
    resize(160, 50)
    assert(not owner.closed and ai.active[s.id] and ai.active[s.id].running)
    press("c")
    assert(cancelled and not ai.active[s.id])
    ui.close()
end)
require("todo.ui.planner").close()
store:close()
for _, report in ipairs(reports) do
    print(report)
end
print(P .. " redesign tests passed, " .. F .. " failed")
if F > 0 then
    vim.cmd("cquit 1")
end
vim.cmd("qa!")
