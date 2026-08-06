local config = require("todo.config")
local duration = require("todo.duration")
local highlights = require("todo.ui.highlights")
local i18n = require("todo.i18n")
local model = require("todo.model")
local CalendarState = require("todo.ui.calendar_state")
local TimeState = require("todo.ui.time_state")

local Input = require("nui.input")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
local Popup = require("nui.popup")

local M = {}
local current
local recurrence_kinds = { "once", "daily", "weekdays", "weekly", "interval" }

local function popup(label, enter)
    return Popup({
        enter = enter == true,
        border = { style = config.get().ui.float.border, text = { top = label and (" " .. label .. " ") or "" } },
        buf_options = { buftype = "nofile", bufhidden = "hide", swapfile = false },
        win_options = { wrap = false, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    })
end

local function input(label, value, on_change)
    return Input({
        border = { style = config.get().ui.float.border, text = { top = " " .. label .. " " } },
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    }, { default_value = value or "", on_change = on_change })
end

local function parse_weekdays(value)
    local names = {
        sun = 1,
        mon = 2,
        tue = 3,
        wed = 4,
        thu = 5,
        fri = 6,
        sat = 7,
        ["周日"] = 1,
        ["周天"] = 1,
        ["日"] = 1,
        ["天"] = 1,
        ["周一"] = 2,
        ["一"] = 2,
        ["周二"] = 3,
        ["二"] = 3,
        ["周三"] = 4,
        ["三"] = 4,
        ["周四"] = 5,
        ["四"] = 5,
        ["周五"] = 6,
        ["五"] = 6,
        ["周六"] = 7,
        ["六"] = 7,
    }
    local result, seen = {}, {}
    for token in tostring(value or ""):lower():gmatch("[^,%s]+") do
        local day = names[token] or tonumber(token)
        if not day or day < 1 or day > 7 or seen[day] then
            return nil
        end
        seen[day] = true
        result[#result + 1] = day
    end
    table.sort(result)
    return #result > 0 and result or nil
end

local function recurrence_from(fields)
    if fields.recurrence == "weekly" then
        local weekdays = parse_weekdays(fields.recurrence_spec)
        return weekdays and { kind = "weekly", weekdays = weekdays, every = 1 } or nil
    elseif fields.recurrence == "interval" then
        local amount, unit = fields.recurrence_spec:lower():match("^(%d+)%s*([mhd])$")
        local units = { m = "minutes", h = "hours", d = "days" }
        return amount
                and tonumber(amount) > 0
                and {
                    kind = "interval",
                    every = tonumber(amount),
                    unit = units[unit],
                }
            or nil
    end
    return { kind = fields.recurrence, every = 1 }
end

local function recurrence_spec(task)
    local rule = task.reminder and task.reminder.recurrence or {}
    if rule.kind == "weekly" then
        return table.concat(rule.weekdays or {}, ",")
    elseif rule.kind == "interval" then
        local units = { minutes = "m", hours = "h", days = "d" }
        return tostring(rule.every or 1) .. (units[rule.unit] or "h")
    end
    return ""
end

function M.open(task, on_save, opts)
    opts = opts or {}
    if current then
        current.close("replaced")
    end
    task = task or {}
    highlights.setup()
    local fields = {
        title = task.title or "",
        trigger = model.deadline_text(task),
        reminder_interval = task.reminder and duration.format(task.reminder.repeat_interval_seconds)
            or opts.default_interval
            or "",
        recurrence = task.reminder and task.reminder.recurrence.kind or "once",
        recurrence_spec = recurrence_spec(task),
        tags = table.concat(task.tags or {}, ", "),
        description = task.description or "",
    }
    local initial = vim.deepcopy(fields)
    local owner = { closed = false, fields = fields, transient = nil }
    current = owner
    local components = {}
    local focusables = {}
    local focus_index = 1

    components.header = popup(nil, false)
    components.title = input(i18n.t("title"), fields.title, function(value)
        fields.title = value
    end)
    components.trigger = input(i18n.t("trigger"), fields.trigger, function(value)
        fields.trigger = value
    end)
    components.interval = input(i18n.t("reminder_interval"), fields.reminder_interval, function(value)
        fields.reminder_interval = value
    end)
    components.recurrence = popup(i18n.t("recurrence"), true)
    components.recurrence_spec = input(i18n.t("recurrence"), fields.recurrence_spec, function(value)
        fields.recurrence_spec = value
    end)
    components.tags = input(i18n.t("tags"), fields.tags, function(value)
        fields.tags = value
    end)
    components.description = popup(i18n.t("description"), true)
    components.footer = popup(nil, true)
    owner.components = components

    focusables = {
        { component = components.title, insert = true },
        { component = components.trigger, insert = true },
        { component = components.interval, insert = true },
        { component = components.recurrence, insert = false },
        { component = components.recurrence_spec, insert = true },
        { component = components.tags, insert = true },
        { component = components.description, insert = true },
        { component = components.footer, insert = false },
    }

    local function set_lines(component, lines, modifiable)
        vim.bo[component.bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, lines)
        vim.bo[component.bufnr].modifiable = modifiable == true
    end

    local function render_recurrence()
        local bits = {}
        for index, kind in ipairs(recurrence_kinds) do
            local label = i18n.t("recurrence_" .. kind)
            bits[#bits + 1] = fields.recurrence == kind and ("[" .. index .. " " .. label .. "]")
                or (index .. " " .. label)
        end
        set_lines(components.recurrence, { " " .. table.concat(bits, "  ") })
        local hint = fields.recurrence == "weekly" and (" " .. i18n.t("recurrence_weekly_hint") .. " ")
            or fields.recurrence == "interval" and (" " .. i18n.t("recurrence_interval_hint") .. " ")
            or (" " .. i18n.t("recurrence_no_spec") .. " ")
        components.recurrence_spec.border:set_text("bottom", hint, "right")
    end

    local function focus(index)
        if owner.closed then
            return
        end
        focus_index = index < 1 and #focusables or index > #focusables and 1 or index
        local target = focusables[focus_index]
        vim.cmd("stopinsert")
        vim.api.nvim_set_current_win(target.component.winid)
        if target.insert then
            vim.cmd("startinsert")
        end
    end

    local function set_input_value(component, value)
        vim.bo[component.bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, { value })
    end

    local function open_duration_picker()
        vim.cmd("stopinsert")
        local picker
        picker = require("todo.ui.duration_picker").open(fields.reminder_interval, {
            on_apply = function(seconds)
                owner.transient = nil
                owner.duration_picker = nil
                fields.reminder_interval = duration.format(seconds)
                set_input_value(components.interval, fields.reminder_interval)
                focus(3)
            end,
            on_close = function()
                owner.transient = nil
                owner.duration_picker = nil
                focus(3)
            end,
        })
        owner.duration_picker = picker
        owner.transient = picker.popup
    end
    owner.open_duration_picker = open_duration_picker

    local function open_calendar(open_time_immediately)
        local calendar = CalendarState.new(fields.trigger)
        local calendar_popup
        owner.calendar_state = calendar

        local function apply_value()
            fields.trigger = calendar:value()
            set_input_value(components.trigger, fields.trigger)
        end

        local function open_time()
            calendar_popup:unmount()
            local time = TimeState.new(calendar:value())
            owner.time_state = time
            local time_popup = Popup({
                relative = "editor",
                position = "50%",
                size = { width = 48, height = 7 },
                enter = true,
                border = { style = config.get().ui.float.border, text = { top = " " .. i18n.t("choose_time") .. " " } },
                zindex = 140,
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
                    " " .. i18n.t("time_picker_nav_hint"),
                    " " .. i18n.t("time_picker_digit_hint"),
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
            local function close_time(apply)
                if apply then
                    calendar:move_days(time.day_offset)
                    calendar:set_time(time:value())
                    apply_value()
                end
                owner.transient = nil
                owner.time_state = nil
                owner.calendar_state = nil
                time_popup:unmount()
                focus(2)
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
            for _, item in ipairs({ { "j", 1 }, { "k", -1 }, { "J", 5 }, { "K", -5 } }) do
                map(item[1], function()
                    time:move(item[2])
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
            map("<CR>", function()
                if time:commit_digits() then
                    close_time(true)
                end
            end)
            map("q", function()
                close_time(false)
            end)
            map("<Esc>", function()
                close_time(false)
            end)
            map("<C-q>", function()
                close_time(false)
            end)
        end

        calendar_popup = Popup({
            relative = "editor",
            position = "50%",
            size = { width = 32, height = 10 },
            enter = true,
            border = { style = config.get().ui.float.border, text = { top = " " .. i18n.t("calendar") .. " " } },
            zindex = 130,
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
                    local cell = day and string.format(" %2d ", day) or "    "
                    if day then
                        day_spans[#day_spans + 1] = {
                            line = week + 3,
                            from = #line + 1,
                            to = #line + #cell,
                            day = day,
                        }
                    end
                    line = line .. cell
                end
                lines[#lines + 1] = line
            end
            lines[#lines + 1] = " " .. i18n.t("calendar_nav_hint")
            lines[#lines + 1] = " " .. i18n.t("calendar_footer")
            set_lines(calendar_popup, lines)
            vim.api.nvim_buf_clear_namespace(calendar_popup.bufnr, calendar_popup.ns_id, 0, -1)
            for _, span in ipairs(day_spans) do
                local selected = span.day == calendar.day
                local today = calendar.year == calendar.today.year
                    and calendar.month == calendar.today.month
                    and span.day == calendar.today.day
                if selected or today then
                    vim.api.nvim_buf_set_extmark(
                        calendar_popup.bufnr,
                        calendar_popup.ns_id,
                        span.line - 1,
                        span.from - 1,
                        {
                            end_col = span.to,
                            hl_group = selected and "TodoSelected" or "TodoStatusInProgress",
                        }
                    )
                end
            end
        end
        local function close_calendar(apply)
            if apply then
                apply_value()
            end
            owner.transient = nil
            owner.calendar_state = nil
            calendar_popup:unmount()
            focus(2)
        end
        calendar_popup:mount()
        render_calendar()
        local map = function(key, callback)
            vim.keymap.set("n", key, callback, { buffer = calendar_popup.bufnr, silent = true })
        end
        for _, item in ipairs({ { "h", -1 }, { "l", 1 }, { "j", 7 }, { "k", -7 } }) do
            map(item[1], function()
                calendar:move_days(item[2])
                render_calendar()
            end)
        end
        map("[", function()
            calendar:shift_month(-1)
            render_calendar()
        end)
        map("]", function()
            calendar:shift_month(1)
            render_calendar()
        end)
        map("g", function()
            calendar:set_today()
            render_calendar()
        end)
        map("t", open_time)
        map("<CR>", function()
            close_calendar(true)
        end)
        map("q", function()
            close_calendar(false)
        end)
        map("<Esc>", function()
            close_calendar(false)
        end)
        map("<C-q>", function()
            close_calendar(false)
        end)
        if open_time_immediately then
            open_time()
        end
    end
    owner.open_calendar = open_calendar

    function owner.close(reason)
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
        pcall(function()
            owner.layout:unmount()
        end)
        if current == owner then
            current = nil
        end
        if opts.on_close then
            vim.schedule(function()
                opts.on_close(reason or "closed")
            end)
        end
    end

    local function save()
        fields.description = table.concat(vim.api.nvim_buf_get_lines(components.description.bufnr, 0, -1, false), "\n")
        local recurrence = recurrence_from(fields)
        if not recurrence then
            vim.notify(i18n.t("recurrence_invalid"), vim.log.levels.ERROR)
            focus(5)
            return
        end
        local input_value = {
            kind = "notice",
            title = fields.title,
            status = fields.trigger ~= initial.trigger and "todo" or task.status or "todo",
            trigger = fields.trigger,
            reminder_interval = fields.reminder_interval,
            reminder = fields.trigger == initial.trigger and vim.deepcopy(task.reminder) or nil,
            recurrence = recurrence,
            tags = fields.tags,
            description = fields.description,
        }
        local normalized, errors = model.validate(input_value)
        if not normalized then
            local field = errors.title and 1 or errors.deadline and 2 or errors.reminder_interval and 3 or 4
            vim.notify(vim.inspect(errors), vim.log.levels.ERROR, { title = "todo.nvim" })
            focus(field)
            return
        end
        local ok, result, save_errors = pcall(on_save, input_value)
        if not ok or not result then
            vim.notify(i18n.t("db_error", result or vim.inspect(save_errors)), vim.log.levels.ERROR)
            return
        end
        owner.close("saved")
        vim.notify(i18n.t("saved"), vim.log.levels.INFO)
    end

    local function request_close()
        fields.description = table.concat(vim.api.nvim_buf_get_lines(components.description.bufnr, 0, -1, false), "\n")
        if vim.deep_equal(fields, initial) then
            owner.close("cancelled")
            return
        end
        local menu = Menu({
            relative = "editor",
            position = "50%",
            border = { style = config.get().ui.float.border, text = { top = " " .. i18n.t("unsaved_title") .. " " } },
            zindex = 120,
        }, {
            lines = {
                Menu.item(i18n.t("continue_editing"), { value = false }),
                Menu.item(i18n.t("discard"), { value = true }),
            },
            on_submit = function(item)
                owner.transient = nil
                if item.value then
                    owner.close("discarded")
                else
                    focus(focus_index)
                end
            end,
            on_close = function()
                owner.transient = nil
                focus(focus_index)
            end,
        })
        owner.transient = menu
        menu:mount()
    end

    for index, target in ipairs(focusables) do
        for _, mode in ipairs({ "n", "i" }) do
            vim.keymap.set(mode, "<Tab>", function()
                vim.schedule(function()
                    focus(index + 1)
                end)
            end, { buffer = target.component.bufnr, silent = true })
            vim.keymap.set(mode, "<S-Tab>", function()
                vim.schedule(function()
                    focus(index - 1)
                end)
            end, { buffer = target.component.bufnr, silent = true })
            vim.keymap.set(mode, "<C-s>", function()
                vim.schedule(save)
            end, { buffer = target.component.bufnr, silent = true })
            vim.keymap.set(mode, "<C-q>", function()
                vim.schedule(request_close)
            end, { buffer = target.component.bufnr, silent = true })
        end
        vim.keymap.set("n", "q", request_close, { buffer = target.component.bufnr, silent = true })
        -- Normal-mode Esc only; insert-mode Esc must still leave insert.
        vim.keymap.set("n", "<Esc>", request_close, { buffer = target.component.bufnr, silent = true })
    end

    local function choose_recurrence(index)
        fields.recurrence = recurrence_kinds[index]
        render_recurrence()
    end
    local function open_tag_panel()
        vim.cmd("stopinsert")
        owner.tag_panel_open = true
        require("todo.ui.tag_panel").open({
            title = "tag_selector",
            selected = model.normalize_tags(fields.tags),
            on_change = function(tags)
                fields.tags = table.concat(tags, ", ")
                set_input_value(components.tags, fields.tags)
            end,
            on_close = function()
                owner.tag_panel_open = false
                focus(6)
            end,
        })
    end
    for index = 1, #recurrence_kinds do
        vim.keymap.set("n", tostring(index), function()
            choose_recurrence(index)
        end, { buffer = components.recurrence.bufnr })
    end
    vim.keymap.set("n", "c", open_calendar, { buffer = components.trigger.bufnr, silent = true })
    vim.keymap.set("n", "t", function()
        open_calendar(true)
    end, { buffer = components.trigger.bufnr, silent = true })
    vim.keymap.set("n", "t", open_duration_picker, { buffer = components.interval.bufnr, silent = true })

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
    enter_next(components.trigger, 2)
    enter_next(components.interval, 3)
    enter_next(components.recurrence_spec, 5)
    vim.keymap.set("n", "<CR>", function()
        focus(5)
    end, { buffer = components.recurrence.bufnr, silent = true })
    for _, mode in ipairs({ "n", "i" }) do
        vim.keymap.set(mode, "<CR>", function()
            vim.schedule(open_tag_panel)
        end, { buffer = components.tags.bufnr, silent = true })
    end
    vim.keymap.set("n", "<CR>", function()
        focus(8)
    end, { buffer = components.description.bufnr, silent = true })
    vim.keymap.set("n", "<CR>", function()
        focus(1)
    end, { buffer = components.footer.bufnr, silent = true })
    components.trigger.border:set_text("bottom", " " .. i18n.t("notice_trigger_hint") .. " ", "right")
    components.interval.border:set_text("bottom", " " .. i18n.t("duration_picker_hint") .. " ", "right")
    components.tags.border:set_text("bottom", " " .. i18n.t("choose_existing_tags") .. " ", "right")
    vim.keymap.set("n", "h", function()
        local index = vim.fn.index(recurrence_kinds, fields.recurrence) + 1
        choose_recurrence((index - 2) % #recurrence_kinds + 1)
    end, { buffer = components.recurrence.bufnr })
    vim.keymap.set("n", "l", function()
        local index = vim.fn.index(recurrence_kinds, fields.recurrence) + 1
        choose_recurrence(index % #recurrence_kinds + 1)
    end, { buffer = components.recurrence.bufnr })

    local size =
        { width = math.max(48, math.min(92, vim.o.columns - 4)), height = math.max(24, math.min(31, vim.o.lines - 4)) }
    owner.layout = Layout(
        { relative = "editor", position = "50%", size = size },
        Layout.Box({
            Layout.Box(components.header, { size = 1 }),
            Layout.Box(components.title, { size = 3 }),
            Layout.Box({
                Layout.Box(components.trigger, { size = "55%" }),
                Layout.Box(components.interval, { size = "45%" }),
            }, { dir = "row", size = 3 }),
            Layout.Box(components.recurrence, { size = 3 }),
            Layout.Box(components.recurrence_spec, { size = 3 }),
            Layout.Box(components.tags, { size = 3 }),
            Layout.Box(components.description, { grow = 1 }),
            Layout.Box(components.footer, { size = 1 }),
        }, { dir = "col" })
    )
    owner.layout:mount()
    set_lines(components.header, { "  " .. i18n.t(task.id and "notice" or "notice_new") })
    set_lines(components.description, vim.split(fields.description, "\n", { plain = true }), true)
    set_lines(components.footer, { " " .. i18n.t("notice_form_footer") })
    render_recurrence()
    vim.schedule(function()
        focus(1)
    end)
    owner.save = save
end

function M.close(force)
    if current then
        current.close(force and "forced" or "closed")
    end
end

function M.inspect_state()
    return current
end

return M
