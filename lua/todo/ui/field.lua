-- Editable fields retain their buffer and never schedule an implicit focus jump.
local M = {}
function M.new(options, value, on_change)
    options.buf_options = { buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = true }
    local pop = require("nui.popup")(options)
    vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, { value or "" })
    vim.api.nvim_buf_attach(pop.bufnr, false, {
        on_lines = function()
            if on_change then
                on_change(vim.api.nvim_buf_get_lines(pop.bufnr, 0, 1, false)[1] or "")
            end
        end,
    })
    return pop
end
return M
