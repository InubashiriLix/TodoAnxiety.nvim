package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local config, secrets = require("todo.config"), require("todo.secrets")
local path = vim.fn.tempname()
local uv = vim.uv or vim.loop
local saved = vim.env.TODO_CONFIG_TEST_TOKEN
vim.env.TODO_CONFIG_TEST_TOKEN = "environment-test-token"
local ok, err = xpcall(function()
    local fd = assert(uv.fs_open(path, "wx", 384))
    uv.fs_write(fd, "file-test-token\n", 0)
    uv.fs_close(fd)
    assert(secrets.resolve(false, "", "TODO_CONFIG_TEST_TOKEN") == "environment-test-token")
    assert(secrets.resolve(false, path, "TODO_CONFIG_TEST_TOKEN") == "file-test-token")
    assert(secrets.resolve("lua-test-token", path, "TODO_CONFIG_TEST_TOKEN") == "lua-test-token")
    assert(secrets.resolve(function()
        return "callback-test-token"
    end, path) == "callback-test-token")
    local success, message = pcall(secrets.resolve, function()
        error("private-callback-secret")
    end, "")
    assert(not success and not tostring(message):find("private-callback-secret", 1, true))
    assert(
        not pcall(secrets.resolve, false, path .. ".missing", "TODO_CONFIG_TEST_TOKEN"),
        "configured file must fail closed"
    )
    assert(not pcall(secrets.resolve, "bad\nheader", "", "TODO_CONFIG_TEST_TOKEN"))
    config.setup({
        sync = { token_file = path },
        ai = {
            api_key = function()
                return "configured-ai-secret"
            end,
            preferences_source = "config",
        },
    })
    local called = false
    local opts = vim.tbl_extend("force", config.get().sync, {
        url = "https://example.invalid/sync",
        transport = function(request, callback)
            assert(request.headers.Authorization == "Bearer file-test-token")
            assert(not request.url:find("file-test-token", 1, true))
            called = true
            callback(nil, { version = 1 })
            return { running = false, cancel = function() end }
        end,
    })
    require("todo.cloud").request(opts, "GET", "/v1/pull", nil, function(e)
        assert(not e, e)
    end)
    assert(called, "sync must accept file-based credentials without environment mutation")
    assert(require("todo.credentials").get() == "configured-ai-secret")
    local redacted = require("todo.diagnostics").redact("file-test-token and configured-ai-secret")
    assert(not redacted:find("file-test-token", 1, true) and not redacted:find("configured-ai-secret", 1, true))
    config.setup({
        planning = { capacity_minutes = 360, reserve_ratio = 0.3, timezone_offset_minutes = 480 },
        ai = { api_key = "explicit-key", text_only = true, extended = true, preferences_source = "config" },
    })
    local ws = {
        get = function()
            return nil
        end,
        put = function() end,
        store = {
            get_setting = function()
                return nil
            end,
        },
    }
    local planner = require("todo.planning").new(ws, {})
    assert(planner:today().capacity_minutes == 360 and planner:today().reserve_ratio == 0.3)
    assert(planner:date() == os.date("!%Y-%m-%d", os.time() + 480 * 60))
    local session = require("todo.ai").new(ws, {}):start({})
    assert(session.text_only and session.extended)
    local explicit = require("todo.ai").new(ws, {}):start({ text_only = false, extended = false })
    assert(not explicit.text_only and not explicit.extended)
    config.setup({ reminders = { enabled = false } })
end, debug.traceback)
vim.env.TODO_CONFIG_TEST_TOKEN = saved
vim.fn.delete(path)
if not ok then
    print(err)
    vim.cmd("cquit 1")
end
print("ok - Lua credentials, file/callback precedence, fail-closed errors, redaction and planning/AI defaults")
vim.cmd("qa!")
