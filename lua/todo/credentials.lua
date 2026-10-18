-- Device-local credentials. Never stored in workspace records or diagnostics.
local M = {}
local uv = vim.uv or vim.loop
local function read(path)
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" or stat.size > 16384 then
        return nil
    end
    local fd = uv.fs_open(path, "r", 384)
    if not fd then
        return nil
    end
    local bytes = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    local ok, value = pcall(vim.json.decode, bytes or "")
    if ok and type(value) == "table" then
        return value
    end
end
function M.path()
    return vim.fn.stdpath("data") .. "/todo.nvim/credentials.json"
end
function M.get()
    local cfg = require("todo.config").get().ai
    local key, source =
        require("todo.secrets").resolve(cfg.api_key, cfg.api_key_file, require("todo.providers").key_env(cfg))
    if key then
        return key, source
    end
    local local_value = read(M.path())
    local scoped = local_value and local_value.keys and local_value.keys[require("todo.providers").namespace(cfg)]
    if type(scoped) == "string" and scoped ~= "" then
        return scoped, "local"
    end
    if not require("todo.providers").deepseek_credentials(cfg) then
        return
    end
    if local_value and type(local_value.deepseek_api_key) == "string" and local_value.deepseek_api_key ~= "" then
        return local_value.deepseek_api_key, "local"
    end
    local opencode = read((vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")) .. "/opencode/auth.json")
    if
        opencode
        and type(opencode.deepseek) == "table"
        and type(opencode.deepseek.key) == "string"
        and opencode.deepseek.key ~= ""
    then
        return opencode.deepseek.key, "opencode"
    end
    local external = read(vim.fn.expand("~/.deepseek-mcp/config.json"))
    if external and type(external.api_key) == "string" and external.api_key ~= "" then
        return external.api_key, "deepseek-mcp"
    end
end
local function write(value)
    local dir = vim.fs.dirname(M.path())
    vim.fn.mkdir(dir, "p", 448)
    local temporary = M.path() .. "." .. require("todo.sync.codec").uuid() .. ".tmp"
    local fd = assert(uv.fs_open(temporary, "wx", 384), "cannot save credentials")
    local ok, err = pcall(function()
        assert(uv.fs_write(fd, vim.json.encode(value), 0))
        assert(uv.fs_fsync(fd))
    end)
    uv.fs_close(fd)
    if not ok then
        uv.fs_unlink(temporary)
        error(err, 0)
    end
    assert(uv.fs_rename(temporary, M.path()))
    uv.fs_chmod(M.path(), 384)
end
function M.set(key)
    assert(type(key) == "string" and #key > 0 and #key <= 8192 and not key:find("[%c]"), "invalid API key")
    local value = read(M.path()) or {}
    value.keys = value.keys or {}
    value.keys[require("todo.providers").namespace(require("todo.config").get().ai)] = key
    write(value)
    return true
end
function M.clear()
    local cfg = require("todo.config").get().ai
    local value = read(M.path())
    if not value then
        return
    end
    local namespace = require("todo.providers").namespace(cfg)
    if value.keys then
        value.keys[namespace] = nil
    end
    if require("todo.providers").deepseek_credentials(cfg) then
        value.deepseek_api_key = nil
    end
    write(value)
end
function M.prompt()
    vim.fn.inputsave()
    local ok, key = pcall(vim.fn.inputsecret, "AI API Key (hidden): ")
    vim.fn.inputrestore()
    if ok and key and key ~= "" then
        M.set(key)
        vim.notify("AI key saved locally (0600)", vim.log.levels.INFO)
    end
end
return M
