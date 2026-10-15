-- Shared helpers for contextual hints in todo.nvim forms, pickers and panels.
--
-- The host provides the generic renderer in `todo.ui.hints`. This module owns
-- only the bilingual label helper, the graded hint-entry builder and a guarded
-- accessor for the shared hints module (so forms keep working when the host has
-- not wired `todo.ui.hints` yet). It intentionally contains no help renderer.
local M = {}

local function language()
    local ok, cfg = pcall(function()
        return require("todo.config").get()
    end)
    return ok and cfg.language or "en"
end

-- Pick the localized string for the active language.
function M.L(en, zh)
    return language() == "zh-CN" and zh or en
end

-- Build a localized hint entry descriptor as understood by todo.ui.hints.
-- modes is optional; when omitted the entry is shown for every mode.
function M.e(key, label_en, label_zh, group_en, group_zh, modes)
    return {
        key = key,
        label = M.L(label_en, label_zh),
        group = M.L(group_en, group_zh),
        modes = modes,
    }
end

-- Group labels used across every todo.nvim context provider.
function M.groups()
    return {
        nav = M.L("Move", "移动"),
        field = M.L("Field", "字段"),
        edit = M.L("Edit", "编辑"),
        form = M.L("Form", "表单"),
        submit = M.L("Submit", "提交"),
        close = M.L("Close", "关闭"),
        list = M.L("List", "列表"),
        manage = M.L("Manage", "管理"),
        picker = M.L("Picker", "选择器"),
    }
end

function M.hints()
    return require("todo.ui.hints")
end

return M
