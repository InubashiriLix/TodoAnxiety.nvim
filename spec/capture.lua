package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
require("todo.config").setup({
    db_path = vim.fn.tempname() .. ".db",
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-capture" },
})
local store = require("todo.store").open(require("todo.config").get().db_path)
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local task = assert(svc:create({ title = "Existing task", description = "Original" }))
local seen = {}
local ai = require("todo.ai").new(ws, svc, {
    transport = function(opts, cb)
        seen[#seen + 1] = opts
        local action = (opts.body.messages[1].content or ""):find("CAPTURE MODE", 1, true) and "capture" or "update"
        local result
        if action == "capture" then
            result = {
                action = "draft",
                summary = "Captured",
                changes = { { id = "new", kind = "task_create", after = { title = "Call the bank" } } },
            }
        else
            result = {
                action = "draft",
                summary = "Updated",
                changes = {
                    {
                        id = "status",
                        kind = "task_update",
                        task_ref = "t1",
                        after = { status = "in_progress" },
                    },
                },
            }
        end
        cb(nil, {
            choices = { { finish_reason = "stop", message = { content = vim.json.encode(result) } } },
            usage = { prompt_tokens = 5, completion_tokens = 5 },
        })
        return { running = false, cancel = function() end }
    end,
})
local function send(session, text)
    local err
    ai:send(session.id, text, {}, function(e)
        err = e
    end)
    assert(not err, err)
    return ai:resume(session.id)
end
local capture = ai:start({ scope = "capture", extended = true })
local done = send(capture, "I need to call the bank")
assert(done.draft_id, "capture must produce a review draft")
local system = seen[1].body.messages[1].content or " "
assert(system:find("CAPTURE MODE", 1, true), "capture prompt missing")
local update = ai:start({ task_id = task.id, scope = "update", extended = true })
done = send(update, "I started working on it")
assert(done.draft_id, "update must produce a review draft")
assert((seen[2].body.messages[1].content or ""):find("UPDATE MODE", 1, true), "update prompt missing")
assert((seen[2].body.messages[2].content or ""):find("Existing task", 1, true), "update context missing task")
store:close()
print("ok - capture and update AI modes produce review drafts with mode prompts")
vim.cmd("qa!")
