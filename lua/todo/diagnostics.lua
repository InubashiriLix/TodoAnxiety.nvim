local M = {}
local uv = vim.uv or vim.loop
function M.path()
    return vim.fn.stdpath("state") .. "/todo.nvim/network.log"
end
function M.redact(value)
    local text = tostring(value or "")
    local cfg = require("todo.config").get()
    for _, name in ipairs({ cfg.ai.api_key_env, cfg.sync.token_env }) do
        local secret = vim.env[name]
        if secret and #secret > 0 then
            text = text:gsub(vim.pesc(secret), "[redacted]")
        end
    end
    for _, resolve in ipairs({
        require("todo.credentials").get,
        function()
            return require("todo.secrets").sync(cfg.sync)
        end,
    }) do
        local ok, credential = pcall(resolve)
        if ok and credential and credential ~= "" then
            text = text:gsub(vim.pesc(credential), "[redacted]")
        end
    end
    text = text:gsub("[Bb]earer%s+[%w%._%-]+", "Bearer [redacted]"):gsub("https?://[^/%s]+@", "https://[redacted]@")
    return text:sub(1, 1200)
end
function M.record(event)
    local file = M.path()
    vim.fn.mkdir(vim.fs.dirname(file), "p", 448)
    local stat = uv.fs_stat(file)
    if stat and stat.size > 262144 then
        uv.fs_unlink(file .. ".1")
        uv.fs_rename(file, file .. ".1")
    end
    local safe = { time = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    for _, key in ipairs({
        "id",
        "operation",
        "stage",
        "status",
        "elapsed_ms",
        "http_status",
        "exit_code",
        "count",
        "total",
        "error",
    }) do
        if event[key] ~= nil then
            safe[key] = type(event[key]) == "string" and M.redact(event[key]) or event[key]
        end
    end
    local fd = uv.fs_open(file, "a", 384)
    if fd then
        uv.fs_write(fd, vim.json.encode(safe) .. "\n", -1)
        uv.fs_close(fd)
    end
end
function M.open()
    local lines = { "Todo network diagnostics", M.path(), "" }
    if require("todo.performance").enabled() then
        vim.list_extend(lines, require("todo.performance").lines())
    end
    for _, path in ipairs({ M.path() .. ".1", M.path() }) do
        if uv.fs_stat(path) then
            for _, line in ipairs(vim.fn.readfile(path)) do
                local ok, e = pcall(vim.json.decode, line)
                if ok and type(e) == "table" then
                    lines[#lines + 1] = string.format(
                        "%s  %s  %s  %s  %s ms",
                        e.time or "",
                        e.operation or "",
                        e.stage or "",
                        (e.status or "") .. (e.http_status and (" HTTP " .. e.http_status) or ""),
                        e.elapsed_ms or ""
                    )
                    if e.error then
                        -- Logged errors may contain newlines; nvim_buf_set_lines
                        -- rejects them, so render every physical line separately.
                        for _, part in ipairs(vim.split(tostring(e.error), "\n", { plain = true })) do
                            lines[#lines + 1] = "  " .. (part:gsub("\r$", ""))
                        end
                    end
                end
            end
        end
    end
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.keymap.set("n", "q", function()
        vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf })
end
return M
