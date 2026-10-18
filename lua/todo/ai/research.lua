-- Bounded asynchronous research. Approvals and fetched contents stay device-local.
local M = {}
local uv = vim.uv or vim.loop
local policy = require("todo.ai.permissions")
local codec = require("todo.sync.codec")
local read_flags = uv.os_uname().sysname == "Linux" and 131072 or "r"
local grants, cache = {}, {}
local function audit(p, decision, reason)
    require("todo.diagnostics").record({
        operation = "AI permission",
        stage = p.tool,
        status = decision,
        error = reason,
    })
    local dir = vim.fn.stdpath("state") .. "/todo.nvim"
    vim.fn.mkdir(dir, "p", 448)
    local path = dir .. "/permissions.json"
    local entries = {}
    pcall(function()
        entries = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    entries[#entries + 1] = {
        time = os.time(),
        mode = p.mode,
        tool = p.tool,
        id = p.id,
        target = require("todo.diagnostics").redact(p.target or ""),
        decision = decision,
        reason = reason,
    }
    while #entries > 200 do
        table.remove(entries, 1)
    end
    local fd = assert(uv.fs_open(path .. ".tmp", "w", 384))
    uv.fs_write(fd, codec.encode(entries), 0)
    uv.fs_close(fd)
    uv.fs_rename(path .. ".tmp", path)
end
-- A byte limit must never send a split UTF-8 sequence to a provider.
local function utf8_prefix(text)
    local i = 1
    while i <= #text do
        local b = text:byte(i)
        local n = b < 128 and 1
            or b >= 194 and b <= 223 and 2
            or b >= 224 and b <= 239 and 3
            or b >= 240 and b <= 244 and 4
            or nil
        if not n then
            return nil, "Not UTF-8 text; use UTF-8 files and the previous next_offset"
        end
        if i + n - 1 > #text then
            return text:sub(1, i - 1)
        end
        for j = i + 1, i + n - 1 do
            local c = text:byte(j)
            if c < 128 or c > 191 then
                return nil, "Non UTF-8 output"
            end
        end
        if n >= 3 then
            local second = text:byte(i + 1)
            if
                b == 224 and second < 160
                or b == 237 and second >= 160
                or b == 240 and second < 144
                or b == 244 and second >= 144
            then
                return nil, "Non UTF-8 output"
            end
        end
        i = i + n
    end
    return text
end
function M.run(call, opts, callback)
    local handle = { running = true }
    local active, staging, deadline
    local function done(err, value)
        if not handle.running then
            return
        end
        handle.running = false
        if deadline then
            deadline:stop()
            deadline:close()
            deadline = nil
        end
        if staging then
            vim.fn.delete(staging, "rf")
        end
        callback(err, value)
    end
    handle.cancel = function()
        done("cancelled")
        if active and active.cancel then
            active.cancel()
        end
    end
    local valid, p = pcall(policy.evaluate, call, opts.mode)
    if not valid then
        vim.schedule(function()
            done(nil, { error = tostring(p), denied = true })
        end)
        return handle
    end
    local c = policy.config()
    local function result_error(e)
        require("todo.diagnostics").record({
            operation = "AI research",
            stage = p.tool,
            status = "failed",
            error = tostring(e),
        })
        done(nil, { error = tostring(e), source = p.target, denied = true })
    end
    local function spawn(argv, options, cb)
        local parts, total, truncated = {}, 0, false
        local proc
        local function output(err, data)
            if err or not data then
                return
            end
            local room = c.max_output_bytes - total
            if room > 0 then
                parts[#parts + 1] = data:sub(1, room)
                total = total + math.min(room, #data)
            end
            if #data > room then
                truncated = true
                if proc then
                    proc:kill(9)
                end
            end
        end
        options = vim.tbl_extend(
            "force",
            { text = true, timeout = c.timeout_ms, stdout = output, stderr = output },
            options or {}
        )
        local ok, value = pcall(vim.system, argv, options, function(r)
            vim.schedule(function()
                if not handle.running then
                    return
                end
                cb(r.code, table.concat(parts), truncated)
            end)
        end)
        if not ok then
            result_error(value)
            return
        end
        proc = value
        active = {
            cancel = function()
                proc:kill(9)
            end,
        }
    end
    -- Copy only text files; never follow symlinks, copy credentials, .git or dependencies.
    -- The sandbox never mounts the original project or the user's home.
    local function snapshot(root, cb)
        staging = vim.fn.tempname()
        vim.fn.mkdir(staging, "p", 448)
        local queue, files, bytes = { { source = root, dest = staging } }, 0, 0
        local skip = {
            node_modules = true,
            target = true,
            vendor = true,
            __pycache__ = true,
            [".cache"] = true,
            [".venv"] = true,
        }
        local next_item
        next_item = function()
            if not handle.running then
                return
            end
            local item = table.remove(queue)
            if not item then
                cb()
                return
            end
            uv.fs_lstat(
                item.source,
                vim.schedule_wrap(function(err, st)
                    if not handle.running then
                        return
                    end
                    if err then
                        result_error(err)
                        return
                    end
                    if st.type == "directory" then
                        vim.fn.mkdir(item.dest, "p", 448)
                        uv.fs_scandir(
                            item.source,
                            vim.schedule_wrap(function(e, scan)
                                if not handle.running then
                                    return
                                end
                                if e then
                                    result_error(e)
                                    return
                                end
                                while true do
                                    local name = uv.fs_scandir_next(scan)
                                    if not name then
                                        break
                                    end
                                    if not skip[name] and not policy.sensitive(name) then
                                        queue[#queue + 1] =
                                            { source = item.source .. "/" .. name, dest = item.dest .. "/" .. name }
                                    end
                                end
                                if #queue > c.snapshot_max_files * 4 then
                                    result_error("Project tree too large; choose a narrower directory")
                                    return
                                end
                                next_item()
                            end)
                        )
                    elseif st.type == "file" then
                        files = files + 1
                        bytes = bytes + st.size
                        if files > c.snapshot_max_files or bytes > c.snapshot_max_bytes then
                            result_error("Snapshot size limit reached; choose a narrower directory")
                            return
                        end
                        uv.fs_open(
                            item.source,
                            "r",
                            384,
                            vim.schedule_wrap(function(e, fd)
                                if e then
                                    if handle.running then
                                        result_error(e)
                                    end
                                    return
                                end
                                uv.fs_read(
                                    fd,
                                    st.size,
                                    0,
                                    vim.schedule_wrap(function(read_err, data)
                                        uv.fs_close(fd)
                                        if not handle.running then
                                            return
                                        end
                                        if read_err then
                                            result_error(read_err)
                                            return
                                        end
                                        if not data:find("%z") then
                                            local out = assert(uv.fs_open(item.dest, "w", 384))
                                            uv.fs_write(out, data, 0)
                                            uv.fs_close(out)
                                        end
                                        next_item()
                                    end)
                                )
                            end)
                        )
                    else
                        next_item()
                    end
                end)
            )
        end
        next_item()
    end
    local function execute()
        if not handle.running then
            return
        end
        deadline = uv.new_timer()
        deadline:start(
            c.timeout_ms,
            0,
            vim.schedule_wrap(function()
                if not handle.running then
                    return
                end
                local process = active
                result_error("Research timed out; no host fallback was attempted")
                if process and process.cancel then
                    process.cancel()
                end
            end)
        )
        if opts.on_stage then
            opts.on_stage("Research / 查阅资料 · " .. p.tool)
        end
        local cached = cache[p.id]
        if cached and p.tool ~= "read_file" and p.tool ~= "run_command" and os.time() - cached.at < 60 then
            done(nil, vim.tbl_extend("force", cached.value, { cached = true }))
            return
        end
        local function deliver(value)
            if value.text then
                local text, err = utf8_prefix(value.text)
                if not text then
                    result_error(err)
                    return
                end
                value.truncated = value.truncated or #text < #value.text
                value.text = text
            end
            value.source = p.target
            if p.tool == "search_files" or p.tool == "fetch_url" then
                cache[p.id] = { at = os.time(), value = value }
            end
            done(nil, value)
        end
        local a = p.args
        local target = a.path or a.root or a.cwd
        if target then
            local verified = policy.path(target)
            assert(verified == target, "Path changed since approval; request access again")
        end
        if p.tool == "read_file" then
            uv.fs_open(
                a.path,
                "r",
                384,
                vim.schedule_wrap(function(err, fd)
                    if err then
                        if handle.running then
                            result_error(err)
                        end
                        return
                    end
                    uv.fs_fstat(
                        fd,
                        vim.schedule_wrap(function(stat_err, st)
                            if stat_err or not handle.running then
                                uv.fs_close(fd)
                                if handle.running then
                                    result_error(stat_err)
                                end
                                return
                            end
                            uv.fs_read(
                                fd,
                                math.min(a.max_bytes, math.max(0, st.size - a.offset)),
                                a.offset,
                                vim.schedule_wrap(function(e, data)
                                    uv.fs_close(fd)
                                    if not handle.running then
                                        return
                                    end
                                    if e then
                                        result_error(e)
                                        return
                                    end
                                    if data:find("%z") then
                                        result_error("Binary files are not supported by read_file")
                                        return
                                    end
                                    local prefix, utf_error = utf8_prefix(data)
                                    if not prefix then
                                        result_error(utf_error)
                                        return
                                    end
                                    data = prefix
                                    deliver({
                                        text = data,
                                        offset = a.offset,
                                        next_offset = a.offset + #data,
                                        complete = a.offset + #data >= st.size,
                                        hash = vim.fn.sha256(data),
                                    })
                                end)
                            )
                        end)
                    )
                end)
            )
        elseif p.tool == "fetch_url" then
            local req
            req = uv.getaddrinfo(
                a.host,
                "443",
                { socktype = "stream" },
                vim.schedule_wrap(function(err, addresses)
                    if not handle.running then
                        return
                    end
                    if err then
                        result_error("DNS: " .. err)
                        return
                    end
                    local ip
                    for _, item in ipairs(addresses or {}) do
                        local v = item.addr
                        local x, y = v:match("^(%d+)%.(%d+)%.")
                        x, y = tonumber(x), tonumber(y)
                        -- Strict public IPv4 only; pin DNS answer to prevent rebinding.
                        if
                            x
                            and x >= 1
                            and x < 224
                            and x ~= 10
                            and x ~= 127
                            and x ~= 169
                            and x ~= 192
                            and x ~= 198
                            and not (x == 172 and y >= 16 and y <= 31)
                            and not (x == 100 and y >= 64 and y <= 127)
                        then
                            ip = v
                            break
                        end
                    end
                    if not ip then
                        result_error(
                            "DNS returned no permitted public IPv4 address (private/loopback or proxy fake-IP). Use public DNS resolution for this tool; no direct/proxy fallback was attempted."
                        )
                        return
                    end
                    spawn({
                        "curl",
                        "--disable",
                        "--silent",
                        "--show-error",
                        "--fail",
                        "--proto",
                        "=https",
                        "--noproxy",
                        "*",
                        "--resolve",
                        a.host .. ":443:" .. ip,
                        "--max-filesize",
                        tostring(c.max_output_bytes),
                        "--max-time",
                        tostring(c.timeout_ms / 1000),
                        a.url,
                    }, { clear_env = true, env = { PATH = "/usr/bin:/bin" } }, function(
                        code,
                        data,
                        cut
                    )
                        if code ~= 0 and not cut then
                            result_error("Fetch failed (curl " .. code .. "); redirects are not followed")
                            return
                        end
                        deliver({ text = data, truncated = cut })
                    end)
                end)
            )
            active = {
                cancel = function()
                    if req then
                        pcall(req.cancel, req)
                    end
                end,
            }
        else
            local root = p.tool == "search_files" and a.root or a.cwd
            snapshot(root, function()
                local argv
                if p.tool == "search_files" then
                    argv = {
                        assert(vim.fn.exepath("rg") ~= "" and vim.fn.exepath("rg"), "ripgrep (rg) unavailable"),
                        "--no-config",
                        "--no-heading",
                        "--line-number",
                        "--color",
                        "never",
                        "--fixed-strings",
                        "--",
                        a.query,
                        ".",
                    }
                    spawn(
                        argv,
                        { cwd = staging, clear_env = true, env = { PATH = "/usr/bin:/bin" } },
                        function(code, data, cut)
                            if code > 1 and not cut then
                                result_error("Search failed: " .. data)
                                return
                            end
                            deliver({
                                text = data,
                                truncated = cut,
                                snapshot = true,
                                excludes = "symlinks, binary files, credentials, .git and dependency directories",
                            })
                        end
                    )
                else
                    argv = {
                        "bwrap",
                        "--die-with-parent",
                        "--unshare-all",
                        "--unshare-user",
                        "--disable-userns",
                        "--cap-drop",
                        "ALL",
                        "--new-session",
                        "--clearenv",
                        "--setenv",
                        "PATH",
                        "/usr/bin:/bin",
                        "--setenv",
                        "HOME",
                        "/tmp",
                        "--size",
                        tostring((c.scratch_mb or 16) * 1048576),
                        "--tmpfs",
                        "/tmp",
                        "--proc",
                        "/proc",
                        "--dev",
                        "/dev",
                    }
                    for _, dir in ipairs({ "/usr", "/bin", "/lib", "/lib64" }) do
                        if uv.fs_stat(dir) then
                            vim.list_extend(argv, { "--ro-bind", dir, dir })
                        end
                    end
                    vim.list_extend(argv, {
                        "--ro-bind",
                        staging,
                        "/workspace",
                        "--chdir",
                        "/workspace",
                        "--remount-ro",
                        "/dev",
                        "--remount-ro",
                        "/proc",
                        "--remount-ro",
                        "/",
                        "--",
                        assert(uv.fs_realpath(vim.fn.exepath("prlimit")), "prlimit unavailable"),
                        "--nproc=" .. (c.max_processes or 64),
                        "--as=" .. tostring((c.memory_mb or 256) * 1048576),
                        "--cpu=" .. (c.cpu_seconds or 5),
                        "--fsize=" .. tostring((c.scratch_mb or 16) * 1048576),
                        "--nofile=64",
                        "--",
                        a.executable,
                    })
                    for i = 2, #a.argv do
                        argv[#argv + 1] = a.argv[i]
                    end
                    spawn(argv, { clear_env = true, env = { PATH = "/usr/bin:/bin" } }, function(code, data, cut)
                        if code ~= 0 and not cut then
                            result_error(
                                "Sandbox command failed ("
                                    .. code
                                    .. "): "
                                    .. data
                                    .. "\nNo host fallback. Use relative paths within /workspace; install/fix bubblewrap or permissions on this device."
                            )
                            return
                        end
                        deliver({
                            text = data,
                            truncated = cut,
                            exit_code = code,
                            snapshot = true,
                            network = false,
                            writable = "temporary scratch only",
                        })
                    end)
                end
            end)
        end
    end
    local scope = opts.workflow_id or opts.session_id
    grants[scope] = grants[scope] or {}
    local function authorize(decision, reason)
        if not handle.running then
            return
        end
        audit(p, decision, reason)
        if decision == "allow_session" then
            grants[scope][p.id] = true
        end
        if decision == "allow" or decision == "allow_session" then
            local ok, e = pcall(execute)
            if not ok then
                result_error(e)
            end
        else
            result_error("Permission denied: " .. (reason or "user rejected"))
        end
    end
    local function ask(reason)
        p.review_reason = reason
        if not opts.on_permission then
            authorize("deny", "No approval UI attached")
            return
        end
        local ok, value = pcall(opts.on_permission, p, authorize)
        if ok then
            active = value
        else
            result_error(value)
        end
    end
    vim.schedule(function()
        if not handle.running then
            return
        end
        if p.decision == "deny" then
            authorize("deny", p.explanation)
        elseif p.decision == "allow" or grants[scope][p.id] then
            authorize("allow", "Local policy / exact session grant")
        elseif p.reviewable and opts.review then
            active = opts.review(p, function(err, decision, reason)
                if not handle.running then
                    return
                end
                if err or decision == "ask" then
                    ask(err or reason)
                elseif decision == "allow" or decision == "deny" then
                    authorize(decision, "AI reviewer: " .. (reason or ""))
                else
                    ask("Invalid reviewer decision")
                end
            end)
        else
            ask(p.explanation)
        end
    end)
    return handle
end
function M.clear(scope)
    grants[scope] = nil
end
return M
