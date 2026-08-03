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
    TodoTag1 = "DiagnosticOk",
    TodoTag2 = "DiagnosticInfo",
    TodoTag3 = "DiagnosticHint",
    TodoTag4 = "DiagnosticWarn",
    TodoTag5 = "String",
    TodoTag6 = "Identifier",
    TodoTag7 = "Type",
    TodoTag8 = "Special",
}

function M.setup()
    for name, target in pairs(links) do
        vim.api.nvim_set_hl(0, name, { default = true, link = target })
    end
end

function M.tag(name)
    local hash = 0
    for index = 1, #name do
        hash = (hash * 31 + name:byte(index)) % 8
    end
    return "TodoTag" .. (hash + 1)
end

return M
