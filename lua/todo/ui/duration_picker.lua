local config = require("todo.config")
local i18n = require("todo.i18n")
local DurationState = require("todo.ui.duration_state")

local Popup = require("nui.popup")

local M = {}

local function set_lines(component, lines)
    vim.bo[component.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, lines)
    vim.bo[component.bufnr].modifiable = false
end

function M.open(value, opts)
    opts = opts or {}
    require("todo.ui.highlights").setup()
    local state = DurationState.new(value)
    local popup = Popup({
        relative = "editor",
        position = "50%",
        size = { width = 58, height = 7 },
        enter = true,
        border = {
            style = config.get().ui.float.border,
            text = { top = " " .. i18n.t("duration_picker") .. " ", top_align = "center" },
        },
        buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false, modifiable = false },
        win_options = { cursorline = false, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
        zindex = 150,
    })
    local owner = { popup = popup, state = state, closed = false }

    local function render()
        local value_line = string.format(
            "        [%s]       [%s]       [%s]       [%s]",
            state:display("days"),
            state:display("hours"),
            state:display("minutes"),
            state:display("seconds")
        )
        set_lines(popup, {
            "        DD         HH         MM         SS",
            value_line,
            "",
            "  " .. i18n.t("duration_picker_nav_hint"),
            "  " .. i18n.t("duration_picker_digit_hint"),
            "  " .. i18n.t("duration_picker_footer"),
        })
        vim.api.nvim_buf_clear_namespace(popup.bufnr, popup.ns_id, 0, -1)
        local spans, search_from = {}, 1
        for index = 1, 4 do
            local open_at = assert(value_line:find("[", search_from, true))
            local close_at = assert(value_line:find("]", open_at + 1, true))
            spans[index] = { from = open_at - 1, to = close_at }
            search_from = close_at + 1
        end
        for index, span in ipairs(spans) do
            vim.api.nvim_buf_set_extmark(popup.bufnr, popup.ns_id, 1, span.from, {
                end_col = span.to,
                hl_group = state.field_index == index and "TodoSelected" or "TodoPriority1",
            })
        end
    end
    owner.render = render

    local function finish(applied)
        if owner.closed then
            return
        end
        owner.closed = true
        popup:unmount()
        if applied then
            opts.on_apply(state:value())
        elseif opts.on_close then
            opts.on_close()
        end
    end

    local function apply()
        if not state:commit_digits() then
            vim.notify(i18n.t("duration_picker_zero"), vim.log.levels.ERROR)
            render()
            return
        end
        finish(true)
    end
    owner.apply = apply
    owner.close = function()
        finish(false)
    end

    popup:mount()
    render()
    local map = function(key, callback)
        vim.keymap.set("n", key, callback, { buffer = popup.bufnr, silent = true })
    end
    for _, key in ipairs({ "l", "<Right>", "<Tab>" }) do
        map(key, function()
            state:switch(1)
            render()
        end)
    end
    for _, key in ipairs({ "h", "<Left>", "<S-Tab>" }) do
        map(key, function()
            state:switch(-1)
            render()
        end)
    end
    for _, item in ipairs({ { "j", 1 }, { "k", -1 }, { "J", 5 }, { "K", -5 } }) do
        map(item[1], function()
            state:move(item[2])
            render()
        end)
    end
    for digit = 0, 9 do
        map(tostring(digit), function()
            state:input_digit(digit)
            render()
        end)
    end
    map("<CR>", apply)
    map("q", owner.close)
    map("<C-q>", owner.close)
    return owner
end

return M
