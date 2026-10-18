local M = {}
local uv = vim.uv or vim.loop
local function cfg()
    return require("todo.config").get().attachments
end
function M.directory(store)
    return cfg().directory ~= "" and cfg().directory or store.path .. ".assets"
end
local function identify(s)
    if s:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "png", "image/png"
    end
    if s:sub(1, 3) == "\255\216\255" then
        return "jpg", "image/jpeg"
    end
    if s:sub(1, 6) == "GIF87a" or s:sub(1, 6) == "GIF89a" then
        return "gif", "image/gif"
    end
    if s:sub(1, 4) == "RIFF" and s:sub(9, 12) == "WEBP" then
        return "webp", "image/webp"
    end
    error("Unsupported image data")
end
function M.import(path, opts)
    opts = opts or {}
    local store = assert(opts.store, "attachment store required")
    local stat = assert(uv.fs_stat(path), "image not found")
    assert(stat.type == "file" and stat.size > 0 and stat.size <= cfg().max_bytes, "image exceeds size limit")
    local fd = assert(uv.fs_open(path, "r", 384))
    local bytes = assert(uv.fs_read(fd, stat.size, 0))
    uv.fs_close(fd)
    local ext, mime = identify(bytes)
    local hash = vim.fn.sha256(bytes)
    assert(not opts.expected_hash or opts.expected_hash == hash, "image hash mismatch")
    local dir = M.directory(store)
    vim.fn.mkdir(dir, "p", 448)
    local target = dir .. "/" .. hash .. "." .. ext
    if not uv.fs_stat(target) then
        local temp = target .. "." .. require("todo.sync.codec").uuid() .. ".tmp"
        local out = assert(uv.fs_open(temp, "wx", 384))
        assert(uv.fs_write(out, bytes, 0))
        uv.fs_fsync(out)
        uv.fs_close(out)
        assert(uv.fs_rename(temp, target))
    end
    local name = (opts.name or vim.fs.basename(path)):gsub("[%[%]\r\n]", "_")
    local a = {
        hash = hash,
        path = target,
        name = name,
        mime = mime,
        size = #bytes,
        markdown = "![" .. name .. "](todo-asset://" .. hash .. "." .. ext .. ")",
    }
    if store.workspace and not opts.expected_hash then
        store.workspace:put(
            "attachment",
            hash,
            { hash = hash, name = name, mime = mime, size = #bytes, reference = "todo-asset://" .. hash .. "." .. ext }
        )
    end
    return a
end
function M.refs(text)
    local result, seen = {}, {}
    for hash in (text or ""):gmatch("todo%-asset://(%x+)") do
        if #hash == 64 and not seen[hash] then
            result[#result + 1] = hash
            seen[hash] = true
        end
    end
    return result
end
function M.resolve(reference, store)
    local hash = (reference or ""):match("todo%-asset://(%x+)") or reference
    if not hash or #hash ~= 64 or not hash:match("^%x+$") then
        return nil
    end
    for _, ext in ipairs({ "png", "jpg", "gif", "webp" }) do
        local p = M.directory(store) .. "/" .. hash .. "." .. ext
        if uv.fs_stat(p) then
            return p
        end
    end
end
function M.read(hash, store)
    local p = assert(M.resolve(hash, store), "attachment missing: " .. hash)
    local stat = assert(uv.fs_stat(p))
    assert(stat.size <= cfg().max_bytes, "image too large")
    local fd = assert(uv.fs_open(p, "r", 384))
    local bytes = assert(uv.fs_read(fd, stat.size, 0))
    uv.fs_close(fd)
    local _, mime = identify(bytes)
    return bytes, mime
end
function M.open(reference, store)
    local path = M.resolve(reference, store)
    if not path then
        local c = require("todo.config").get().sync
        if c.enabled and c.provider == "server" then
            local hash = reference:match("todo%-asset://(%x+)") or reference
            return require("todo.cloud").fetch_asset(hash, store, c, function(err)
                if err then
                    vim.notify(err, vim.log.levels.ERROR)
                else
                    M.open(hash, store)
                end
            end)
        end
        error("Attachment not downloaded")
    end
    local command = cfg().viewer
    local argv = type(command) == "table" and vim.deepcopy(command)
        or { vim.fn.has("mac") == 1 and "open" or "xdg-open" }
    argv[#argv + 1] = path
    return vim.system(argv, { detach = true })
end
function M.paste(opts, callback)
    opts = opts or {}
    local command = opts.command or cfg().clipboard_command
    if not command then
        if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
            command = { "wl-paste", "--no-newline", "--type", "image/png" }
        elseif vim.fn.executable("xclip") == 1 then
            command = { "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }
        else
            callback("No image clipboard provider")
            return
        end
    end
    return vim.system(command, { text = false, timeout = 5000 }, function(r)
        vim.schedule(function()
            if r.code ~= 0 or not r.stdout or #r.stdout == 0 then
                callback("No clipboard image")
                return
            end
            if #r.stdout > cfg().max_bytes then
                callback("Clipboard image exceeds size limit")
                return
            end
            local p = vim.fn.tempname()
            local fd = assert(uv.fs_open(p, "w", 384))
            uv.fs_write(fd, r.stdout, 0)
            uv.fs_close(fd)
            local ok, a = pcall(M.import, p, { store = opts.store, name = "clipboard.png" })
            uv.fs_unlink(p)
            if ok then
                callback(nil, a)
            else
                callback(tostring(a))
            end
        end)
    end)
end
function M.attach(buf, store, opts)
    opts = opts or {}
    if vim.b[buf].todo_assets then
        return
    end
    vim.b[buf].todo_assets = true
    if not opts.readonly then
        vim.keymap.set(opts.paste_modes or { "n", "i" }, "<C-v>", function()
            local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
            local win = vim.api.nvim_get_current_win()
            local pos = vim.api.nvim_win_get_cursor(win)
            M.paste({ store = store }, function(err, a)
                if not vim.api.nvim_buf_is_valid(buf) then
                    return
                end
                if err then
                    if err == "No clipboard image" or err == "No image clipboard provider" then
                        if vim.api.nvim_get_current_buf() == buf then
                            vim.api.nvim_feedkeys(
                                vim.api.nvim_replace_termcodes("<C-v>", true, false, true),
                                "n",
                                false
                            )
                        end
                    else
                        vim.notify(err, vim.log.levels.INFO)
                    end
                    return
                end
                local row = math.min(pos[1] - 1, vim.api.nvim_buf_line_count(buf) - 1)
                local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
                local col = math.min(pos[2], #line)
                vim.api.nvim_buf_set_text(buf, row, col, row, col, { a.markdown })
                if opts.on_asset then
                    opts.on_asset(a)
                end
            end)
        end, { buffer = buf, desc = "Paste image attachment" })
    end
    local images = {}
    local reported_error = false
    local function report(err)
        if reported_error then
            return
        end
        reported_error = true
        require("todo.diagnostics").record({ operation = "inline image", stage = "render", error = tostring(err) })
    end
    local function clear()
        for _, im in pairs(images) do
            pcall(function()
                im:clear()
            end)
        end
        images = {}
    end
    local function render()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        if not cfg().inline then
            clear()
            return
        end
        local ok, image = pcall(require, "image")
        if not ok then
            return
        end
        local win = vim.fn.bufwinid(buf)
        if win == -1 then
            clear()
            return
        end
        local retained = {}
        local geometry = table.concat({ win, vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }, ":")
        for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            for reference in line:gmatch("todo%-asset://%x+") do
                local key = geometry .. ":" .. row .. ":" .. reference
                if images[key] then
                    retained[key], images[key] = images[key], nil
                elseif not retained[key] then
                    local path = M.resolve(reference, store)
                    if path then
                        local success, im = pcall(
                            image.from_file,
                            path,
                            { buffer = buf, window = win, x = 0, y = row - 1, with_virtual_padding = true }
                        )
                        if success and im then
                            retained[key] = im
                            local rendered, err = pcall(function()
                                im:render()
                            end)
                            if not rendered then
                                report(err)
                            end
                        elseif not success then
                            report(im)
                        end
                    end
                end
            end
        end
        clear()
        images = retained
    end
    local pending = false
    local function schedule_render()
        if pending then
            return
        end
        pending = true
        vim.defer_fn(function()
            pending = false
            render()
        end, 80)
    end
    vim.api.nvim_buf_attach(buf, false, {
        on_lines = function()
            schedule_render()
        end,
    })
    vim.api.nvim_create_autocmd({ "BufWinEnter", "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            schedule_render()
        end,
    })
    local resize_id = vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { callback = schedule_render })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            pcall(vim.api.nvim_del_autocmd, resize_id)
        end,
    })
    vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout" }, { buffer = buf, callback = clear })
    vim.keymap.set("n", "gx", function()
        local line = vim.api.nvim_get_current_line()
        local ref = line:match("todo%-asset://%x+")
        if ref then
            M.open(ref, store)
        end
    end, { buffer = buf, desc = "Open image attachment" })
    schedule_render()
end
return M
