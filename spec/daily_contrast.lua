package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
require("todo.config").setup({ reminders = { enabled = false } })
local view = require("todo.ui.daily_view")
local contrast = require("todo.ui.contrast")
for _, theme in ipairs({
    { fg = 0x747894, bg = 0x171a21 },
    { fg = 0x999999, bg = 0xffffff },
    { fg = 0x8288ad, bg = 0x1a1b26 },
}) do
    vim.api.nvim_set_hl(0, "Normal", theme)
    vim.api.nvim_set_hl(0, "DiagnosticInfo", { fg = 0x446677 })
    view.theme()
    for _, case in ipairs({
        { "Text", 9 },
        { "Muted", 4.5 },
        { "Key", 4.5 },
        { "Accent", 4.5 },
        { "Included", 4.5 },
        { "Error", 4.5 },
        { "Rule", 3 },
        { "Excluded", 3 },
    }) do
        local hl = vim.api.nvim_get_hl(0, { name = "TodoDaily" .. case[1], link = false })
        assert(contrast.ratio(hl.fg, theme.bg) >= case[2], case[1] .. " is too dim")
    end
    local panel = vim.api.nvim_get_hl(0, { name = "TodoDailyPanel", link = false })
    assert(contrast.ratio(panel.fg, panel.bg) >= 9)
end
vim.api.nvim_set_hl(0, "TodoDailyKey", { fg = 0x123456 })
view.theme()
assert(vim.api.nvim_get_hl(0, { name = "TodoDailyKey", link = false }).fg == 0x123456, "explicit override was lost")
local doc = view.doc(80)
doc:text("Readable AI prose")
assert(doc.spans[1].hl == "TodoDailyText", "prose must not inherit dim Markdown syntax")
print("ok - dark/light contrast, theme refresh, prose foreground and explicit user overrides")
vim.cmd("qa!")
