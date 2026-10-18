-- One source for configurable action keys, mappings and on-screen hints.
local M = {}
M.defaults = {
    focus_left = { "<C-h>" },
    focus_down = { "<C-j>" },
    focus_up = { "<C-k>" },
    focus_right = { "<C-l>" },
    read_half_up = { "<C-M-u>" },
    read_half_down = { "<C-M-d>" },
    read_page_up = { "<C-M-b>" },
    read_page_down = { "<C-M-f>" },
    read_latest = { "<C-M-g>" },
    maximize = { "+" },
    previous_question = { "h", "<S-Tab>" },
    next_question = { "l", "<Tab>" },
    select = { "<CR>" },
    toggle = { "<Space>" },
    preview = { "w" },
    edit_note = { "e" },
    input = { "i" },
    return_to_choices = { "<CR>", "<Esc>" },
}
function M.keys(action, options)
    options = options or require("todo.config").get().ui.daily_keys or {}
    local keys = options[action]
    if keys == nil then
        keys = M.defaults[action]
    end
    if keys == false then
        return {}
    end
    return type(keys) == "string" and { keys } or keys or {}
end
function M.label(action)
    return table.concat(
        vim.tbl_map(function(k)
            return k:gsub("<CR>", "Enter")
                :gsub("<Esc>", "Esc")
                :gsub("<Space>", "Space")
                :gsub("<S%-Tab>", "Shift-Tab")
                :gsub("<Tab>", "Tab")
                :gsub("<C%-M%-(.)>", "Ctrl-Alt-%1")
                :gsub("<C%-(.)>", "Ctrl-%1")
        end, M.keys(action)),
        " / "
    )
end
function M.bind(buf, action, fn, modes)
    for _, key in ipairs(M.keys(action)) do
        vim.keymap.set(modes or "n", key, fn, { buffer = buf, silent = true, nowait = true, desc = "Todo: " .. action })
    end
end
function M.validate(options)
    assert(type(options) == "table", "ui.daily_keys must be a table")
    for name, value in pairs(options) do
        assert(M.defaults[name], "Unknown ui.daily_keys action: " .. name)
        assert(value == false or type(value) == "string" or type(value) == "table", "Invalid ui.daily_keys." .. name)
        if type(value) == "table" then
            assert(vim.islist(value), "ui.daily_keys." .. name .. " must be a list of keys")
        end
    end
    local used = {}
    for _, key in ipairs({
        "j",
        "k",
        "gg",
        "G",
        "q",
        "r",
        "?",
        "<F1>",
        "M",
        "y",
        "Y",
        "n",
        "a",
        "v",
        "V",
        "p",
        "d",
        "b",
        "g",
        "s",
        "C",
        "B",
        "L",
        "S",
        "<C-q>",
        "<C-c>",
        "<C-u>",
        "<C-d>",
    }) do
        used["choices" .. vim.api.nvim_replace_termcodes(key, true, true, true)] = "reserved " .. key
    end
    for _, key in ipairs({ "<F1>", "<C-q>", "<C-c>" }) do
        used["input" .. vim.api.nvim_replace_termcodes(key, true, true, true)] = "reserved " .. key
    end
    for name in pairs(M.defaults) do
        for _, key in ipairs(M.keys(name, options)) do
            assert(type(key) == "string" and key ~= "", "Empty key for ui.daily_keys." .. name)
            -- Return only exists in the editable composer; selection/preview only in read-only panes.
            local contexts = name == "return_to_choices" and { "input" }
                or (name == "select" or name == "toggle" or name == "preview" or name == "edit_note" or name == "input" or name == "previous_question" or name == "next_question") and {
                    "choices",
                }
                or { "input", "choices" }
            for _, ctx in ipairs(contexts) do
                local canonical = ctx .. vim.api.nvim_replace_termcodes(key, true, true, true)
                assert(not used[canonical], "Conflicting ui.daily_keys: " .. name .. " / " .. (used[canonical] or ""))
                used[canonical] = name
            end
        end
    end
end
return M
