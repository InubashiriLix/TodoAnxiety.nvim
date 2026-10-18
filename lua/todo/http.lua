-- Shared asynchronous HTTP adapter. Credentials and bodies never enter argv.
local M = {}
local serial = 0
local uv = vim.uv or vim.loop
local function private(path, data)
    local fd = assert(uv.fs_open(path, "w", 384))
    assert(uv.fs_write(fd, data, 0))
    uv.fs_close(fd)
end
function M.request(opts, callback)
    serial = serial + 1
    local request_id = serial
    local started = uv.hrtime()
    assert(
        type(opts.url) == "string"
            and opts.url:match("^https?://")
            and not opts.url:find("[%c]")
            and not opts.url:match("^https?://[^/]*@"),
        "invalid HTTP URL"
    )
    local dir = vim.fn.tempname()
    assert(vim.fn.mkdir(dir, "p", 448) == 1, "cannot create HTTP staging directory")
    local header, body, output = dir .. "/headers", dir .. "/body", dir .. "/response"
    local config = {}
    for name, value in pairs(opts.headers or {}) do
        assert(not name:find("[%c]") and not value:find("[%c]"), "invalid HTTP header")
        config[#config + 1] = 'header = "' .. (name .. ": " .. value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    private(header, table.concat(config, "\n"))
    private(output, "")
    local argv = {
        "curl",
        "--silent",
        "--show-error",
        "--config",
        header,
        "--request",
        opts.method or "GET",
        "--output",
        output,
        "--write-out",
        "%{http_code}",
        "--max-time",
        tostring((opts.timeout_ms or 90000) / 1000),
        "--max-filesize",
        tostring(opts.max_bytes or 16777216),
        "--proto",
        "=http,https",
        opts.url,
    }
    if opts.body then
        private(body, type(opts.body) == "string" and opts.body or require("todo.sync.codec").encode(opts.body))
        vim.list_extend(argv, { "--data-binary", "@" .. body })
    end
    if opts.ca_file and opts.ca_file ~= "" then
        vim.list_extend(argv, { "--cacert", opts.ca_file })
    end
    if opts.tls_verify == false then
        argv[#argv + 1] = "--insecure"
    end
    local handle = { running = true }
    local finished = false
    local exit_code
    local function cleanup()
        vim.fn.delete(dir, "rf")
    end
    local function done(err, result, status)
        if finished then
            return
        end
        finished = true
        handle.running = false
        cleanup()
        require("todo.diagnostics").record({
            id = tostring(request_id),
            operation = opts.operation or "HTTP",
            stage = opts.method or "GET",
            http_status = status,
            status = err and "failed" or "complete",
            error = err,
            elapsed_ms = math.floor((uv.hrtime() - started) / 1e6),
        })
        callback(err and require("todo.diagnostics").redact(err) or nil, result, status)
    end
    local ok, proc = pcall(vim.system, argv, { text = true }, function(r)
        vim.schedule(function()
            if finished then
                return
            end
            if r.code ~= 0 then
                exit_code = r.code
                local errors = {
                    [6] = "DNS resolution failed / 无法解析服务器地址",
                    [7] = "Connection failed / 无法连接服务器",
                    [28] = "Request timed out / 请求超时",
                    [35] = "TLS handshake failed / TLS 握手失败",
                    [60] = "Certificate verification failed / 证书验证失败；请配置 CA",
                    [63] = "Response size limit exceeded / 响应超过大小限制",
                }
                done((errors[r.code] or "HTTP transport failed") .. " (curl " .. r.code .. ")")
                return
            end
            local status = tonumber(r.stdout)
            local st = uv.fs_stat(output)
            if not st or st.size > (opts.max_bytes or 16777216) then
                done("HTTP response exceeds size limit")
                return
            end
            local fd = assert(uv.fs_open(output, "r", 384))
            local data = uv.fs_read(fd, st.size, 0) or ""
            uv.fs_close(fd)
            local parsed, value
            if not opts.raw or not status or status < 200 or status >= 300 then
                parsed, value = pcall(
                    vim.json.decode,
                    data,
                    opts.preserve_null and {} or { luanil = { object = true, array = true } }
                )
            end
            if not status or status < 200 or status >= 300 then
                local description = ({
                    [401] = "authentication failed / 认证失败，请检查密钥",
                    [403] = "access denied / 无权访问",
                    [429] = "rate limit / 请求过于频繁，请稍后重试",
                })[status]
                if not description and parsed and type(value) == "table" and type(value.error) == "string" then
                    description = value.error:sub(1, 250)
                end
                done(
                    "HTTP " .. tostring(status) .. (description and ": " .. description or ""),
                    parsed and value or nil,
                    status
                )
                return
            end
            if opts.raw then
                done(nil, data, status)
                return
            end
            if status == 204 then
                done(nil, {}, status)
                return
            end
            if not parsed then
                done("Invalid JSON HTTP response", nil, status)
                return
            end
            done(nil, value, status)
        end)
    end)
    handle.cancel = function()
        if proc and handle.running then
            proc:kill(15)
        end
        done("cancelled")
    end
    if not ok then
        vim.schedule(function()
            done("Unable to start curl")
        end)
    end
    return handle
end
-- Incremental transport: response headers stay in a private file; stdout is SSE only.
function M.stream(opts, on_text, callback)
    assert(
        type(opts.url) == "string"
            and opts.url:match("^https?://")
            and not opts.url:find("[%c]")
            and not opts.url:match("^https?://[^/]*@"),
        "invalid HTTP URL"
    )
    local dir = vim.fn.tempname()
    assert(vim.fn.mkdir(dir, "p", 448) == 1)
    local config, headers = {}, dir .. "/response-headers"
    for name, value in pairs(opts.headers or {}) do
        assert(not name:find("[%c]") and not value:find("[%c]"), "invalid HTTP header")
        config[#config + 1] = 'header = "' .. (name .. ": " .. value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    private(dir .. "/auth", table.concat(config, "\n"))
    private(dir .. "/body", require("todo.sync.codec").encode(opts.body))
    private(headers, "")
    local argv = {
        "curl",
        "--silent",
        "--show-error",
        "--no-buffer",
        "--config",
        dir .. "/auth",
        "--request",
        "POST",
        "--data-binary",
        "@" .. dir .. "/body",
        "--dump-header",
        headers,
        "--max-time",
        tostring((opts.timeout_ms or 90000) / 1000),
        "--proto",
        "=http,https",
        opts.url,
    }
    if opts.ca_file and opts.ca_file ~= "" then
        vim.list_extend(argv, { "--cacert", opts.ca_file })
    end
    if opts.tls_verify == false then
        argv[#argv + 1] = "--insecure"
    end
    local handle = { running = true }
    local finished = false
    local proc
    local status, content_type
    local received = 0
    local error_body = ""
    local started = uv.hrtime()
    local decoder = require("todo.ai.stream").new(on_text)
    local function read_headers()
        local stat = uv.fs_stat(headers)
        assert(stat and stat.size <= 65536, "invalid response headers")
        local fd = assert(uv.fs_open(headers, "r", 384))
        local raw = uv.fs_read(fd, stat.size, 0) or ""
        uv.fs_close(fd)
        for block in (raw:gsub("\r\n", "\n") .. "\n\n"):gmatch("(.-)\n\n") do
            local code = tonumber(block:match("^HTTP/[%d.]+%s+(%d+)"))
            if code and code >= 200 then
                status = code
                content_type = block:lower():match("content%-type:%s*([^\n]+)")
            end
        end
    end
    local function finish(err)
        if finished then
            return
        end
        finished = true
        handle.running = false
        if err and proc then
            proc:kill(15)
        end
        require("todo.diagnostics").record({
            operation = "AI stream",
            stage = "POST",
            status = err and "failed" or "complete",
            http_status = status,
            elapsed_ms = math.floor((uv.hrtime() - started) / 1e6),
            error = err,
        })
        vim.fn.delete(dir, "rf")
        callback(err and require("todo.diagnostics").redact(err) or nil, decoder:response(), status)
    end
    local ok, result = pcall(vim.system, argv, {
        stdout = function(err, data)
            vim.schedule(function()
                if finished then
                    return
                end
                local success, failure = pcall(function()
                    assert(not err, "stream read failed")
                    if not data then
                        return
                    end
                    received = received + #data
                    assert(received <= (opts.max_bytes or 16777216), "stream response exceeds size limit")
                    if not status then
                        read_headers()
                    end
                    assert(status, "missing response status")
                    if status < 200 or status >= 300 then
                        error_body = (error_body .. data):sub(1, 4096)
                        return
                    end
                    assert(
                        content_type and content_type:find("text/event-stream", 1, true),
                        "Provider did not return SSE; configure streaming=false for this provider"
                    )
                    decoder:feed(data)
                end)
                if not success then
                    finish(tostring(failure))
                end
            end)
        end,
    }, function(exit)
        vim.schedule(function()
            if finished then
                return
            end
            local success, err = pcall(function()
                if not status then
                    read_headers()
                end
                assert(exit.code == 0, "stream transport failed (curl " .. exit.code .. ")")
                assert(
                    status and status >= 200 and status < 300,
                    "HTTP "
                        .. tostring(status)
                        .. (status == 401 and ": authentication failed" or status == 429 and ": rate limit" or "")
                )
                assert(decoder.done and decoder.finish_reason, "stream interrupted before completion")
            end)
            finish(not success and tostring(err) or nil)
        end)
    end)
    if ok then
        proc = result
    else
        vim.schedule(function()
            finish("Unable to start curl")
        end)
    end
    handle.cancel = function()
        finish("cancelled")
    end
    return handle
end
return M
