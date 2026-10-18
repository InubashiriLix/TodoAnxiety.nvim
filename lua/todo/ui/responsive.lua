-- Resize windows without replacing buffers, business state or request handles.
local M = {}

-- Popups that are currently filling the editor, keyed by the popup object so an
-- unmounted popup is collected instead of being restored later.
local maximized = setmetatable({}, { __mode = "k" })

function M.size(maxwidth, maxheight, margin)
    margin = margin or 4
    return {
        width = math.max(1, math.min(maxwidth, vim.o.columns - margin)),
        height = math.max(1, math.min(maxheight, vim.o.lines - margin)),
    }
end

-- Editor-filling geometry. The margin keeps room for the float border and the
-- command line so a maximized popup never spills outside the screen.
function M.maximized(margin)
    margin = margin or 4
    return {
        width = math.max(1, vim.o.columns - margin),
        height = math.max(1, vim.o.lines - margin),
    }
end
function M.watch(owner, resize)
    local group = vim.api.nvim_create_augroup(
        "TodoReflow" .. tostring(owner.bufnr or owner.popup and owner.popup.bufnr or owner.list and owner.list.bufnr),
        { clear = true }
    )
    owner.reflow_group = group
    local dimensions = vim.o.columns .. ":" .. vim.o.lines
    local pending = false
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = group,
        callback = function()
            local next_dimensions = vim.o.columns .. ":" .. vim.o.lines
            if next_dimensions == dimensions or pending or owner.closed then
                return
            end
            pending = true
            vim.schedule(function()
                pending = false
                dimensions = vim.o.columns .. ":" .. vim.o.lines
                if owner.closed then
                    return
                end
                local focused = vim.api.nvim_get_current_win()
                local views = {}
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
                end
                local ok, err = pcall(resize)
                for win, view in pairs(views) do
                    if vim.api.nvim_win_is_valid(win) then
                        pcall(vim.api.nvim_win_call, win, function()
                            vim.fn.winrestview(view)
                        end)
                    end
                end
                if vim.api.nvim_win_is_valid(focused) and vim.api.nvim_get_current_win() ~= focused then
                    vim.api.nvim_set_current_win(focused)
                end
                if not ok then
                    require("todo.diagnostics").record({
                        operation = "TUI",
                        stage = "resize",
                        status = "failed",
                        error = tostring(err),
                    })
                end
            end)
        end,
    })
    local close = owner.close or owner.force_close or owner.unmount
    local name = owner.close and "close" or owner.force_close and "force_close" or "unmount"
    owner[name] = function(...)
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return close(...)
    end
end
-- Remember the geometry a popup had before maximizing so the toggle can put it
-- back exactly where it was.
local function remember(pop)
    local winid = pop and pop.winid
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return nil
    end
    local config = vim.api.nvim_win_get_config(winid)
    local position = "50%"
    if config.relative == "win" then
        position = { win = config.win, row = config.row, col = config.col }
    elseif config.relative == "editor" or config.relative == "cursor" then
        position = { row = config.row, col = config.col }
    end
    return {
        relative = config.relative,
        position = position,
        size = { width = config.width, height = config.height },
    }
end

-- Resize without touching buffer, cursor, folds or selection.
local function relayout(pop, config)
    local winid = pop.winid
    local view
    if winid and vim.api.nvim_win_is_valid(winid) then
        view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
    end
    local ok, err = pcall(pop.update_layout, pop, config)
    if winid and vim.api.nvim_win_is_valid(winid) and view then
        pcall(vim.api.nvim_win_call, winid, function()
            vim.fn.winrestview(view)
        end)
    end
    if not ok then
        require("todo.diagnostics").record({
            operation = "TUI",
            stage = "maximize",
            status = "failed",
            error = tostring(err),
        })
    end
    return ok
end

--- Toggle a nui popup between its current geometry and an editor-filling one.
--- Only window geometry changes: the buffer, cursor, scroll position and any
--- selection stay intact, so callers keep input and pending requests alive.
---@param pop table nui popup
---@param maxwidth number|nil fallback width when the popup has no window yet
---@param maxheight number|nil fallback height when the popup has no window yet
---@param opts table|nil { margin = number, on_toggle = fun(maximized: boolean) }
---@return boolean maximized
function M.toggle_maximize(pop, maxwidth, maxheight, opts)
    opts = opts or {}
    if not pop or not pop.winid or not vim.api.nvim_win_is_valid(pop.winid) then
        return false
    end
    local previous = maximized[pop]
    if previous then
        maximized[pop] = nil
        -- Restore against today's screen size, not stale pre-resize pixels.
        relayout(pop, {
            relative = "editor",
            position = "50%",
            size = M.size(maxwidth or previous.size.width, maxheight or previous.size.height),
        })
        if opts.on_toggle then
            pcall(opts.on_toggle, false)
        end
        return false
    end
    maximized[pop] = remember(pop)
        or {
            relative = "editor",
            position = "50%",
            size = M.size(maxwidth or vim.o.columns, maxheight or vim.o.lines),
        }
    relayout(pop, { relative = "editor", position = "50%", size = M.maximized(opts.margin) })
    if opts.on_toggle then
        pcall(opts.on_toggle, true)
    end
    return true
end

function M.is_maximized(pop)
    return maximized[pop] ~= nil
end

--- Drop saved geometry, e.g. when the owner unmounts the popup itself.
function M.reset(pop)
    maximized[pop] = nil
end

local function has_key(bufnr, key)
    local ok, mappings = pcall(vim.api.nvim_buf_get_keymap, bufnr, "n")
    if not ok then
        return true
    end
    for _, mapping in ipairs(mappings) do
        if mapping.lhs == key then
            return true
        end
    end
    return false
end

--- Keep a popup inside the editor on resize and, unless the caller opts out or
--- the buffer already binds the key, let `+` maximize/restore it. The extra
--- argument is optional, so existing `responsive.popup(pop, w, h)` calls keep
--- working and additionally gain the toggle key.
---@param pop table nui popup
---@param maxwidth number
---@param maxheight number
---@param opts table|nil { maximize = boolean, key = string, margin = number, on_toggle = fun(...) }
function M.popup(pop, maxwidth, maxheight, opts)
    opts = opts or {}
    M.watch(pop, function()
        if M.is_maximized(pop) then
            pop:update_layout({ relative = "editor", position = "50%", size = M.maximized(opts.margin) })
        else
            pop:update_layout({ relative = "editor", position = "50%", size = M.size(maxwidth, maxheight) })
        end
    end)
    if opts.maximize == false or not pop.bufnr then
        return
    end
    local key = opts.key or "+"
    if has_key(pop.bufnr, key) then
        return
    end
    pcall(vim.keymap.set, "n", key, function()
        M.toggle_maximize(pop, maxwidth, maxheight, opts)
    end, { buffer = pop.bufnr, silent = true, desc = "Maximize / restore" })
end
return M
