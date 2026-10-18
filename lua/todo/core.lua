-- Required local Rust core. There is no Lua fallback: a missing or
-- incompatible todo-core is a hard startup error, as configured by the user.
local M = {}

local uv = vim.uv or vim.loop
local channel
local info
local last_error

local function plugin_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function executable(path)
    local stat = path and uv.fs_stat(path)
    return stat and stat.type == "file"
end

function M.binary()
    local configured = require("todo.config").get().core and require("todo.config").get().core.bin or ""
    local suffix = vim.fn.has("win32") == 1 and ".exe" or ""
    local candidates = {}
    for _, path in ipairs({
        configured,
        vim.env.TODO_CORE_BIN or "",
        plugin_root() .. "/core/target/release/todo-core" .. suffix,
        plugin_root() .. "/core/target/debug/todo-core" .. suffix,
        vim.fn.exepath("todo-core"),
    }) do
        if path and path ~= "" then
            candidates[#candidates + 1] = path
        end
    end
    for _, path in ipairs(candidates) do
        if executable(path) then
            return path
        end
    end
end

local function missing()
    return table.concat({
        "todo.nvim requires the Rust core binary `todo-core`, but it was not found.",
        "Build it with: cargo build --release --manifest-path " .. plugin_root() .. "/core/Cargo.toml",
        "Or set `core.bin` / `$TODO_CORE_BIN` to an existing binary.",
    }, "\n")
end

local function clean(value)
    if value == vim.NIL then
        return nil
    end
    if type(value) == "table" then
        for key, item in pairs(value) do
            value[key] = clean(item)
        end
    end
    return value
end

local function call(method, params)
    if not M.start() then
        error(last_error or missing(), 0)
    end
    local ok, result = pcall(vim.rpcrequest, channel, method, unpack(params or {}))
    if not ok then
        last_error = "todo-core RPC failed: " .. tostring(result)
        error(last_error, 0)
    end
    if type(result) ~= "table" or result.ok ~= true then
        local message = type(result) == "table" and result.error or "invalid todo-core response"
        error("todo-core: " .. tostring(message), 0)
    end
    return clean(result.value)
end

local function channel_open(ch)
    if not ch then
        return false
    end
    local ok, value = pcall(vim.api.nvim_get_chan_info, ch)
    return ok and type(value) == "table" and value.id ~= nil
end

function M.start()
    if channel_open(channel) then
        return true
    end
    channel, info = nil, nil
    local binary = M.binary()
    if not binary then
        last_error = missing()
        return nil, last_error
    end
    local started = vim.fn.jobstart({ binary }, {
        rpc = true,
        on_stderr = function(_, data)
            if data then
                for _, line in ipairs(data) do
                    if line ~= "" then
                        last_error = line
                    end
                end
            end
        end,
        on_exit = function()
            if channel == started then
                channel, info = nil, nil
            end
        end,
    })
    if started <= 0 then
        last_error = "cannot start todo-core: " .. tostring(binary)
        return nil, last_error
    end
    channel = started
    local ok, hello = pcall(vim.rpcrequest, channel, "core.hello", { client_version = "0.1.0" })
    if not ok or type(hello) ~= "table" or hello.ok ~= true then
        local message = type(hello) == "table" and hello.error or tostring(hello)
        pcall(vim.fn.chanclose, channel)
        channel = nil
        last_error = "todo-core handshake failed: " .. tostring(message)
        return nil, last_error
    end
    info = hello.value
    if tonumber(info.protocol) ~= 1 then
        pcall(vim.fn.chanclose, channel)
        channel = nil
        last_error = "todo-core protocol mismatch: " .. tostring(info.protocol)
        return nil, last_error
    end
    return true
end

function M.request(method, params)
    return call(method, params)
end

function M.health()
    return call("core.health", {})
end

function M.status()
    return {
        running = channel_open(channel),
        channel = channel,
        info = info,
        error = last_error,
        binary = M.binary(),
    }
end

function M.stop()
    if channel_open(channel) then
        pcall(vim.rpcrequest, channel, "core.shutdown", {})
        pcall(vim.fn.chanclose, channel)
    end
    channel, info = nil, nil
end

M._call = call

return M
