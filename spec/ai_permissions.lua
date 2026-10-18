package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
vim.env.XDG_STATE_HOME = vim.fn.tempname()
local uv = vim.uv or vim.loop
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "Project deliverable: ship a small demo." }, root .. "/brief.md")
vim.fn.writefile({ "do-not-send-this" }, root .. "/.env")
uv.fs_symlink(root .. "/.env", root .. "/linked.md")
local cfg = require("todo.config")
cfg.setup({
    reminders = { enabled = false },
    ai = { enabled = true, api_key = "mock-permissions", permissions = {
        roots = { root },
    } },
})
local policy = require("todo.ai.permissions")
local research = require("todo.ai.research")
local function request(tool, args)
    return { tool = tool, args = args, reason = "Understand the task deliverable" }
end
local read = request("read_file", { path = root .. "/brief.md" })
assert(policy.evaluate(read, "plan").decision == "allow")
assert(not pcall(policy.evaluate, request("read_file", { path = root .. "/.env" }), "auto"))
assert(not pcall(policy.evaluate, request("read_file", { path = root .. "/linked.md" }), "auto"))
assert(not pcall(policy.evaluate, request("fetch_url", { url = "http://127.0.0.1:1234" }), "auto"))
assert(not pcall(policy.evaluate, request("fetch_url", { url = "https://api.example.com/?api_key=test" }), "auto"))
local function run(call, extra)
    local complete, value, failure = false
    local opts = vim.tbl_extend("force", { mode = "plan", session_id = "test" }, extra or {})
    research.run(call, opts, function(err, result)
        complete = true
        failure = err
        value = result
    end)
    assert(
        vim.wait(12000, function()
            return complete
        end, 10),
        "research timed out"
    )
    assert(not failure, failure)
    return value
end
vim.fn.writefile({ "中文任务描述" }, root .. "/chinese.md")
local chunk = run(request("read_file", { path = root .. "/chinese.md", max_bytes = 4 }))
assert(chunk.text == "中" and chunk.next_offset == 3, "UTF-8 read split a character")
chunk = run(request("read_file", { path = root .. "/chinese.md", offset = chunk.next_offset, max_bytes = 4 }))
assert(chunk.text == "文" and chunk.next_offset == 6)
local value = run(read)
assert(value.text:find("deliverable", 1, true) and value.complete)
value = run(request("search_files", { root = root, query = "do-not-send-this" }))
assert(value.text == "" and not value.error, vim.inspect(value))
value = run(request("search_files", { root = root, query = "deliverable" }))
assert(value.text:find("brief.md", 1, true), vim.inspect(value))
local command = request("run_command", { cwd = root, argv = { "sh", "-c", "printf changed > brief.md" } })
if vim.fn.executable("bwrap") == 1 and vim.fn.executable("prlimit") == 1 then
    assert(policy.evaluate(command, "plan").decision == "ask")
    value = run(command, {
        on_permission = function(_, cb)
            cb("allow", "Test exact request")
            return {}
        end,
    })
    assert(
        value.error and vim.fn.readfile(root .. "/brief.md")[1]:find("deliverable", 1, true),
        "host write escaped sandbox"
    )
    local sandbox_works = not value.error:find("bwrap:", 1, true) or value.error:find("Read%-only")
    if sandbox_works then
        local limits =
            run(request("run_command", { cwd = root, argv = { "sh", "-c", "ulimit -v; ulimit -u; ulimit -t" } }), {
                on_permission = function(_, cb)
                    cb("allow")
                    return {}
                end,
            })
        assert(
            limits.text and limits.text:find("262144", 1, true) and limits.text:find("64", 1, true),
            vim.inspect(limits)
        )
        value = run(request("run_command", { cwd = root, argv = { "cat", "brief.md" } }), {
            on_permission = function(_, cb)
                cb("allow")
                return {}
            end,
        })
        assert(value.text and value.text:find("deliverable", 1, true), vim.inspect(value))
        value = run(request("run_command", { cwd = root, argv = { "cat", ".env" } }), {
            on_permission = function(_, cb)
                cb("allow")
                return {}
            end,
        })
        assert(value.error and not value.error:find("do-not-send-this", 1, true))
    else
        assert(value.error:find("No host fallback", 1, true), "sandbox unavailable must fail closed")
        assert(
            value.error:find("Operation not permitted", 1, true)
                or value.error:find("No permissions", 1, true)
                or value.error:find("No space left", 1, true),
            value.error
        )
        print("skip - OS denies sandbox namespaces; fail-closed behavior verified")
    end
else
    assert(not pcall(policy.evaluate, command, "plan"), "missing sandbox must reject commands")
    print("skip - optional bwrap/prlimit unavailable; fail-closed behavior verified")
end
local reviews, asks = 0, 0
cfg.get().ai.permissions.rules.read_file = "ask"
value = run(read, {
    mode = "auto",
    review = function(_, cb)
        reviews = reviews + 1
        cb(nil, "allow", "Bounded listing")
        return {}
    end,
})
assert(reviews == 1)
cfg.get().ai.permissions.roots = {}
value = run(read, {
    mode = "auto",
    review = function()
        error("Reviewer must not expand local scope")
    end,
    on_permission = function(_, cb)
        asks = asks + 1
        cb("deny")
        return {}
    end,
})
assert(asks == 1 and value.denied)
cfg.get().ai.permissions.rules.read_file = "deny"
value = run(read, {
    on_permission = function()
        error("Local deny must not be overridable")
    end,
})
assert(value.denied)
cfg.get().ai.permissions.rules.read_file = "ask"
local pending, callbacks
local h = research.run(read, {
    mode = "plan",
    session_id = "cancel",
    on_permission = function(_, cb)
        pending = cb
        return {}
    end,
}, function(err)
    assert(err == "cancelled")
    callbacks = (callbacks or 0) + 1
end)
assert(vim.wait(1000, function()
    return pending ~= nil
end))
h.cancel()
pending("allow")
vim.wait(50)
assert(callbacks == 1 and not h.running)
print(
    "ok - scoped permissions, secret/symlink denial, filtered snapshots, sandbox writes blocked, auto scope boundaries, cancellation"
)
-- Real orchestration: independent reviewer is billed and shares request caps.
cfg.get().ai.permissions.roots = { root }
cfg.get().ai.permissions.rules.read_file = "ask"
local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local task = assert(svc:create({ title = "Research task", description = "Deliver demo" }))
local count, review_calls = 0, 0
local ai = require("todo.ai").new(ws, svc, {
    transport = function(opts, cb)
        count = count + 1
        local response
        if opts.body.messages[1].content:find("independent permission reviewer", 1, true) then
            review_calls = review_calls + 1
            response = { decision = "deny", reason = "No command needed" }
        elseif count == 1 then
            response = { action = "lookup", calls = { read } }
        else
            assert(vim.json.encode(opts.body.messages):find("Permission denied", 1, true))
            response = { action = "draft", changes = {}, summary = "Use known task context" }
        end
        vim.defer_fn(function()
            cb(nil, {
                choices = { { finish_reason = "stop", message = { content = vim.json.encode(response) } } },
                usage = { prompt_tokens = 20, completion_tokens = 10 },
            })
        end, 5)
        return {
            running = true,
            cancel = function()
                cb("cancelled")
            end,
        }
    end,
})
local s = ai:start({ task_id = task.id })
local done, err = false
ai:send(s.id, "Investigate", {
    mode = "auto",
    quiet = true,
    on_permission = function()
        error("Human approval unnecessary after reviewer deny")
    end,
}, function(e)
    err = e
    done = true
end)
assert(
    vim.wait(5000, function()
        return done
    end),
    "AI orchestration timeout"
)
assert(not err, err)
assert(count == 3 and review_calls == 1 and ai:usage(s.id).requests == 3)
assert(ai:usage(s.id).prompt_tokens == 60)
local review_usage = 0
for _, r in ipairs(ws:list("usage")) do
    if r.value.purpose == "permission_review" then
        review_usage = review_usage + 1
    end
end
assert(review_usage == 1)
print("ok - independent AI approval is isolated, counted and billed; denied research resumes planning")
vim.fn.delete(root, "rf")
store:close()
vim.cmd("qa!")
