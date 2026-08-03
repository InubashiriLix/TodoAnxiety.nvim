local config = require("todo.config")
local duration = require("todo.duration")
local highlights = require("todo.ui.highlights")
local i18n = require("todo.i18n")
local model = require("todo.model")
local CalendarState = require("todo.ui.calendar_state")
local FormState = require("todo.ui.form_state")
local TimeState = require("todo.ui.time_state")

local Input = require("nui.input")
local Layout = require("nui.layout")
local Line = require("nui.line")
local Menu = require("nui.menu")
local Popup = require("nui.popup")
local Text = require("nui.text")

local M = {}
local current

local function border(label)
    return {
        style = config.get().ui.float.border,
        text = { top = " " .. label .. " ", top_align = "left" },
    }
end

local function popup(label, opts)
    opts = opts or {}
    return Popup({
        enter = opts.enter or false,
        focusable = opts.focusable ~= false,
        border = opts.border == false and "none" or border(label),
        buf_options = { buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = true },
        win_options = {
            wrap = opts.wrap or false,
            cursorline = opts.cursorline or false,
            winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder,CursorLine:TodoSelected",
        },
    })
end

local function input(label, value, on_change)
    return Input({
        border = border(label),
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    }, {
        default_value = value or "",
        on_change = on_change,
        on_close = function() end,
    })
end

local function set_lines(component, lines)
    if not vim.api.nvim_buf_is_valid(component.bufnr) then
        return
    end
    vim.bo[component.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, lines)
    vim.bo[component.bufnr].modifiable = false
end

local function set_input(component, value)
    if not vim.api.nvim_buf_is_valid(component.bufnr) then
        return
    end
    vim.bo[component.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, { value or "" })
    if component.winid and vim.api.nvim_win_is_valid(component.winid) then
        pcall(vim.api.nvim_win_set_cursor, component.winid, { 1, #(value or "") })
    end
end

local function write_display(component, callback)
    if not vim.api.nvim_buf_is_valid(component.bufnr) then
        return
    end
    vim.bo[component.bufnr].modifiable = true
    local ok, err = xpcall(callback, debug.traceback)
    if vim.api.nvim_buf_is_valid(component.bufnr) then
        vim.bo[component.bufnr].modifiable = false
    end
    if not ok then
        error(err)
    end
end

local function open_menu(owner, title, values, selected, on_submit, on_close)
    if owner.transient then
        owner.transient:unmount()
    end
    local items = {}
    for _, item in ipairs(values) do
        local label = item.label
        if item.value == selected then
            label = "✓ " .. label
        end
        items[#items + 1] = Menu.item(label, { value = item.value })
    end
    local menu = Menu({
        relative = "editor",
        position = "50%",
        border = { style = config.get().ui.float.border, text = { top = " " .. title .. " ", top_align = "center" } },
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder,CursorLine:TodoSelected" },
        zindex = 80,
    }, {
        lines = items,
        min_width = 24,
        max_height = 10,
        on_close = function()
            owner.transient = nil
            if on_close then
                on_close()
            end
        end,
        on_submit = function(item)
            owner.transient = nil
            on_submit(item.value)
        end,
    })
    owner.transient = menu
    menu:mount()
end

local function render_text(component, value, hl)
    set_lines(component, { " " .. value })
    vim.api.nvim_buf_clear_namespace(component.bufnr, component.ns_id, 0, -1)
    vim.api.nvim_buf_set_extmark(component.bufnr, component.ns_id, 0, 1, {
        end_col = 1 + #value,
        hl_group = hl,
    })
end

local function form_size()
    return {
        width = math.max(40, math.min(92, vim.o.columns - 4)),
        height = math.max(18, math.min(32, vim.o.lines - 4)),
    }
end

function M.open(task, on_save, opts)
    opts = opts or {}
    if current and current.force_close then
        current.force_close("replaced")
    end
    highlights.setup()

    local owner = { state = FormState.new(task), transient = nil, closed = false }
    local state = owner.state
    local components = {}
    local focusables = {}
    local focus_index = 1
    local tag_pending = ""
    local save, request_close, render_tags, queue_render_tags, commit_tag, open_calendar, open_time_picker, open_tag_panel
    local open_duration_picker

    components.header = popup("", { border = false, focusable = false })
    components.title = input(i18n.t("title"), state:get("title"), function(value)
        state:set("title", value)
    end)
    components.priority = popup(i18n.t("priority"), { enter = true })
    components.status = popup(i18n.t("status"), { enter = true })
    components.deadline = popup(i18n.t("deadline"), { enter = true })
    components.reminder_interval = input(i18n.t("reminder_interval"), state:get("reminder_interval"), function(value)
        state:set("reminder_interval", value)
    end)
    components.tag_chips = popup(i18n.t("tags"), { focusable = false })
    components.tag_input = input(i18n.t("add_tag"), "", function(value)
        tag_pending = value
    end)
    components.description = popup(i18n.t("description"), { enter = true, wrap = true })
    components.footer = popup("", { border = false, enter = true })
    owner.components = components

    focusables = {
        { component = components.title,             insert = true },
        { component = components.priority,          insert = false },
        { component = components.status,            insert = false },
        { component = components.deadline,          insert = false },
        { component = components.reminder_interval, insert = true },
        { component = components.tag_input,         insert = true },
        { component = components.description,       insert = true },
        { component = components.footer,            insert = false },
    }

    local function focus(index)
        if owner.closed then
            return
        end
        local previous = focus_index
        if previous == 1 then
            local invalid = vim.trim(state:get("title")) == ""
            components.title.border:set_highlight(invalid and "TodoError" or "TodoBorder")
            components.title.border:set_text("bottom", invalid and (" " .. i18n.t("title_required") .. " ") or "",
                "right")
        elseif previous == 6 and tag_pending ~= "" and commit_tag then
            commit_tag()
        end
        if index < 1 then
            index = #focusables
        elseif index > #focusables then
            index = 1
        end
        focus_index = index
        local target = focusables[index]
        if not target.component.winid or not vim.api.nvim_win_is_valid(target.component.winid) then
            return
        end
        vim.cmd("stopinsert")
        vim.api.nvim_set_current_win(target.component.winid)
        if target.insert then
            vim.cmd("startinsert")
        end
    end

    local function render_priority()
        write_display(components.priority, function()
            local line = Line()
            line:append(" ")
            for value = 0, 3 do
                local priority = "P" .. value
                local text = state:get("priority") == priority and ("[" .. priority .. "] ") or (" " .. priority .. "  ")
                line:append(Text(text, "TodoPriority" .. value))
            end
            line:render(components.priority.bufnr, components.priority.ns_id, 1)
        end)
        components.priority.border:set_text("bottom", " " .. i18n.t("priority_hint") .. " ", "right")
    end

    local function render_selects()
        render_priority()
        local status_hl = {
            todo = "TodoStatusTodo",
            in_progress = "TodoStatusInProgress",
            done = "TodoStatusDone",
            cancelled = "TodoStatusCancelled",
        }
        write_display(components.status, function()
            local line = Line()
            line:append(" ")
            for _, status in ipairs({ "todo", "in_progress", "done", "cancelled" }) do
                local label = i18n.t(status)
                local text = state:get("status") == status and ("[" .. label .. "] ") or (" " .. label .. "  ")
                line:append(Text(text, status_hl[status]))
            end
            line:render(components.status.bufnr, components.status.ns_id, 1)
        end)
        components.status.border:set_text("bottom", " " .. i18n.t("status_hint") .. " ", "right")
    end

    local function render_deadline()
        local value = state:get("deadline")
        render_text(
            components.deadline,
            value ~= "" and ("📅  " .. value) or i18n.t("deadline_empty"),
            value ~= "" and "TodoStatusInProgress" or "TodoMuted"
        )
        components.deadline.border:set_text("bottom", " " .. i18n.t("deadline_hint") .. " ", "right")
    end

    render_tags = function()
        if owner.closed or not vim.api.nvim_buf_is_valid(components.tag_chips.bufnr) then
            return
        end
        write_display(components.tag_chips, function()
            vim.api.nvim_buf_clear_namespace(components.tag_chips.bufnr, components.tag_chips.ns_id, 0, -1)
            vim.api.nvim_buf_set_lines(components.tag_chips.bufnr, 0, -1, false, { "", "" })
            local line = Line()
            if #state:get("tags") == 0 then
                line:append(Text(" " .. i18n.t("no_tags"), "TodoMuted"))
            else
                line:append(" ")
                for _, tag in ipairs(state:get("tags")) do
                    local text = "[" .. tag .. "] "
                    line:append(Text(text, highlights.tag(tag)))
                end
            end
            line:render(components.tag_chips.bufnr, components.tag_chips.ns_id, 1)
            vim.api.nvim_buf_set_lines(components.tag_chips.bufnr, 1, -1, false, {
                " " .. i18n.t("tag_panel_prompt"),
            })
        end)
    end

    local tag_render_scheduled = false
    queue_render_tags = function()
        if tag_render_scheduled or owner.closed then
            return
        end
        tag_render_scheduled = true
        vim.schedule(function()
            tag_render_scheduled = false
            if not owner.closed then
                render_tags()
            end
        end)
    end

    commit_tag = function()
        if vim.trim(tag_pending) ~= "" then
            state:add_tag(tag_pending)
        end
        tag_pending = ""
        vim.schedule(function()
            if not owner.closed then
                set_input(components.tag_input, "")
                render_tags()
            end
        end)
    end
    owner.commit_tag = commit_tag

    open_tag_panel = function()
        vim.cmd("stopinsert")
        owner.tag_panel_open = true
        require("todo.ui.tag_panel").open({
            title = "tag_selector",
            selected = state:get("tags"),
            on_change = function(tags)
                state:set("tags", tags)
                render_tags()
            end,
            on_close = function()
                owner.tag_panel_open = false
                if not owner.closed then
                    render_tags()
                    focus(5)
                end
            end,
        })
    end
    owner.open_tag_panel = open_tag_panel

    open_duration_picker = function()
        if owner.transient then
            owner.transient:unmount()
        end
        vim.cmd("stopinsert")
        local picker
        picker = require("todo.ui.duration_picker").open(state:get("reminder_interval"), {
            on_apply = function(seconds)
                owner.transient = nil
                owner.duration_picker = nil
                local value = duration.format(seconds)
                state:set("reminder_interval", value)
                set_input(components.reminder_interval, value)
                focus(5)
            end,
            on_close = function()
                owner.transient = nil
                owner.duration_picker = nil
                focus(5)
            end,
        })
        owner.duration_picker = picker
        owner.transient = picker.popup
    end
    owner.open_duration_picker = open_duration_picker

    open_time_picker = function(calendar)
        if owner.transient then
            owner.transient:unmount()
        end
        local time = TimeState.new(calendar:value())
        owner.time_state = time
        local time_popup = Popup({
            relative = "editor",
            position = "50%",
            size = { width = 44, height = 7 },
            enter = true,
            border = {
                style = config.get().ui.float.border,
                text = { top = " " .. i18n.t("choose_time") .. " ", top_align = "center" },
            },
            buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false, modifiable = false },
            win_options = { cursorline = false, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
            zindex = 95,
        })
        owner.transient = time_popup

        local function render_time()
            local value_line = string.format(
                "  [%s]  [%s] : [%s]",
                calendar:shifted_date(time.day_offset),
                time:display("hour"),
                time:display("minute")
            )
            set_lines(time_popup, {
                "",
                "     DATE          HH     MM",
                value_line,
                "",
                "  " .. i18n.t("time_picker_nav_hint"),
                "  " .. i18n.t("time_picker_digit_hint"),
                "  " .. i18n.t("time_picker_footer"),
            })
            vim.api.nvim_buf_clear_namespace(time_popup.bufnr, time_popup.ns_id, 0, -1)
            local date_from = assert(value_line:find("[", 1, true)) - 1
            local hour_from = assert(value_line:find("[", date_from + 2, true)) - 1
            local minute_from = assert(value_line:find("[", hour_from + 2, true)) - 1
            vim.api.nvim_buf_set_extmark(time_popup.bufnr, time_popup.ns_id, 2, date_from, {
                end_col = date_from + 12,
                hl_group = "TodoStatusInProgress",
            })
            vim.api.nvim_buf_set_extmark(time_popup.bufnr, time_popup.ns_id, 2, hour_from, {
                end_col = hour_from + 4,
                hl_group = time.field == "hour" and "TodoSelected" or "TodoPriority1",
            })
            vim.api.nvim_buf_set_extmark(time_popup.bufnr, time_popup.ns_id, 2, minute_from, {
                end_col = minute_from + 4,
                hl_group = time.field == "minute" and "TodoSelected" or "TodoPriority1",
            })
        end

        local function close_time()
            if owner.transient == time_popup then
                owner.transient = nil
            end
            time_popup:unmount()
            owner.time_state = nil
            owner.apply_time = nil
            owner.calendar_state = nil
            owner.choose_calendar_date = nil
            focus(4)
        end

        local function apply_time()
            if not time:commit_digits() then
                vim.notify(i18n.t("invalid_time"), vim.log.levels.ERROR)
                render_time()
                return
            end
            calendar:move_days(time.day_offset)
            calendar:set_time(time:value())
            state:set("deadline", calendar:value())
            render_deadline()
            close_time()
        end

        time_popup:mount()
        render_time()
        local map = function(key, callback)
            vim.keymap.set("n", key, callback, { buffer = time_popup.bufnr, silent = true })
        end
        for _, key in ipairs({ "h", "l", "<Left>", "<Right>", "<Tab>" }) do
            map(key, function()
                time:switch(1)
                render_time()
            end)
        end
        for _, item in ipairs({
            { key = "j", delta = 1 },
            { key = "k", delta = -1 },
            { key = "J", delta = 5 },
            { key = "K", delta = -5 },
        }) do
            map(item.key, function()
                time:move(item.delta)
                render_time()
            end)
        end
        for digit = 0, 9 do
            map(tostring(digit), function()
                if time:input_digit(digit) == false then
                    vim.notify(i18n.t("invalid_time"), vim.log.levels.ERROR)
                end
                render_time()
            end)
        end
        map("<CR>", apply_time)
        map("a", function()
            calendar:set_time("")
            state:set("deadline", calendar:value())
            render_deadline()
            close_time()
        end)
        map("q", close_time)
        map("<C-q>", close_time)
        owner.apply_time = apply_time
    end
    owner.open_time_picker = open_time_picker

    open_calendar = function()
        if owner.transient then
            owner.transient:unmount()
        end
        local calendar = CalendarState.new(state:get("deadline"))
        owner.calendar_state = calendar
        local calendar_popup = Popup({
            relative = "editor",
            position = "50%",
            size = { width = 32, height = 10 },
            enter = true,
            border = {
                style = config.get().ui.float.border,
                text = { top = " " .. i18n.t("calendar") .. " ", top_align = "center" },
            },
            buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false, modifiable = false },
            win_options = { cursorline = false, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
            zindex = 90,
        })
        owner.transient = calendar_popup
        local day_spans = {}

        local function render_calendar()
            local lines = {
                string.format("  ‹          %04d-%02d          ›", calendar.year, calendar.month),
                "  Mo  Tu  We  Th  Fr  Sa  Su",
            }
            day_spans = {}
            local cells = calendar:cells()
            for week = 0, 5 do
                local line = " "
                for weekday = 1, 7 do
                    local day = cells[week * 7 + weekday]
                    local text = day and string.format(" %2d ", day) or "    "
                    if day then
                        day_spans[#day_spans + 1] = {
                            line = week + 3,
                            from = #line + 1,
                            to = #line + #text,
                            day = day,
                        }
                    end
                    line = line .. text
                end
                lines[#lines + 1] = line
            end
            lines[#lines + 1] = " " .. i18n.t("calendar_nav_hint")
            lines[#lines + 1] = " " .. i18n.t("calendar_footer")
            set_lines(calendar_popup, lines)
            vim.api.nvim_buf_clear_namespace(calendar_popup.bufnr, calendar_popup.ns_id, 0, -1)
            for _, span in ipairs(day_spans) do
                local is_selected = span.day == calendar.day
                local is_today = calendar.year == calendar.today.year
                    and calendar.month == calendar.today.month
                    and span.day == calendar.today.day
                if is_selected or is_today then
                    vim.api.nvim_buf_set_extmark(calendar_popup.bufnr, calendar_popup.ns_id, span.line - 1, span.from - 1,
                        {
                            end_col = span.to,
                            hl_group = is_selected and "TodoSelected" or "TodoStatusInProgress",
                        })
                end
            end
        end

        local function close_calendar()
            if owner.transient == calendar_popup then
                owner.transient = nil
            end
            calendar_popup:unmount()
            owner.calendar_state = nil
            owner.choose_calendar_date = nil
            focus(4)
        end

        local function apply_calendar()
            state:set("deadline", calendar:value())
            render_deadline()
            close_calendar()
        end
        owner.choose_calendar_date = apply_calendar

        calendar_popup:mount()
        render_calendar()
        local map = function(key, callback)
            vim.keymap.set("n", key, callback, { buffer = calendar_popup.bufnr, silent = true })
        end
        map("h", function()
            calendar:move_days(-1)
            render_calendar()
        end)
        map("l", function()
            calendar:move_days(1)
            render_calendar()
        end)
        map("j", function()
            calendar:move_days(7)
            render_calendar()
        end)
        map("k", function()
            calendar:move_days(-7)
            render_calendar()
        end)
        for _, key in ipairs({ "[", "H", "<PageUp>" }) do
            map(key, function()
                calendar:shift_month(-1)
                render_calendar()
            end)
        end
        for _, key in ipairs({ "]", "L", "<PageDown>" }) do
            map(key, function()
                calendar:shift_month(1)
                render_calendar()
            end)
        end
        map("<CR>", apply_calendar)
        map("g", function()
            calendar:set_today()
            render_calendar()
        end)
        map("x", function()
            state:set("deadline", "")
            render_deadline()
            close_calendar()
        end)
        map("t", function()
            open_time_picker(calendar)
        end)
        map("q", close_calendar)
        map("<C-q>", close_calendar)
    end
    owner.open_calendar = open_calendar

    local function priority_menu()
        local values = {}
        for value = 0, 3 do
            values[#values + 1] = { label = "P" .. value, value = "P" .. value }
        end
        open_menu(owner, i18n.t("priority"), values, state:get("priority"), function(value)
            state:set("priority", value)
            render_selects()
            focus(2)
        end, function()
            focus(2)
        end)
    end

    local function set_priority(value)
        state:set("priority", "P" .. tostring(value))
        render_selects()
    end

    local function cycle_priority(delta)
        local current_priority = tonumber(state:get("priority"):sub(2)) or 2
        set_priority((current_priority + delta) % 4)
    end

    local function status_menu()
        local values = {}
        for _, value in ipairs({ "todo", "in_progress", "done", "cancelled" }) do
            values[#values + 1] = { label = i18n.t(value), value = value }
        end
        open_menu(owner, i18n.t("status"), values, state:get("status"), function(value)
            state:set("status", value)
            render_selects()
            focus(3)
        end, function()
            focus(3)
        end)
    end

    local statuses = { "todo", "in_progress", "done", "cancelled" }
    local function set_status(index)
        state:set("status", statuses[index])
        render_selects()
    end

    local function cycle_status(delta)
        local current_index = 1
        for index, status in ipairs(statuses) do
            if status == state:get("status") then
                current_index = index
                break
            end
        end
        set_status((current_index - 1 + delta) % #statuses + 1)
    end

    local function clear_errors()
        for _, component in pairs({
            title = components.title,
            priority = components.priority,
            status = components.status,
            deadline = components.deadline,
            reminder_interval = components.reminder_interval,
        }) do
            component.border:set_highlight("TodoBorder")
            component.border:set_text("bottom", "", "right")
        end
        components.priority.border:set_text("bottom", " " .. i18n.t("priority_hint") .. " ", "right")
        components.status.border:set_text("bottom", " " .. i18n.t("status_hint") .. " ", "right")
        components.deadline.border:set_text("bottom", " " .. i18n.t("deadline_hint") .. " ", "right")
        components.reminder_interval.border:set_text("bottom", " " .. i18n.t("duration_picker_hint") .. " ", "right")
    end

    local function show_errors(errors)
        clear_errors()
        local map = {
            title = { component = components.title, message = i18n.t("title_required"), focus = 1 },
            priority = { component = components.priority, message = i18n.t("invalid_priority"), focus = 2 },
            status = { component = components.status, message = "todo | in_progress | done | cancelled", focus = 3 },
            deadline = { component = components.deadline, message = i18n.t("invalid_deadline"), focus = 4 },
            reminder_interval = {
                component = components.reminder_interval,
                message = i18n.t("invalid_duration"),
                focus = 5,
            },
        }
        local first
        for field in pairs(errors or {}) do
            local target = map[field]
            if target then
                target.component.border:set_highlight("TodoError")
                target.component.border:set_text("bottom", " " .. target.message .. " ", "right")
                first = first or target.focus
            end
        end
        if first then
            focus(first)
        end
    end

    local size = form_size()
    local box = Layout.Box({
        Layout.Box(components.header, { size = 1 }),
        Layout.Box(components.title, { size = 3 }),
        Layout.Box({
            Layout.Box(components.priority, { size = "35%" }),
            Layout.Box(components.status, { size = "65%" }),
        }, { dir = "row", size = 3 }),
        Layout.Box({
            Layout.Box(components.deadline, { size = "65%" }),
            Layout.Box(components.reminder_interval, { size = "35%" }),
        }, { dir = "row", size = 3 }),
        Layout.Box(components.tag_chips, { size = 4 }),
        Layout.Box(components.tag_input, { size = 3 }),
        Layout.Box(components.description, { grow = 1 }),
        Layout.Box(components.footer, { size = 1 }),
    }, { dir = "col" })
    owner.layout = Layout({ relative = "editor", position = "50%", size = size }, box)

    function owner.force_close(reason)
        if owner.closed then
            return
        end
        owner.closed = true
        if owner.transient then
            pcall(function()
                owner.transient:unmount()
            end)
        end
        if owner.tag_panel_open then
            pcall(function()
                require("todo.ui.tag_panel").close()
            end)
            owner.tag_panel_open = false
        end
        if owner.layout then
            pcall(function()
                owner.layout:unmount()
            end)
        end
        if current == owner then
            current = nil
        end
        if opts.on_close then
            vim.schedule(function()
                opts.on_close(reason or "closed")
            end)
        end
    end

    save = function()
        if owner.closed then
            return
        end
        if vim.trim(tag_pending) ~= "" then
            commit_tag()
        end
        local normalized, errors = state:validate()
        if not normalized then
            show_errors(errors)
            return
        end
        clear_errors()
        local ok, result, save_errors = pcall(on_save, state:input())
        if not ok then
            vim.notify(i18n.t("db_error", result), vim.log.levels.ERROR)
            return
        end
        if not result then
            state.errors = save_errors or {}
            show_errors(state.errors)
            vim.notify(i18n.t("save_failed"), vim.log.levels.ERROR)
            return
        end
        state:mark_saved()
        owner.force_close("saved")
        vim.notify(i18n.t("saved"), vim.log.levels.INFO)
    end

    request_close = function()
        if owner.closed then
            return
        end
        if not state:is_dirty() and vim.trim(tag_pending) == "" then
            owner.force_close("cancelled")
            return
        end
        open_menu(
            owner,
            i18n.t("unsaved_title"),
            {
                { label = i18n.t("save"),             value = "save" },
                { label = i18n.t("discard"),          value = "discard" },
                { label = i18n.t("continue_editing"), value = "continue" },
            },
            nil,
            function(value)
                if value == "save" then
                    save()
                elseif value == "discard" then
                    owner.force_close("discarded")
                else
                    focus(focus_index)
                end
            end,
            function()
                focus(focus_index)
            end
        )
    end

    local function map_focus(component, index)
        vim.keymap.set("n", "<Tab>", function()
            focus(index + 1)
        end, { buffer = component.bufnr })
        vim.keymap.set("i", "<Tab>", function()
            vim.schedule(function()
                focus(index + 1)
            end)
        end, { buffer = component.bufnr })
        vim.keymap.set("n", "<S-Tab>", function()
            focus(index - 1)
        end, { buffer = component.bufnr })
        vim.keymap.set("i", "<S-Tab>", function()
            vim.schedule(function()
                focus(index - 1)
            end)
        end, { buffer = component.bufnr })
        vim.keymap.set("n", "q", request_close, { buffer = component.bufnr })
        vim.keymap.set("n", "<C-q>", request_close, { buffer = component.bufnr })
        vim.keymap.set("i", "<C-q>", function()
            vim.schedule(request_close)
        end, { buffer = component.bufnr })
        vim.keymap.set("n", "<C-s>", save, { buffer = component.bufnr })
        vim.keymap.set("i", "<C-s>", function()
            vim.schedule(save)
        end, { buffer = component.bufnr })
    end
    for index, target in ipairs(focusables) do
        map_focus(target.component, index)
    end

    local function enter_next(component, index)
        for _, mode in ipairs({ "n", "i" }) do
            vim.keymap.set(mode, "<CR>", function()
                vim.schedule(function()
                    focus(index + 1)
                end)
            end, { buffer = component.bufnr, silent = true })
        end
    end
    enter_next(components.title, 1)
    enter_next(components.reminder_interval, 5)
    vim.keymap.set("n", "t", open_duration_picker, { buffer = components.reminder_interval.bufnr, silent = true })
    vim.keymap.set("n", "<CR>", function()
        focus(8)
    end, { buffer = components.description.bufnr, silent = true })
    vim.keymap.set("n", "<CR>", function()
        focus(1)
    end, { buffer = components.footer.bufnr, silent = true })

    vim.keymap.set("n", "<CR>", priority_menu, { buffer = components.priority.bufnr })
    for value = 0, 3 do
        vim.keymap.set("n", tostring(value), function()
            set_priority(value)
        end, { buffer = components.priority.bufnr })
    end
    for _, key in ipairs({ "l", "<Right>" }) do
        vim.keymap.set("n", key, function()
            cycle_priority(1)
        end, { buffer = components.priority.bufnr })
    end
    for _, key in ipairs({ "h", "<Left>" }) do
        vim.keymap.set("n", key, function()
            cycle_priority(-1)
        end, { buffer = components.priority.bufnr })
    end
    for _, key in ipairs({ "i", "a", "p", "P" }) do
        vim.keymap.set("n", key, priority_menu, { buffer = components.priority.bufnr })
    end
    vim.keymap.set("n", "<CR>", status_menu, { buffer = components.status.bufnr })
    for index = 1, 4 do
        vim.keymap.set("n", tostring(index), function()
            set_status(index)
        end, { buffer = components.status.bufnr })
    end
    for _, key in ipairs({ "l", "<Right>" }) do
        vim.keymap.set("n", key, function()
            cycle_status(1)
        end, { buffer = components.status.bufnr })
    end
    for _, key in ipairs({ "h", "<Left>" }) do
        vim.keymap.set("n", key, function()
            cycle_status(-1)
        end, { buffer = components.status.bufnr })
    end
    for _, key in ipairs({ "i", "a" }) do
        vim.keymap.set("n", key, status_menu, { buffer = components.status.bufnr })
    end

    vim.keymap.set("n", "<CR>", open_calendar, { buffer = components.deadline.bufnr })
    vim.keymap.set("n", "c", open_calendar, { buffer = components.deadline.bufnr })
    vim.keymap.set("n", "x", function()
        state:set("deadline", "")
        render_deadline()
    end, { buffer = components.deadline.bufnr })
    vim.keymap.set("n", "t", function()
        open_time_picker(CalendarState.new(state:get("deadline")))
    end, { buffer = components.deadline.bufnr })

    local function submit_tag_input()
        vim.schedule(function()
            if vim.trim(tag_pending) == "" then
                open_tag_panel()
            else
                commit_tag()
            end
        end)
    end
    vim.keymap.set({ "n", "i" }, "<CR>", submit_tag_input, { buffer = components.tag_input.bufnr })
    vim.keymap.set("i", ",", function()
        vim.schedule(commit_tag)
    end, { buffer = components.tag_input.bufnr })
    vim.keymap.set("i", "<BS>", function()
        if tag_pending == "" then
            state:remove_last_tag()
            queue_render_tags()
            return ""
        end
        return "<BS>"
    end, { buffer = components.tag_input.bufnr, expr = true })
    components.tag_input.border:set_text("bottom", " " .. i18n.t("tag_input_hint") .. " ", "right")
    components.reminder_interval.border:set_text("bottom", " " .. i18n.t("duration_picker_hint") .. " ", "right")

    local footer_text = " " .. i18n.t("form_footer")

    owner.layout:mount()
    current = owner
    set_lines(components.header, { "  " .. i18n.t(task and task.id and "form_title_edit" or "form_title_new") })
    vim.api.nvim_buf_add_highlight(components.header.bufnr, components.header.ns_id, "TodoHeader", 0, 2, -1)
    render_selects()
    render_deadline()
    render_tags()
    set_lines(
        components.description,
        vim.split(state:get("description") ~= "" and state:get("description") or "", "\n", { plain = true })
    )
    vim.bo[components.description.bufnr].modifiable = true
    set_lines(components.footer, { footer_text })
    vim.api.nvim_buf_add_highlight(components.footer.bufnr, components.footer.ns_id, "TodoMuted", 0, 0, -1)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = components.description.bufnr,
        callback = function()
            if not owner.closed then
                state:set(
                    "description",
                    table.concat(vim.api.nvim_buf_get_lines(components.description.bufnr, 0, -1, false), "\n")
                )
            end
        end,
    })
    vim.schedule(function()
        if not owner.closed then
            focus(1)
        end
    end)
    owner.request_close = request_close
end

function M.close(force)
    if not current then
        return
    end
    if force then
        current.force_close("forced")
    else
        current.request_close()
    end
end

function M.inspect_state()
    return current
end

return M
