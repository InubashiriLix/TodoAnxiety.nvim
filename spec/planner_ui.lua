local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    language = "zh-CN",
    reminders = { enabled = false },
    ai = { enabled = true },
})
local todo = require("todo")
local svc = todo._service()
local ws = svc.store.workspace
local planner = require("todo.planning").new(ws, svc)
local t = assert(svc:create({ title = "界面测试", description = "原始描述" }))
planner:add(t.sync_uuid)
local function press(k)
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt")
    vim.wait(30)
end
local ok, err = xpcall(function()
    todo.today()
    local panel = require("todo.ui.panel")
    assert(panel.inspect_state().view == "today")
    press("j")
    assert(panel.current_task().id == t.id)
    press("L")
    assert(planner:today().items[1].locked == true)
    press("U")
    assert(planner:today().items[1].locked == false)
    local header =
        table.concat(vim.api.nvim_buf_get_lines(panel.inspect_state().owner.header.bufnr, 0, -1, false), "\n")
    assert(header:find("480m", 1, true))
    panel.close()
    local api = require("todo.ai").new(ws, svc, {
        transport = function(opts, cb)
            cb(nil, {
                choices = {
                    {
                        message = {
                            content = vim.json.encode({
                                action = "question",
                                question = "希望最终得到什么结果？",
                            }),
                        },
                        finish_reason = "stop",
                    },
                },
                usage = { prompt_tokens = 100, completion_tokens = 10 },
            })
            return { running = false, cancel = function() end }
        end,
    })
    todo._ai = function()
        return api
    end
    vim.env.DEEPSEEK_API_KEY = "mock-ui"
    local ui = require("todo.ui.planner")
    local owner = ui.chat({ task_id = t.id })
    local conversations = ws:list("conversation")
    local session = conversations[#conversations].value
    press("a")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "帮我澄清任务" })
    vim.cmd("stopinsert")
    press("<CR>")
    assert(api:resume(session.id).questions == 1, "chat submit must ask one question")
    vim.o.columns = 80
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert(
        vim.wait(1000, function()
            return not owner.closed and vim.api.nvim_win_get_width(owner.popup.winid) < 100
        end),
        "wide chat must reflow without replacing owner"
    )
    vim.wait(80)
    assert(vim.api.nvim_win_get_width(0) <= 80)
    press("V")
    assert(api:resume(session.id).text_only == true, "text-only control must work in narrow layout")
    vim.o.columns = 140
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.wait(100)
    ui.close()
    local draft = {
        id = require("todo.sync.codec").uuid(),
        session_id = session.id,
        date = planner:today().date,
        plan_revision = select(2, ws:get("plan", planner:today().date)),
        summary = "建议补充描述",
        changes = {
            {
                id = "one",
                kind = "description",
                task_uuid = t.sync_uuid,
                expected_revision = svc.store:get(t.id).sync_revision,
                after = { description = "明确后的描述" },
                reason = "补充目标",
            },
        },
    }
    ws:put("draft", draft.id, draft)
    owner = ui.review(draft.id)
    assert(svc.store:get(t.id).description == "原始描述", "opening review must not apply")
    vim.api.nvim_win_set_cursor(owner.popup.winid, { 4, 0 })
    press("<Space>")
    assert(ws:get("draft", draft.id).changes[1].selected)
    press("a")
    assert(svc.store:get(t.id).description == "明确后的描述")
    press("U")
    assert(svc.store:get(t.id).description == "原始描述")
    panel.close()
    svc.store:close()
    print("ok - today controls, chat editor, review selection/apply and batch undo")
end, debug.traceback)
if not ok then
    print(err)
    vim.cmd("cquit 1")
end
vim.cmd("qa!")
