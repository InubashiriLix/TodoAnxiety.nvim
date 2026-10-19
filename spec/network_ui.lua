package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
require("todo.config").setup({ reminders = { enabled = false } })
local uv = vim.uv or vim.loop
local progress = require("todo.ui.network_progress")
local diag = require("todo.diagnostics")
local server, client, timer
local ok, err = xpcall(function()
    local win = vim.api.nvim_get_current_win()
    local p = progress.start("Async test")
    p:update("Download", 1, 2)
    vim.wait(150)
    assert(vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_config(p.win).focusable == false)
    assert(vim.api.nvim_buf_get_lines(p.buf, 0, 1, false)[1]:find("1/2", 1, true))
    p:finish("test failure")
    assert(p.failed and not p.running)
    progress.close()
    assert(next(progress.inspect_state()) == nil)
    vim.env.DEEPSEEK_API_KEY = "redaction_test_secret"
    diag.record({ operation = "test", stage = "redaction", error = "Bearer redaction_test_secret" })
    local log = table.concat(vim.fn.readfile(diag.path()), "\n")
    assert(not log:find("redaction_test_secret", 1, true))
    diag.record({ operation = "test", stage = "newline", error = "first diagnostic line\nsecond diagnostic line" })
    local opened, open_error = pcall(diag.open)
    assert(opened, open_error)
    local rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(
        rendered:find("first diagnostic line", 1, true)
            and rendered:find("second diagnostic line", 1, true),
        "diagnostics must render multiline errors"
    )
    vim.cmd("bwipeout!")
    server = uv.new_tcp()
    server:bind("127.0.0.1", 0)
    local port = server:getsockname().port
    server:listen(1, function()
        client = uv.new_tcp()
        server:accept(client)
        client:read_start(function(e, bytes)
            if not bytes then
                return
            end
            client:read_stop()
            timer = uv.new_timer()
            timer:start(150, 0, function()
                local rate_limited = bytes:find("/rate-limit", 1, true)
                local payload = rate_limited and "<html>too many requests</html>" or '{"ok":true}'
                local status = rate_limited and "429 Too Many Requests" or "200 OK"
                client:write(
                    "HTTP/1.1 "
                        .. status
                        .. "\r\nContent-Length: "
                        .. #payload
                        .. "\r\nConnection: close\r\n\r\n"
                        .. payload,
                    function()
                        client:close()
                    end
                )
                timer:stop()
                timer:close()
            end)
        end)
    end)
    local completed, response = false, nil
    local ticks = 0
    local ticker = uv.new_timer()
    ticker:start(10, 10, function()
        ticks = ticks + 1
    end)
    require("todo.http").request({ url = "http://127.0.0.1:" .. port, timeout_ms = 3000 }, function(e, r)
        assert(not e, e)
        response = r
        completed = true
    end)
    assert(not completed, "HTTP must return before callback")
    assert(
        vim.wait(5000, function()
            return completed
        end, 10),
        "HTTP timed out"
    )
    ticker:stop()
    ticker:close()
    assert(response.ok and ticks >= 3, "network blocked event loop")
    for _, raw in ipairs({ false, true }) do
        local finished, failure, status = false, nil, nil
        require("todo.http").request(
            { url = "http://127.0.0.1:" .. port .. "/rate-limit", raw = raw, timeout_ms = 3000 },
            function(e, _, code)
                failure, status, finished = e, code, true
            end
        )
        assert(vim.wait(5000, function()
            return finished
        end, 10))
        assert(
            status == 429 and failure:find("HTTP 429", 1, true),
            "HTML rate limit must retain HTTP status, including image downloads"
        )
    end
    local stdpath = vim.fn.stdpath
    local dir = vim.fn.tempname()
    local oldkey = vim.env.DEEPSEEK_API_KEY
    vim.env.DEEPSEEK_API_KEY = nil
    vim.fn.stdpath = function(kind)
        return kind == "data" and dir or stdpath(kind)
    end
    local success, credential_error = pcall(function()
        require("todo.credentials").set("local_test_key")
        assert(require("todo.credentials").get() == "local_test_key")
        local mode = uv.fs_stat(require("todo.credentials").path()).mode
        assert(bit.band(mode, 511) == 384, "credentials must be 0600")
        require("todo.credentials").clear()
    end)
    vim.fn.stdpath = stdpath
    vim.env.DEEPSEEK_API_KEY = oldkey
    vim.fn.delete(dir, "rf")
    assert(success, credential_error)
    progress.close()
    print("ok - async HTTP keeps event loop responsive, progress preserves focus, diagnostics redact secrets")
end, debug.traceback)
if server and not server:is_closing() then
    server:close()
end
progress.close()
if not ok then
    print(err)
    vim.cmd("cquit 1")
end
vim.cmd("qa!")
