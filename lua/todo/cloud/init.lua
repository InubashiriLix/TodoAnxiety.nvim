local M = {}
local uv = vim.uv or vim.loop
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
local active = setmetatable({}, { __mode = "k" })
local function request(opts, method, path, body, cb, raw)
    assert(type(opts.url) == "string" and opts.url:match("^https?://"), "sync.url required")
    assert(not opts.url:match("^http://") or opts.allow_http, "HTTP sync requires allow_http=true")
    local token = assert(
        require("todo.secrets").sync(opts),
        "sync token missing; configure sync.token_file, sync.token or sync.token_env"
    )
    return (opts.transport or require("todo.http").request)({
        operation = "Server " .. method .. " " .. path,
        url = opts.url:gsub("/$", "") .. path,
        method = method,
        headers = {
            Authorization = "Bearer " .. token,
            ["Content-Type"] = raw and "application/octet-stream" or "application/json",
        },
        body = body,
        raw = raw,
        preserve_null = true,
        ca_file = opts.ca_file,
        tls_verify = opts.tls_verify,
        timeout_ms = 30000,
        max_bytes = 16777216,
    }, cb)
end
M.request = request
function M.run(ws, opts, callback)
    callback = callback or function() end
    if active[ws] then
        callback("sync already running")
        return active[ws]
    end
    local feedback
    if opts.quiet then
        feedback = {
            update = function() end,
            finish = function(_, err)
                require("todo.diagnostics").record({
                    operation = "Background sync",
                    stage = "complete",
                    status = err and "failed" or "complete",
                    error = err,
                })
            end,
        }
    else
        feedback = require("todo.ui.network_progress").start(L("Server sync", "服务端同步"))
    end
    local uploaded, downloaded = 0, 0
    local handle = { running = true }
    active[ws] = handle
    local proc
    local ended = false
    local function done(err)
        if ended then
            return
        end
        ended = true
        handle.running = false
        active[ws] = nil
        ws.store:set_setting("cloud_last_error", err or "")
        if not err then
            ws.store:set_setting("cloud_last_success", os.time())
        end
        feedback:finish(
            err,
            not err
                    and string.format(
                        L("Synced · ↑%d ↓%d", "已同步 · 上传 %d 下载 %d"),
                        uploaded,
                        downloaded
                    )
                or nil
        )
        local status = ws:cloud_status()
        status.uploaded = uploaded
        status.downloaded = downloaded
        callback(err, status)
    end
    handle.cancel = function()
        if proc and proc.cancel then
            proc.cancel()
        end
        done("cancelled")
    end
    local function guarded(fn, ...)
        if ended then
            return
        end
        local ok, err = pcall(fn, ...)
        if not ok then
            done(tostring(err))
        end
    end
    local function call(method, path, body, fn, raw)
        proc = request(opts, method, path, body, function(err, result, status)
            if ended then
                return
            end
            if raw and status and (status < 200 or status >= 300) then
                err = "HTTP " .. status
            end
            if err then
                done(err)
                return
            end
            guarded(fn, result)
        end, raw)
    end
    local pulls = 0
    local function pull(nextstep)
        pulls = pulls + 1
        if pulls > 100 then
            done("Sync page limit reached; run sync again")
            return
        end
        feedback:update(L("Downloading changes", "下载变更"))
        local cursor = ws:cloud_status().cursor
        call("GET", "/v1/pull?after=" .. cursor, nil, function(page)
            assert(page.version == 2 and type(page.cursor) == "number" and page.cursor >= cursor, "invalid sync cursor")
            feedback:update(L("Applying changes", "应用变更"))
            downloaded = downloaded + ws:import_page(page)
            if page.cursor > cursor and #page.operations > 0 then
                pull(nextstep)
            else
                nextstep()
            end
        end)
    end
    local pushed = 0
    local function push()
        local op = ws:export_pending()
        if not op then
            pull(function()
                done()
            end)
            return
        end
        pushed = pushed + 1
        assert(pushed <= 20, "Sync operation limit reached; run again")
        local hashes, seen = {}, {}
        for _, c in ipairs(op.changes) do
            for _, hash in ipairs(c.attachments or {}) do
                if not seen[hash] then
                    hashes[#hashes + 1] = hash
                    seen[hash] = true
                end
            end
        end
        local function upload(n)
            if n > #hashes then
                feedback:update(L("Uploading changes", "上传变更"), 0, #op.changes)
                call("POST", "/v1/push", op, function(response)
                    ws:ack(op, response)
                    uploaded = uploaded + #op.changes
                    push()
                end)
                return
            end
            feedback:update(L("Uploading images", "上传图片"), n - 1, #hashes)
            local bytes = require("todo.assets").read(hashes[n], ws.store)
            call("PUT", "/v1/blobs/" .. hashes[n], bytes, function()
                upload(n + 1)
            end, true)
        end
        upload(1)
    end
    local ok, err = pcall(function()
        call("GET", "/v1/status", nil, function(status)
            assert(status.version == 2, "Unsupported server protocol")
            pull(function()
                ws:upgrade_flight()
                push()
            end)
        end)
    end)
    if not ok then
        done(tostring(err))
    end
    return handle
end
function M.fetch_asset(hash, store, opts, cb)
    assert(type(hash) == "string" and #hash == 64 and hash:match("^%x+$"), "invalid hash")
    local progress = require("todo.ui.network_progress").start(L("Image download", "图片下载"))
    progress:update(L("Downloading image", "下载图片"))
    return request(opts, "GET", "/v1/blobs/" .. hash, nil, function(err, bytes, status)
        if err or status ~= 200 then
            progress:finish(err or "Attachment download failed")
            cb(err or "Attachment download failed")
            return
        end
        local path = vim.fn.tempname()
        local fd = assert(uv.fs_open(path, "w", 384))
        uv.fs_write(fd, bytes, 0)
        uv.fs_close(fd)
        local ok, a = pcall(require("todo.assets").import, path, { store = store, expected_hash = hash })
        uv.fs_unlink(path)
        progress:finish(not ok and tostring(a) or nil)
        if ok then
            cb(nil, a)
        else
            cb(tostring(a))
        end
    end, true)
end
function M.acquire_lease(id, owner, opts, cb)
    return request(opts, "POST", "/v1/leases/" .. id, { owner = owner, ttl_seconds = 180 }, cb)
end
function M.renew_lease(id, owner, token, opts, cb)
    return request(opts, "POST", "/v1/leases/" .. id, { owner = owner, token = token, ttl_seconds = 180 }, cb)
end
function M.release_lease(id, owner, token, opts, cb)
    return request(opts, "DELETE", "/v1/leases/" .. id, { owner = owner, token = token }, cb or function() end)
end
function M.start_auto(ws, opts, on_update)
    if not opts.enabled or opts.provider ~= "server" or not opts.auto then
        return function() end
    end
    local timer = uv.new_timer()
    local debounce = uv.new_timer()
    local stopped = false
    local failures = 0
    local nexttime = 0
    local running
    local group = vim.api.nvim_create_augroup("TodoCloud" .. vim.fn.sha256(ws.store.path):sub(1, 10), { clear = true })
    local function pending()
        local status = ws:cloud_status()
        return status.pending > 0 and #status.conflicts == 0
    end
    local run
    run = function(poll)
        if stopped or not opts.auto or active[ws] or os.time() < nexttime then
            return
        end
        if not poll and not pending() then
            return
        end
        running = M.run(ws, vim.tbl_extend("force", opts, { quiet = true }), function(err, status)
            if stopped then
                return
            end
            failures = err and math.min(failures + 1, 6) or 0
            nexttime = os.time() + (err and math.min(60, 2 ^ failures) or 0)
            if not err and on_update and ((status.uploaded or 0) > 0 or (status.downloaded or 0) > 0) then
                on_update()
            end
            -- Edits made while a request was running must not be lost. Failures
            -- remain pending for a later edit/manual sync, without a retry loop.
            if not err and pending() then
                debounce:start(
                    opts.debounce_ms or 2000,
                    0,
                    vim.schedule_wrap(function()
                        run(false)
                    end)
                )
            end
        end)
    end
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TodoWorkspaceChanged",
        callback = function(event)
            if event.data and event.data.origin == "ai_checkpoint" then
                return
            end
            if not stopped and pending() then
                debounce:start(
                    opts.debounce_ms or 2000,
                    0,
                    vim.schedule_wrap(function()
                        run(false)
                    end)
                )
            end
        end,
    })
    if (opts.interval_seconds or 0) > 0 then
        timer:start(
            opts.interval_seconds * 1000,
            opts.interval_seconds * 1000,
            vim.schedule_wrap(function()
                run(true)
            end)
        )
    end
    -- Startup only flushes existing local changes; no FocusGained polling.
    vim.schedule(function()
        run(false)
    end)
    return function()
        stopped = true
        timer:stop()
        timer:close()
        debounce:stop()
        debounce:close()
        pcall(vim.api.nvim_del_augroup_by_id, group)
        if running and running.running then
            running.cancel()
        end
    end
end
return M
