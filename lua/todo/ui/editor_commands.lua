-- Native Vim writes for managed editors. No global command or mapping overrides.
local M = {}
function M.protect_layout(layout)
    local function clear()
        pcall(vim.api.nvim_clear_autocmds, { group = layout._.augroup.unmount, event = "QuitPre" })
    end
    for _, method in ipairs({ "mount", "update" }) do
        local original = layout[method]
        layout[method] = function(self, ...)
            local result = original(self, ...)
            clear()
            return result
        end
    end
    clear()
end
function M.attach(pop, opts)
    local buf = pop.bufnr
    local disposed, quitting, writing = false, nil, false
    local baseline = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    vim.api.nvim_buf_set_name(buf, "todo-editor://" .. buf)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden = "acwrite", "hide"
    vim.bo[buf].swapfile, vim.bo[buf].modified = false, false
    local group = vim.api.nvim_create_augroup("TodoEditorCommands" .. buf, { clear = true })
    local handle = {}
    function handle.mark_saved()
        if vim.api.nvim_buf_is_valid(buf) then
            baseline = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            vim.bo[buf].modified = false
        end
    end
    function handle.dispose()
        if disposed then
            return
        end
        disposed = true
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    local function dirty()
        if opts.is_dirty then
            return opts.is_dirty()
        end
        return vim.bo[buf].modified
    end
    -- NUI's default QuitPre unmounts even when :q fails with E37. Remove only
    -- that popup's hook; its hide/resize/buffer lifecycle hooks remain intact.
    local function mounted()
        if disposed then
            return
        end
        vim.bo[buf].buftype, vim.bo[buf].bufhidden = "acwrite", "hide"
        if pop._ and pop._.augroup then
            pcall(vim.api.nvim_clear_autocmds, { group = pop._.augroup.unmount, event = "QuitPre", buffer = buf })
        end
    end
    if pop._ and pop._.buf_options then
        pop._.buf_options.buftype, pop._.buf_options.bufhidden = "acwrite", "hide"
    end
    local mount = pop.mount
    pop.mount = function(self, ...)
        local result = mount(self, ...)
        mounted()
        return result
    end
    mounted()
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = buf,
        callback = function()
            assert(not writing, "Save is already in progress")
            writing = true
            local ok, result, err = pcall(opts.save)
            writing = false
            if not ok or result == false or result == nil then
                vim.bo[buf].modified = true
                error(tostring(not ok and result or err or "Save failed"), 0)
            end
            handle.mark_saved()
        end,
    })
    vim.api.nvim_create_autocmd("QuitPre", {
        group = group,
        buffer = buf,
        callback = function()
            if opts.is_dirty then
                vim.bo[buf].modified = dirty()
            end
            -- 'hidden' is normally enabled in Neovim. Ask the native quit path
            -- to check for unsaved text even though layout reflows keep drafts hidden.
            vim.bo[buf].bufhidden = "unload"
            local win = vim.api.nvim_get_current_win()
            quitting = win
            -- A failed :q must not arm a later layout resize as an editor exit.
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.bo[buf].bufhidden = "hide"
                end
                if quitting == win then
                    quitting = nil
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(event)
            if disposed or tonumber(event.match) ~= quitting then
                return
            end
            quitting = nil
            vim.bo[buf].bufhidden = "hide"
            local discard = dirty()
            vim.schedule(function()
                if disposed then
                    return
                end
                if discard and opts.rollback then
                    opts.rollback(baseline)
                end
                if vim.api.nvim_buf_is_valid(buf) then
                    handle.mark_saved()
                end
                if opts.persistent then
                    local layout = opts.layout and opts.layout()
                    if layout then
                        layout:show()
                    else
                        pop:show()
                    end
                end
                opts.close()
            end)
        end,
    })
    return handle
end
return M
