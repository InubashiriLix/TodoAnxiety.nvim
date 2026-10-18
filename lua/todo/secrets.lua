-- Explicit, device-local credential sources. Never persisted in synced records.
local M = {}
local uv = vim.uv or vim.loop
local function checked(value)
    assert(type(value) == "string" and #value > 0 and #value <= 8192 and not value:find("[%c]"), "invalid credential")
    return value
end
function M.resolve(value, path, env)
    if value ~= nil and value ~= false then
        if type(value) == "function" then
            local ok, result = pcall(value)
            assert(ok, "credential callback failed") -- callback errors may contain secrets
            value = result
        end
        return checked(value), "config"
    end
    if path and path ~= "" then
        path = vim.fn.expand(path)
        local stat = uv.fs_stat(path)
        assert(
            stat and stat.type == "file" and stat.size > 0 and stat.size <= 8194,
            "credential file missing or invalid"
        )
        local fd = assert(uv.fs_open(path, "r", 384), "cannot open credential file")
        local bytes = uv.fs_read(fd, stat.size, 0)
        uv.fs_close(fd)
        return checked(vim.trim(bytes or "")), "file"
    end
    local key = env and vim.env[env]
    if key and key ~= "" then
        return checked(key), "environment"
    end
end
function M.sync(opts)
    return M.resolve(opts.token, opts.token_file, opts.token_env or "TODO_SYNC_TOKEN")
end
return M
