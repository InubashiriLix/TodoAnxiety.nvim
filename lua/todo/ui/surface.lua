-- Change only the differing lines. Unchanged Markdown buffers must not emit
-- on_lines events (Treesitter, image renderers and other integrations listen).
local M = {}
function M.write(buf, lines)
    if #lines == 0 then
        lines = { "" }
    end
    local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #old == #lines then
        local changed, start = {}, nil
        local modifiable = vim.bo[buf].modifiable
        for i = 1, #lines + 1 do
            if i <= #lines and old[i] ~= lines[i] then
                changed[i - 1] = true
                start = start or i
            elseif start then
                vim.bo[buf].modifiable = true
                require("todo.performance").count("buffer.writes")
                vim.api.nvim_buf_set_lines(buf, start - 1, i - 1, false, vim.list_slice(lines, start, i - 1))
                start = nil
            end
        end
        vim.bo[buf].modifiable = modifiable
        return next(changed) ~= nil, changed
    end
    local first, last_old, last_new = 1, #old, #lines
    while first <= last_old and first <= last_new and old[first] == lines[first] do
        first = first + 1
    end
    while last_old >= first and last_new >= first and old[last_old] == lines[last_new] do
        last_old, last_new = last_old - 1, last_new - 1
    end
    local replacement = {}
    for i = first, last_new do
        replacement[#replacement + 1] = lines[i]
    end
    local modifiable = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    require("todo.performance").count("buffer.writes")
    vim.api.nvim_buf_set_lines(buf, first - 1, last_old, false, replacement)
    vim.bo[buf].modifiable = modifiable
    return true, nil
end
return M
