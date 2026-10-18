local M = {}

local links = {
    TodoHeader = "Title",
    TodoTabActive = "TabLineSel",
    TodoTabInactive = "TabLine",
    TodoSelected = "Visual",
    TodoTaskTitle = "Normal",
    TodoMuted = "Comment",
    TodoBorder = "FloatBorder",
    TodoError = "DiagnosticError",
    TodoSuccess = "DiagnosticOk",
    TodoPriority0 = "DiagnosticError",
    TodoPriority1 = "DiagnosticWarn",
    TodoPriority2 = "DiagnosticInfo",
    TodoPriority3 = "Comment",
    TodoStatusTodo = "DiagnosticInfo",
    TodoStatusInProgress = "DiagnosticWarn",
    TodoStatusDone = "DiagnosticOk",
    TodoStatusCancelled = "Comment",
    TodoUrgencyOverdue = "DiagnosticError",
    TodoUrgencyUrgent = "DiagnosticWarn",
    TodoUrgencyHigh = "DiagnosticInfo",
    TodoUrgencyAttention = "DiagnosticHint",
    TodoUrgencyPriorityOnly = "Comment",
    TodoTag1 = "DiagnosticOk",
    TodoTag2 = "DiagnosticInfo",
    TodoTag3 = "DiagnosticHint",
    TodoTag4 = "DiagnosticWarn",
    TodoTag5 = "String",
    TodoTag6 = "Identifier",
    TodoTag7 = "Type",
    TodoTag8 = "Special",
    TodoSectionHeader = "Folded",
}

-- Card bars and badges are intentionally concrete rather than links: a
-- background priority badge cannot be represented by a simple highlight link.
local card = {
    TodoBarToday = { fg = 0x8fbf6f, bold = true },
    TodoBarReview = { fg = 0xe0af68, bold = true },
    TodoBarActive = { fg = 0x5c6370 },
    TodoBarAI = { fg = 0xb48ead, bold = true },
    TodoBarOverdue = { fg = 0xe06c75, bold = true },
    TodoBarUrgent = { fg = 0xe5a15f, bold = true },
    TodoBarHigh = { fg = 0xd7c06a },
    TodoBarAttention = { fg = 0x61afef },
    TodoBarNone = { fg = 0x5c6370 },
    TodoPriorityBadge0 = { fg = 0x000000, bg = 0xe06c75, bold = true },
    TodoPriorityBadge1 = { fg = 0x000000, bg = 0xe5a15f, bold = true },
    TodoPriorityBadge2 = { fg = 0x000000, bg = 0x61afef, bold = true },
    TodoPriorityBadge3 = { fg = 0x9aa0aa, bg = 0x2c313a },
    TodoDueOverdue = { fg = 0xe06c75, bold = true },
    TodoDueToday = { fg = 0xe5a15f, bold = true },
    TodoDueSoon = { fg = 0xd7c06a },
    TodoDueLater = { fg = 0x61afef },
    TodoDueNone = { fg = 0x5c6370 },
}

local function fg_of(group)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and type(hl) == "table" then
        return hl.fg
    end
end

function M.setup()
    for name, target in pairs(links) do
        vim.api.nvim_set_hl(0, name, { default = true, link = target })
    end
    for name, value in pairs(card) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, value))
    end
    -- Dynamic hint text: normal fg, explicitly not bold/italic, no forced bg.
    local hint_text = { default = true, bold = false, italic = false }
    local normal_fg = fg_of("Normal")
    if normal_fg then
        hint_text.fg = normal_fg
    end
    vim.api.nvim_set_hl(0, "TodoHintText", hint_text)
    -- Key tokens: Special fg, bold, not italic, no forced bg.
    local hint_key = { default = true, bold = true, italic = false }
    local special_fg = fg_of("Special")
    if special_fg then
        hint_key.fg = special_fg
    end
    vim.api.nvim_set_hl(0, "TodoHintKey", hint_key)
end

function M.tag(name)
    local hash = 0
    for index = 1, #name do
        hash = (hash * 31 + name:byte(index)) % 8
    end
    return "TodoTag" .. (hash + 1)
end

return M
