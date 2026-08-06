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

    local function show_main()
        local reminder = task.reminder or {}
        local popup = Popup({
            relative = "editor",
            position = "50%",
            size = { width = math.max(36, math.min(68, vim.o.columns - 8)), height = 9 },
            enter = true,
            border = {
                style = config.get().ui.float.border,
                text = { top = " " .. i18n.t("reminder_due") .. " ", top_align = "center" },
            },
            win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoPriority0" },
            zindex = 200,
        })
        owner.component = popup
        popup:mount()
        vim.cmd("stopinsert")
        vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, {
            "",
            "  " .. task.title,
            "",
            "  " .. i18n.t("trigger") .. ": " .. os.date("%Y-%m-%d %H:%M:%S", reminder.scheduled_at or os.time()),
            "  " .. i18n.t("reminder_interval") .. ": " .. duration.format(reminder.repeat_interval_seconds),
            "",
            "  " .. i18n.t("reminder_help"),
        })
        vim.keymap.set("n", "d", function()
            finish("complete")
        end, { buffer = popup.bufnr, silent = true })
        vim.keymap.set("n", "a", function()
            finish("archive")
        end, { buffer = popup.bufnr, silent = true })
        vim.keymap.set("n", "q", function()
            finish("dismiss")
        end, { buffer = popup.bufnr, silent = true })
        vim.keymap.set("n", "<Esc>", function()
            finish("dismiss")
        end, { buffer = popup.bufnr, silent = true })
        vim.keymap.set("n", "<C-q>", function()
            finish("dismiss")
        end, { buffer = popup.bufnr, silent = true })
        vim.keymap.set("n", "s", function()
            popup:unmount()
            local input = Input({
                relative = "editor",
                position = "50%",
                size = { width = 42 },
                border = { style = config.get().ui.float.border, text = { top = " " .. i18n.t("snooze") .. " " } },
                zindex = 210,
            }, {
                default_value = duration.format(reminder.repeat_interval_seconds),
                on_submit = function(value)
                    local seconds = duration.parse(value)
                    if seconds then
                        finish("snooze", seconds)
                    else
                        vim.notify(i18n.t("invalid_duration"), vim.log.levels.ERROR)
                        vim.schedule(show_main)
                    end
                end,
                on_close = function()
                    vim.schedule(show_main)
                end,
            })
            owner.component = input
            input:mount()
            local cancel_snooze = function()
                input:unmount()
            end
            vim.keymap.set("n", "q", cancel_snooze, { buffer = input.bufnr, silent = true })
            vim.keymap.set("n", "<Esc>", cancel_snooze, { buffer = input.bufnr, silent = true })
            vim.keymap.set("i", "<Esc>", function()
                vim.schedule(cancel_snooze)
            end, { buffer = input.bufnr, silent = true })
            vim.keymap.set({ "n", "i" }, "<C-q>", cancel_snooze, { buffer = input.bufnr, silent = true })
        end, { buffer = popup.bufnr, silent = true })
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
