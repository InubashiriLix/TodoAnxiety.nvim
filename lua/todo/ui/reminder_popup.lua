local config = require("todo.config")
local duration = require("todo.duration")
local i18n = require("todo.i18n")

local Input = require("nui.input")
local Popup = require("nui.popup")

local M = {}
local current

local function remember_focus()
    local winid = vim.api.nvim_get_current_win()
    return {
        winid = winid,
        cursor = vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_cursor(winid) or nil,
        mode = vim.api.nvim_get_mode().mode,
    }
end

local function restore_focus(origin)
    if origin.winid and vim.api.nvim_win_is_valid(origin.winid) then
        vim.api.nvim_set_current_win(origin.winid)
        if origin.cursor then
            pcall(vim.api.nvim_win_set_cursor, origin.winid, origin.cursor)
        end
        if origin.mode:sub(1, 1) == "i" then
            vim.schedule(function()
                if vim.api.nvim_get_current_win() == origin.winid then
                    vim.cmd("startinsert")
                end
            end)
        end
    end
end

function M.show(task, callback)
    if current then
        current.finish("dismiss")
    end
    local owner = { origin = remember_focus(), closed = false }
    current = owner

    local function finish(action, value)
        if owner.closed then
            return
        end
        owner.closed = true
        if owner.help then
            pcall(function() owner.help:unmount() end)
            owner.help = nil
        end
        if owner.component then
            pcall(function()
                owner.component:unmount()
            end)
        end
        current = nil
        restore_focus(owner.origin)
        callback(action, value)
    end
    owner.finish = finish

    local hints = require("todo.ui.hints")
    local function L(en, zh)
        return config.get().language == "zh-CN" and zh or en
    end
    local function entry(key, label)
        return { key = key, label = label, group = L("Reminder", "提醒") }
    end
    local function eligible()
        return require("todo.ui.actions").allowed(task, "postpone")
    end
    local function alive()
        return not owner.closed and current == owner
    end
    local show_main, open_duration
    local function schedule_main()
        vim.schedule(function()
            if alive() then
                show_main()
            end
        end)
    end
    open_duration = function(action, initial)
        if not alive() then
            return
        end
        if owner.component and owner.component.winid then
            owner.component:unmount()
        end
        local input
        input = Input({
            relative = "editor",
            position = "50%",
            size = { width = math.max(10, math.min(58, vim.o.columns - 6)) },
            border = { style = config.get().ui.float.border,
                text = { top = " " .. i18n.t(action == "postpone" and "postpone_title" or "snooze") .. " " } },
            zindex = 210,
        }, {
            default_value = initial,
            on_submit = function(value)
                if not alive() or owner.component ~= input then
                    return
                end
                local seconds = duration.parse(value)
                local target = seconds and (os.time() + seconds) or math.huge
                local valid = seconds and seconds < math.huge and target < math.huge
                if valid and action == "postpone" then
                    local ok, text = pcall(os.date, "%Y-%m-%d %H:%M", math.ceil(target / 60) * 60)
                    valid = ok and text:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$") ~= nil
                end
                if valid then
                    finish(action, seconds)
                else
                    vim.notify(i18n.t("invalid_duration"), vim.log.levels.ERROR)
                    vim.schedule(function()
                        if alive() and owner.component == input then
                            open_duration(action, value)
                        end
                    end)
                end
            end,
            on_close = function()
                if alive() and owner.component == input then
                    schedule_main()
                end
            end,
        })
        owner.component = input
        input:mount()
        local cancel = function()
            if alive() and owner.component == input then
                input:unmount()
            end
        end
        for _, key in ipairs({ "q", "<Esc>" }) do
            vim.keymap.set("n", key, cancel, { buffer = input.bufnr, silent = true })
        end
        vim.keymap.set("i", "<Esc>", function() vim.schedule(cancel) end, { buffer = input.bufnr, silent = true })
        vim.keymap.set({ "n", "i" }, "<C-q>", function() vim.schedule(cancel) end,
            { buffer = input.bufnr, silent = true })
        hints.attach(input.bufnr, function(mode)
            local entries = {
                entry("Enter", L("Apply duration", "应用时长")),
                entry("Esc / Ctrl-q", L("Back to reminder", "返回提醒框")),
            }
            if mode:sub(1, 1) == "n" then
                entries[#entries + 1] = entry("q", L("Back to reminder", "返回提醒框"))
                entries[#entries + 1] = entry("i", L("Edit duration", "输入时长"))
            end
            return { title = i18n.t(action == "postpone" and "postpone_title" or "snooze"), actions = entries }
        end, { owner = owner })
    end
    show_main = function()
        if not alive() then
            return
        end
        local reminder = task.reminder or {}
        local function context()
            local entries = {
                entry("d", task.kind == "notice" and L("Complete occurrence", "完成本轮") or L("Complete task", "完成任务")),
                entry("s", L("Snooze reminders", "稍后提醒")),
            }
            if eligible() then
                entries[#entries + 1] = entry("p", L("Postpone deadline (1d default)", "延期截止时间（默认1d）"))
            end
            entries[#entries + 1] = entry("a", L("Archive", "归档"))
            vim.list_extend(entries, require("todo.ui.history").actions())
            entries[#entries + 1] = entry("q / Esc / Ctrl-q", L("Close this reminder", "仅关闭本次提醒"))
            return { title = i18n.t("reminder_due"), actions = entries }
        end
        local width = math.max(10, math.min(68, vim.o.columns - 6))
        local lines = {
            "", "  " .. task.title, "",
            "  " .. i18n.t("trigger") .. ": " .. os.date("%Y-%m-%d %H:%M:%S", reminder.scheduled_at or os.time()),
            "  " .. i18n.t("reminder_interval") .. ": " .. duration.format(reminder.repeat_interval_seconds), "",
        }
        vim.list_extend(lines, hints.lines(context().actions, width, 3))
        local popup = Popup({
            relative = "editor", position = "50%",
            size = { width = width, height = math.max(1, math.min(#lines, vim.o.lines - 6)) },
            enter = true,
            border = { style = config.get().ui.float.border,
                text = { top = " " .. i18n.t("reminder_due") .. " ", top_align = "center" } },
            win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoPriority0" },
            zindex = 200,
        })
        owner.component = popup
        popup:mount()
        vim.cmd("stopinsert")
        vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
        hints.highlight(popup.bufnr, 6, #lines)
        require("todo.ui.history").attach(popup.bufnr)
        local map = function(key, cb)
            vim.keymap.set("n", key, cb, { buffer = popup.bufnr, silent = true })
        end
        map("d", function() finish("complete") end)
        map("a", function() finish("archive") end)
        for _, key in ipairs({ "q", "<Esc>", "<C-q>" }) do
            map(key, function() finish("dismiss") end)
        end
        map("s", function() open_duration("snooze", duration.format(reminder.repeat_interval_seconds)) end)
        map("p", function()
            if eligible() then
                open_duration("postpone", "1d")
            else
                vim.notify(i18n.t("postpone_ineligible"), vim.log.levels.WARN)
            end
        end)
        hints.attach(popup.bufnr, context, { owner = owner })
    end

    show_main()
end

function M.close()
    if current then
        current.finish("dismiss")
    end
end

function M.inspect_state()
    return current
end

return M
