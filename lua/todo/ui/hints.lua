local config = require("todo.config")
local M = {}
local contexts = {}
local hint_ns = vim.api.nvim_create_namespace("TodoHintHighlight")

-- Parse the [key] tokens of a hint line for a given render mode.
local function token_spans(text)
    local spans = {}
    local init = 1
    while true do
        local s, e = text:find("%[(.-)%]%s", init)
        if not s then break end
        -- s..(e-1) is the whole "[key]"; e is the trailing separator space.
        spans[#spans + 1] = { s - 1, e - 1 }
        init = e + 1
    end
    return spans
end

--- Highlight a dynamic hint region (footer/border lines).
--- Lines are 0-based: first_line inclusive, last_line exclusive. Omit both to
--- refresh the whole buffer. Base text is rendered as TodoHintText and every
--- [key] token (or a bare F1 fallback) as TodoHintKey, at a priority that wins
--- over the legacy TodoMuted line highlight. Only the target lines are cleared.
function M.highlight(bufnr, first_line, last_line)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
    local total = vim.api.nvim_buf_line_count(bufnr)
    first_line = math.max(0, math.min(first_line or 0, total))
    last_line = last_line == nil and total or math.max(first_line, math.min(last_line, total))
    if last_line <= first_line then return end
    vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, first_line, last_line)
    for line = first_line, last_line - 1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
        if text ~= "" then
            vim.api.nvim_buf_set_extmark(bufnr, hint_ns, line, 0, {
                end_col = #text,
                hl_group = "TodoHintText",
                hl_eol = true,
                priority = 200,
            })
            local spans = token_spans(text)
            for _, span in ipairs(spans) do
                vim.api.nvim_buf_set_extmark(bufnr, hint_ns, line, span[1], {
                    end_col = span[2],
                    hl_group = "TodoHintKey",
                    priority = 201,
                })
            end
            -- Bare "F1" fallback (e.g. "F1: full help" / "F1 完整帮助").
            local find_init = 1
            while true do
                local s, e = text:find("F1", find_init, true)
                if not s then break end
                local inside = false
                for _, span in ipairs(spans) do
                    if s - 1 >= span[1] and e <= span[2] then
                        inside = true
                        break
                    end
                end
                if not inside then
                    vim.api.nvim_buf_set_extmark(bufnr, hint_ns, line, s - 1, {
                        end_col = e,
                        hl_group = "TodoHintKey",
                        priority = 201,
                    })
                end
                find_init = e + 1
            end
        end
    end
end
local function L(en, zh) return config.get().language == "zh-CN" and zh or en end
local function mode() return vim.api.nvim_get_mode().mode:sub(1, 1) == "i" and "i" or "n" end
function M.filter(actions, current_mode)
    return vim.tbl_filter(function(a)
        return not a.modes or vim.tbl_contains(a.modes, current_mode)
    end, actions or {})
end
-- Keep complete action tokens together; oversized tokens remain in full help.
function M.lines(actions, width, max_lines)
    width, max_lines = math.max(1, width), math.max(1, max_lines or 3)
    local entries = vim.list_extend({}, actions or {})
    local has_help = false
    for _, a in ipairs(entries) do
        if a.key:find("F1", 1, true) then has_help = true end
    end
    if not has_help then
        entries[#entries + 1] = { key = "F1", label = L("Help", "帮助") }
    end
    local lines, current, overflow = {}, "", false
    for _, a in ipairs(entries) do
        local token = "[" .. a.key .. "] " .. a.label
        if vim.fn.strdisplaywidth(token) > width then
            overflow = true
        elseif current ~= "" and vim.fn.strdisplaywidth(current .. "  " .. token) > width then
            lines[#lines + 1], current = current, token
        else
            current = current == "" and token or current .. "  " .. token
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    if #lines > max_lines then overflow = true end
    while #lines > max_lines do table.remove(lines) end
    if overflow then
        local fallback = width >= 12 and L("F1: full help", "F1 完整帮助") or "F1/?"
        if vim.fn.strdisplaywidth(fallback) > width then fallback = "?" end
        if #lines < max_lines then lines[#lines + 1] = fallback
        else lines[max_lines] = fallback end
    end
    return #lines > 0 and lines or { "F1/?" }
end
function M.close(owner)
    if owner and owner.help then owner.help:unmount() end
end
function M.show(provider, opts)
    opts = opts or {}
    local origin = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(origin)
    local original_mode = opts.mode or mode()
    local context = type(provider) == "function" and provider(original_mode) or provider
    local actions = M.filter(context.actions, original_mode)
    local owner = opts.owner
    if owner then M.close(owner) end
    local width = math.max(1, math.min(88, vim.o.columns - 4))
    local lines, marks, group = { " " .. (context.title or L("Help", "帮助")), "" }, {}, nil
    local key_width = 0
    for _, a in ipairs(actions) do key_width = math.max(key_width, vim.fn.strdisplaywidth(a.key)) end
    key_width = math.min(key_width, math.max(4, math.floor(width / 2)))
    for _, a in ipairs(actions) do
        local next_group = a.group or L("Operations", "操作")
        if next_group ~= group then
            if group then lines[#lines + 1] = "" end
            group = next_group
            lines[#lines + 1] = " " .. group
            marks[#marks + 1] = { #lines - 1, "TodoHeader" }
        end
        local prefix = "  " .. a.key .. string.rep(" ", math.max(2, key_width - vim.fn.strdisplaywidth(a.key) + 2))
        lines[#lines + 1] = prefix .. a.label
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = L(" j/k scroll · q/Esc/F1 close", " j/k 滚动 · q/Esc/F1 关闭")
    local popup = require("nui.popup")({ relative = "editor", position = "50%", enter = true,
        size = { width = width, height = math.max(1, math.min(#lines, vim.o.lines - 5)) },
        border = { style = config.get().ui.float.border, text = { top = " " .. L("Keyboard help", "快捷键帮助") .. " " } },
        buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false },
        win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" }, zindex = 300,
    })
    local unmount, closed, cleanup_id = popup.unmount, false, nil
    popup.unmount = function(self)
        if closed then return end
        closed = true
        if cleanup_id then pcall(vim.api.nvim_del_autocmd, cleanup_id) end
        if owner and owner.help == self then owner.help = nil end
        unmount(self)
        if (not owner or not owner.closed) and vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_set_current_win(origin)
            pcall(vim.api.nvim_win_set_cursor, origin, cursor)
            if original_mode == "i" then vim.cmd("startinsert") end
        end
    end
    if owner then owner.help = popup end
    popup:mount()
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_add_highlight(popup.bufnr, -1, mark[2], mark[1], 0, -1)
    end
    for index, line in ipairs(lines) do
        if line:sub(1, 2) == "  " then
            vim.api.nvim_buf_add_highlight(popup.bufnr, -1, "TodoTabActive", index - 1, 2, math.min(#line, key_width + 2))
        end
    end
    vim.bo[popup.bufnr].modifiable = false
    for _, key in ipairs({ "q", "<Esc>", "?", "<F1>", "<C-q>" }) do
        vim.keymap.set("n", key, function() popup:unmount() end, { buffer = popup.bufnr, silent = true })
    end
    cleanup_id = vim.api.nvim_create_autocmd({ "BufWipeout", "BufHidden" }, { buffer = vim.api.nvim_win_get_buf(origin), once = true,
        callback = function() if not closed then popup:unmount() end end })
    return popup
end
function M.attach(bufnr, provider, opts)
    opts = opts or {}
    contexts[bufnr] = provider
    local group = vim.api.nvim_create_augroup("TodoContextHints" .. bufnr, { clear = true })
    local function border_hint(current_mode)
        local owner = opts.owner
        if not owner then return end
        for _, name in ipairs({ "transient", "component" }) do
            local component = owner[name]
            if component and component.bufnr == bufnr and component.border then
                local ctx = provider(current_mode)
                local width = component.winid and vim.api.nvim_win_is_valid(component.winid)
                    and vim.api.nvim_win_get_width(component.winid) or 40
                component.border:set_text("bottom", M.lines(M.filter(ctx.actions, current_mode), width, 1)[1], "left")
                break
            end
        end
    end
    border_hint(mode())
    local function open()
        if not opts.owner or not opts.owner.closed then M.show(provider, opts) end
    end
    vim.keymap.set("n", "?", open, { buffer = bufnr, silent = true, desc = "Contextual help" })
    vim.keymap.set({ "n", "i" }, "<F1>", open, { buffer = bufnr, silent = true, desc = "Contextual help" })
    vim.api.nvim_create_autocmd({ "BufEnter", "ModeChanged" }, { buffer = bufnr, group = group,
        callback = function()
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr
                    and (not opts.owner or not opts.owner.closed) then
                    local ctx = provider(mode())
                    ctx.actions = M.filter(ctx.actions, mode())
                    border_hint(mode())
                    if opts.on_update then opts.on_update(ctx) end
                end
            end)
        end })
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = bufnr, group = group, once = true, callback = function()
        contexts[bufnr] = nil
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end })
end
return M
