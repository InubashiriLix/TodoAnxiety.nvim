local config = require("todo.config")
local grouping = require("todo.ui.grouping")
local highlights = require("todo.ui.highlights")
local i18n = require("todo.i18n")
local form = require("todo.ui.form")
local markdown = require("todo.ui.markdown")
local urgency = require("todo.urgency")
local viewmodel = require("todo.ui.viewmodel")

local Input = require("nui.input")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
local Popup = require("nui.popup")
local Split = require("nui.split")

local M = {}
local ns = vim.api.nvim_create_namespace("todo_dashboard")
-- The fixed detail pane and the detail overlay are mutually exclusive (the
-- overlay only opens when there is no fixed pane), so both can share one
-- buffer kept alive across mount/unmount. Recreating it on every open/close
-- gave third-party filetype=markdown watchers (e.g. mdmath.nvim, which
-- enables itself 100ms after FileType via vim.defer_fn) a window to fire
-- against a buffer nui had already deleted.
local detail_bufnr = nil

local function persistent_detail_bufnr()
    if not detail_bufnr or not vim.api.nvim_buf_is_valid(detail_bufnr) then
        detail_bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[detail_bufnr].buftype = "nofile"
        vim.bo[detail_bufnr].bufhidden = "hide"
        vim.bo[detail_bufnr].swapfile = false
        vim.bo[detail_bufnr].modifiable = false
    end
    return detail_bufnr
end
local state = {
    owner = nil,
    mode = nil,
    view = "active",
    tasks = {},
    stats = { active = 0, emergency = 0, notices = 0, archived = 0 },
    filters = {},
    selected_id = nil,
    rows = {},
    cursor_row = 1,
    collapsed = {},
    task_order = {},
    task_lines = {},
    tab_spans = {},
    tab_line = 1,
}

local function collapsed_map()
    state.collapsed[state.view] = state.collapsed[state.view] or {}
    return state.collapsed[state.view]
end

local function current_row()
    return state.rows[state.cursor_row]
end

local function service()
    return require("todo")._service()
end

local function owner_valid()
    local owner = state.owner
    if not owner or owner.closed then
        return false
    end
    if owner.split then
        return owner.split.winid and vim.api.nvim_win_is_valid(owner.split.winid)
    end
    return owner.layout ~= nil and owner.list.winid and vim.api.nvim_win_is_valid(owner.list.winid)
end

local function owner_has_window(owner, winid)
    if not owner or not winid or not vim.api.nvim_win_is_valid(winid) then
        return false
    end
    for _, name in ipairs({ "split", "header", "list", "footer", "detail", "detail_overlay", "transient" }) do
        local component = owner[name]
        if component and component.winid == winid then
            return true
        end
    end
    return false
end

local function tag_panel_has_window(winid)
    local tag_panel = package.loaded["todo.ui.tag_panel"]
    if type(tag_panel) ~= "table" or type(tag_panel.inspect_state) ~= "function" then
        return false
    end
    local tag_owner = tag_panel.inspect_state()
    if not tag_owner or tag_owner.closed then
        return false
    end
    for _, name in ipairs({ "popup", "transient" }) do
        local component = tag_owner[name]
        if component and component.winid == winid then
            return true
        end
    end
    return false
end

local function reminder_popup_has_window(winid)
    local popup = package.loaded["todo.ui.reminder_popup"]
    if type(popup) ~= "table" or type(popup.inspect_state) ~= "function" then
        return false
    end
    local reminder_owner = popup.inspect_state()
    return reminder_owner
        and not reminder_owner.closed
        and reminder_owner.component
        and reminder_owner.component.winid == winid
end

local function todo_has_window(owner, winid)
    return owner_has_window(owner, winid) or tag_panel_has_window(winid) or reminder_popup_has_window(winid)
end

local function selected_task()
    for _, task in ipairs(state.tasks) do
        if task.id == state.selected_id then
            return task
        end
    end
    return nil
end

local function set_buffer(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function add_hl(buf, line, from, to, group)
    local content = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
    from = math.max(0, math.min(from, #content))
    if to < 0 then
        to = #content
    end
    to = math.max(from, math.min(to, #content))
    if to == from then
        return
    end
    vim.api.nvim_buf_set_extmark(buf, ns, line, from, {
        end_col = to,
        hl_group = group,
        priority = 120,
    })
end

local function filter_summary()
    local bits = {}
    for _, key in ipairs({ "search", "status", "priority", "tag" }) do
        local value = state.filters[key]
        if value and value ~= "" and value ~= "all" then
            bits[#bits + 1] = key .. ":" .. value
        end
    end
    return bits
end

--- Lay the seven view tabs out over as many lines as the width needs.
--- Returns the tab lines plus spans carrying the line each tab landed on.
local function tab_layout(compact, width, first_line, first_prefix)
    local continuation = string.rep(" ", vim.fn.strdisplaywidth(first_prefix))
    local lines, spans = {}, {}
    local current, line_index, prefix = first_prefix, first_line, first_prefix
    for _, view in ipairs(grouping.views) do
        local label = i18n.t(compact and (view .. "_short") or view)
        local text = grouping.counted[view] and string.format("[ %s %d ]", label, state.stats[view] or 0)
            or string.format("[ %s ]", label)
        if current ~= prefix and vim.fn.strdisplaywidth(current .. text) > width then
            lines[#lines + 1] = current
            line_index = line_index + 1
            prefix = continuation
            current = prefix
        end
        local from = #current
        current = current .. text .. " "
        spans[#spans + 1] = { from = from, to = from + #text, view = view, line = line_index }
    end
    lines[#lines + 1] = current
    return lines, spans
end

local function header_content(compact, width)
    width = width or 200
    local filters = filter_summary()
    if compact then
        local title = "  TODO.NVIM · " .. i18n.t(state.view)
        local tab_lines, spans = tab_layout(true, width, 2, " ")
        local result = { viewmodel.truncate(title, width) }
        for _, line in ipairs(tab_lines) do
            result[#result + 1] = viewmodel.truncate(line, width)
        end
        if #filters > 0 then
            result[#result + 1] = viewmodel.truncate("  " .. table.concat(filters, "   "), width)
        end
        return result, spans, 2
    end
    local tab_lines, spans = tab_layout(false, width, 1, "  TODO.NVIM  ")
    local result = vim.deepcopy(tab_lines)
    result[#result + 1] = #filters > 0 and ("  " .. table.concat(filters, "   "))
        or ("  / " .. i18n.t("search_placeholder"))
    return result, spans, 1
end

local urgency_groups = {
    overdue = "TodoUrgencyOverdue",
    urgent = "TodoUrgencyUrgent",
    high = "TodoUrgencyHigh",
    attention = "TodoUrgencyAttention",
    priority_only = "TodoUrgencyPriorityOnly",
}

local function urgency_label(task)
    if not urgency.is_candidate(task) then
        return nil
    end
    local info = task.urgency or urgency.calculate(task)
    task.urgency = info
    return i18n.t(info.level), urgency_groups[info.level]
end

local function list_content(width)
    local lines, mappings, order, decorations = {}, {}, {}, {}
    local relative = state.view == "by_time"
    local rows = state.rows
    for index, row in ipairs(rows) do
        if row.kind == "section" then
            local marker = row.collapsed and "▸" or "▾"
            local indent = string.rep("  ", row.depth)
            lines[#lines + 1] = string.format(" %s%s %s  %d", indent, marker, row.label, row.count)
            decorations[#decorations + 1] =
                { line = #lines - 1, from = 0, to = -1, group = "TodoSectionHeader", whole = true }
            local group = row.tag and highlights.tag(row.tag) or "TodoHeader"
            decorations[#decorations + 1] = { line = #lines - 1, from = 1, to = #lines[#lines], group = group }
            mappings[#lines] = row
            if index == state.cursor_row then
                decorations[#decorations + 1] =
                    { line = #lines - 1, from = 0, to = -1, group = "TodoSelected", whole = true }
            end
        else
            local task = row.task
            local indent = string.rep("  ", row.depth)
            local reason, reason_group = urgency_label(task)
            local line1, line2 =
                viewmodel.card(task, math.max(10, width - 3 - #indent), reason, { relative = relative })
            local first = #lines + 1
            lines[#lines + 1] = " " .. indent .. line1
            lines[#lines + 1] = " " .. indent .. line2
            lines[#lines + 1] = ""
            mappings[first] = row
            mappings[first + 1] = row
            order[#order + 1] = task
            local badge = string.format("[P%d]", task.priority)
            local badge_start = lines[first]:find(badge, 1, true)
            if badge_start then
                decorations[#decorations + 1] = {
                    line = first - 1,
                    from = badge_start - 1,
                    to = badge_start - 1 + #badge,
                    group = "TodoPriority" .. task.priority,
                }
            end
            if reason_group and reason then
                local reason_start = lines[first + 1]:find(reason, 1, true)
                if reason_start then
                    decorations[#decorations + 1] = {
                        line = first,
                        from = reason_start - 1,
                        to = reason_start - 1 + #reason,
                        group = reason_group,
                    }
                end
            end
            for _, tag in ipairs(task.tags or {}) do
                local marker = "#" .. tag
                local tag_start = lines[first + 1]:find(marker, 1, true)
                if tag_start then
                    decorations[#decorations + 1] = {
                        line = first,
                        from = tag_start - 1,
                        to = tag_start - 1 + #marker,
                        group = highlights.tag(tag),
                    }
                end
            end
            if index == state.cursor_row then
                decorations[#decorations + 1] =
                    { line = first - 1, from = 0, to = -1, group = "TodoSelected", whole = true }
                decorations[#decorations + 1] =
                    { line = first, from = 0, to = -1, group = "TodoSelected", whole = true }
            end
        end
    end
    if #order == 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  " .. i18n.t("no_tasks")
        decorations[#decorations + 1] = { line = #lines - 1, from = 2, to = #lines[#lines], group = "TodoMuted" }
    end
    return lines, mappings, order, decorations
end

--- Detail panes render markdown, so treesitter owns the highlighting and we
--- hand back an empty decoration list.
local function detail_content(task)
    return markdown.task_lines(task), {}
end

local function apply_decorations(buf, decorations, offset)
    offset = offset or 0
    for _, item in ipairs(decorations) do
        if item.whole then
            vim.api.nvim_buf_set_extmark(buf, ns, item.line + offset, 0, {
                end_row = item.line + offset + 1,
                hl_group = item.group,
                hl_eol = true,
                priority = 80,
            })
        else
            add_hl(buf, item.line + offset, item.from, item.to, item.group)
        end
    end
end

local function footer_text(compact)
    local line = " "
    local items = compact
            and {
                { key = "a", label = "+" },
                { key = "n", label = "󰀠" },
                { key = "e", label = "✎" },
                { key = "x", label = "✓" },
                { key = "/", label = "" },
                { key = "f", label = "" },
                { key = "?", label = "" },
            }
        or {
            { key = "a", label = i18n.t("action_add") },
            { key = "n", label = i18n.t("notice") },
            { key = "e", label = i18n.t("action_edit") },
            { key = "x", label = i18n.t("action_complete") },
            { key = "/", label = i18n.t("search") },
            { key = "f", label = i18n.t("filter") },
            { key = "?", label = i18n.t("help") },
        }
    if state.view == "archived" then
        table.insert(items, 4, { key = "D", label = compact and "" or i18n.t("action_delete") })
    end
    for _, item in ipairs(items) do
        local text = item.label == "" and string.format("[%s] ", item.key)
            or string.format("[%s %s] ", item.key, item.label)
        line = line .. text
    end
    return line
end

local function focus_selected(owner)
    local win = owner.split and owner.split.winid or owner.list.winid
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local target = current_row()
    local selected_line
    for line, row in pairs(state.task_lines) do
        if row == target then
            selected_line = not selected_line and line or math.min(selected_line, line)
        end
    end
    if selected_line then
        pcall(vim.api.nvim_win_set_cursor, win, { selected_line, 0 })
        pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zz")
        end)
    end
end

local render

local function render_float(owner)
    local header, spans, tab_line = header_content(false, vim.api.nvim_win_get_width(owner.header.winid))
    -- Counts can gain a digit while open and push tabs onto an extra line; the
    -- header box was sized at mount, so drop anything that no longer fits.
    local room = vim.api.nvim_win_get_height(owner.header.winid)
    while #header > room do
        table.remove(header)
    end
    state.tab_spans, state.tab_line = spans, tab_line
    set_buffer(owner.header.bufnr, header)
    add_hl(owner.header.bufnr, 0, 2, 11, "TodoHeader")
    for _, span in ipairs(spans) do
        add_hl(
            owner.header.bufnr,
            span.line - 1,
            span.from,
            span.to,
            span.view == state.view and "TodoTabActive" or "TodoTabInactive"
        )
    end
    add_hl(owner.header.bufnr, #header - 1, 0, #header[#header], "TodoMuted")

    local width = vim.api.nvim_win_get_width(owner.list.winid)
    local lines, mappings, order, decorations = list_content(width)
    state.task_lines, state.task_order = mappings, order
    set_buffer(owner.list.bufnr, lines)
    owner.list.border:set_text("top", " " .. i18n.t(state.view) .. " ", "left")
    apply_decorations(owner.list.bufnr, decorations)

    if owner.detail then
        local details, detail_decorations = detail_content(selected_task())
        set_buffer(owner.detail.bufnr, details)
        apply_decorations(owner.detail.bufnr, detail_decorations)
    end
    set_buffer(owner.footer.bufnr, { footer_text() })
    add_hl(owner.footer.bufnr, 0, 0, -1, "TodoMuted")
    focus_selected(owner)
end

local function render_sidebar(owner)
    local width = vim.api.nvim_win_get_width(owner.split.winid)
    local header, spans, tab_line = header_content(true, width)
    state.tab_spans, state.tab_line = spans, tab_line
    local filtered = #filter_summary() > 0
    local list_lines, mappings, order, decorations = list_content(width)
    local lines = vim.list_extend(vim.deepcopy(header), { "" })
    local list_offset = #lines
    vim.list_extend(lines, list_lines)
    lines[#lines + 1] = footer_text(true)
    state.task_lines, state.task_order = {}, order
    for line, row in pairs(mappings) do
        state.task_lines[line + list_offset] = row
    end
    set_buffer(owner.split.bufnr, lines)
    add_hl(owner.split.bufnr, 0, 2, 11, "TodoHeader")
    for _, span in ipairs(spans) do
        add_hl(
            owner.split.bufnr,
            span.line - 1,
            span.from,
            span.to,
            span.view == state.view and "TodoTabActive" or "TodoTabInactive"
        )
    end
    if filtered then
        add_hl(owner.split.bufnr, #header - 1, 0, -1, "TodoMuted")
    end
    apply_decorations(owner.split.bufnr, decorations, list_offset)
    add_hl(owner.split.bufnr, #lines - 1, 0, -1, "TodoMuted")
    focus_selected(owner)
end

render = function()
    if not owner_valid() then
        return
    end
    local ok, tasks, stats = pcall(function()
        return service():list(state.view, state.filters), service():stats()
    end)
    if not ok then
        vim.notify(i18n.t("db_error", tasks), vim.log.levels.ERROR)
        return
    end
    state.tasks, state.stats = tasks, stats
    state.rows = grouping.rows(grouping.sections(tasks, state.view), collapsed_map())
    -- Keep the cursor on the previously selected task when it is still visible.
    local target
    for index, row in ipairs(state.rows) do
        if row.kind == "task" and row.task.id == state.selected_id then
            target = target or index
        end
    end
    if not target then
        for index, row in ipairs(state.rows) do
            if row.kind == "task" then
                target = index
                break
            end
        end
    end
    state.cursor_row = target or 1
    local row = current_row()
    if row and row.kind == "task" then
        state.selected_id = row.task.id
    elseif not selected_task() then
        state.selected_id = nil
    end
    if state.owner.split then
        render_sidebar(state.owner)
    else
        render_float(state.owner)
    end
end

local function repaint()
    if state.owner.split then
        render_sidebar(state.owner)
    else
        render_float(state.owner)
    end
end

local function select_delta(delta)
    if #state.rows == 0 then
        return
    end
    state.cursor_row = math.max(1, math.min(#state.rows, state.cursor_row + delta))
    local row = current_row()
    if row and row.kind == "task" then
        state.selected_id = row.task.id
    end
    repaint()
end

local function change_view(view)
    state.view, state.selected_id = view, nil
    state.cursor_row = 1
    render()
end

local function cycle_view(delta)
    local views = grouping.views
    local index = 1
    for i, view in ipairs(views) do
        if view == state.view then
            index = i
            break
        end
    end
    change_view(views[(index - 1 + delta) % #views + 1])
end

--- Section key whose fold the cursor should toggle: the header itself, or the
--- section the highlighted task belongs to.
local function cursor_section_key()
    local row = current_row()
    if not row then
        return nil
    end
    return row.kind == "section" and row.key or row.section_key
end

local function toggle_fold()
    local key = cursor_section_key()
    if not key then
        return
    end
    local collapsed = collapsed_map()
    collapsed[key] = not collapsed[key] or nil
    -- Land on the section header so repeated presses stay predictable.
    state.rows = grouping.rows(grouping.sections(state.tasks, state.view), collapsed)
    for index, row in ipairs(state.rows) do
        if row.kind == "section" and row.key == key then
            state.cursor_row = index
            break
        end
    end
    repaint()
end

local function set_all_folds(value)
    local collapsed = collapsed_map()
    local sections = grouping.sections(state.tasks, state.view)
    for _, section in ipairs(sections) do
        collapsed[section.key] = value or nil
    end
    state.rows = grouping.rows(sections, collapsed)
    state.cursor_row = math.max(1, math.min(#state.rows, state.cursor_row))
    repaint()
end

local function open_task_form(task, save_task)
    local reopen = {
        mode = state.mode,
        view = state.view,
        filters = vim.deepcopy(state.filters),
        selected_id = state.selected_id,
    }
    M.close()
    form.open(task, function(input)
        local result, errors = save_task(input)
        if result then
            reopen.selected_id = result.id
        end
        return result, errors
    end, {
        on_close = function(reason)
            if reason ~= "replaced" and not owner_valid() then
                M.open(reopen)
            end
        end,
    })
end

local function add_task(opts)
    opts = opts or {}
    local last_interval = service():last_reminder_interval()
    open_task_form({
        title = opts.title or "",
        reminder = last_interval and { repeat_interval_seconds = last_interval } or nil,
    }, function(input)
        local result, errors = service():create(input)
        if result then
            require("todo")._reschedule_reminders()
        end
        return result, errors
    end)
end

local function add_notice(opts)
    opts = opts or {}
    local reopen = {
        mode = state.mode,
        view = "notices",
        filters = vim.deepcopy(state.filters),
        selected_id = state.selected_id,
    }
    local default_interval = service():last_reminder_interval()
    M.close()
    require("todo.ui.notice_form").open({ title = opts.title or "" }, function(input)
        local result, errors = service():create(input)
        if result then
            reopen.selected_id = result.id
            require("todo")._reschedule_reminders()
        end
        return result, errors
    end, {
        default_interval = default_interval and require("todo.duration").format(default_interval) or "",
        on_close = function(reason)
            if reason ~= "replaced" and not owner_valid() then
                M.open(reopen)
            end
        end,
    })
end

local function require_task()
    local task = selected_task()
    if not task then
        vim.notify(i18n.t("missing_task"), vim.log.levels.WARN)
    end
    return task
end

local function edit_task()
    local task = require_task()
    if not task then
        return
    end
    if task.kind == "notice" then
        local reopen =
            { mode = state.mode, view = state.view, filters = vim.deepcopy(state.filters), selected_id = task.id }
        M.close()
        require("todo.ui.notice_form").open(task, function(input)
            local result, errors = service():update(task.id, input, task.sync_revision)
            if result then
                require("todo")._reschedule_reminders()
            end
            return result, errors
        end, {
            on_close = function()
                if not owner_valid() then
                    M.open(reopen)
                end
            end,
        })
    else
        open_task_form(task, function(input)
            local result, errors = service():update(task.id, input, task.sync_revision)
            if result then
                require("todo")._reschedule_reminders()
            end
            return result, errors
        end)
    end
end

local function change_status(status)
    local task = require_task()
    if not task then
        return
    end
    local ok, result = pcall(function()
        if status == "done" and task.kind == "notice" then
            return service():complete_reminder(task.id)
        end
        return service():set_status(task.id, status)
    end)
    if not ok or not result then
        vim.notify(i18n.t("db_error", result), vim.log.levels.ERROR)
    else
        require("todo")._reschedule_reminders()
        render()
    end
end

local function archive_task(restore)
    local task = require_task()
    if not task then
        return
    end
    local ok, result = pcall(function()
        return restore and service():restore(task.id) or service():archive(task.id)
    end)
    if not ok or not result then
        vim.notify(i18n.t("db_error", result), vim.log.levels.ERROR)
        return
    end
    state.selected_id = nil
    require("todo")._reschedule_reminders()
    vim.notify(i18n.t(restore and "restored" or "archived_ok"), vim.log.levels.INFO)
    render()
end

local function close_transient(owner)
    if owner.transient then
        pcall(function()
            owner.transient:unmount()
        end)
        owner.transient = nil
    end
end

local function menu(owner, title, items, on_submit)
    close_transient(owner)
    local lines = {}
    for _, item in ipairs(items) do
        lines[#lines + 1] = Menu.item(item.label, { value = item.value })
    end
    local component = Menu({
        relative = "editor",
        position = "50%",
        border = { style = config.get().ui.float.border, text = { top = " " .. title .. " ", top_align = "center" } },
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder,CursorLine:TodoSelected" },
        zindex = 80,
    }, {
        lines = lines,
        min_width = 26,
        max_height = 14,
        on_close = function()
            owner.transient = nil
        end,
        on_submit = function(item)
            owner.transient = nil
            on_submit(item.value)
        end,
    })
    owner.transient = component
    component:mount()
    local dismiss = function()
        close_transient(owner)
        focus_list(owner)
    end
    vim.keymap.set("n", "<Esc>", dismiss, { buffer = component.bufnr, silent = true })
    vim.keymap.set("n", "q", dismiss, { buffer = component.bufnr, silent = true })
end

local function delete_archived_task()
    local task = require_task()
    if not task then
        return
    end
    if not task.archived_at then
        vim.notify(i18n.t("delete_archived_only"), vim.log.levels.WARN)
        return
    end
    menu(state.owner, i18n.t("delete_task_title"), {
        { label = i18n.t("cancel"), value = false },
        { label = i18n.t("delete_task_confirm", task.id, task.title), value = true },
    }, function(confirmed)
        if not confirmed then
            return
        end
        local ok, deleted = pcall(function()
            return service():delete_archived(task.id)
        end)
        if not ok or not deleted then
            vim.notify(i18n.t("delete_failed"), vim.log.levels.ERROR)
            return
        end
        state.selected_id = nil
        vim.notify(i18n.t("deleted"), vim.log.levels.INFO)
        render()
    end)
end

local function open_filter()
    local owner = state.owner
    menu(owner, i18n.t("filter"), {
        { label = i18n.t("status"), value = "status" },
        { label = i18n.t("priority"), value = "priority" },
        { label = i18n.t("tags"), value = "tag" },
        { label = i18n.t("clear"), value = "clear" },
    }, function(kind)
        if kind == "clear" then
            state.filters = {}
            render()
            return
        end
        local values = {}
        if kind == "status" then
            values[#values + 1] = { label = i18n.t("all"), value = "all" }
            for _, value in ipairs({ "todo", "in_progress", "done", "cancelled" }) do
                values[#values + 1] = { label = i18n.t(value), value = value }
            end
        elseif kind == "priority" then
            values[#values + 1] = { label = i18n.t("all"), value = "all" }
            for value = 0, 3 do
                values[#values + 1] = { label = "P" .. value, value = "P" .. value }
            end
        else
            values[#values + 1] = { label = i18n.t("all"), value = "" }
            for _, tag in ipairs(service():list_tags()) do
                values[#values + 1] = { label = "#" .. tag, value = tag }
            end
        end
        menu(owner, i18n.t(kind == "tag" and "tags" or kind), values, function(value)
            state.filters[kind] = value
            render()
        end)
    end)
end

--- Put the cursor back on the list/sidebar window after a transient closes.
local function focus_list(owner)
    local win = owner.split and owner.split.winid or (owner.list and owner.list.winid)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_current_win, win)
    end
end

local function open_search()
    local owner = state.owner
    close_transient(owner)
    local search = Input({
        relative = "editor",
        position = { row = 2, col = "50%" },
        size = { width = math.max(10, math.min(60, vim.o.columns - 8)) },
        border = { style = config.get().ui.float.border, text = { top = " " .. i18n.t("search") .. " " } },
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
        zindex = 80,
    }, {
        default_value = state.filters.search or "",
        on_change = function(value)
            state.filters.search = value
            vim.schedule(render)
        end,
        on_submit = function(value)
            owner.transient = nil
            state.filters.search = value
            render()
        end,
        on_close = function()
            owner.transient = nil
            render()
        end,
    })
    owner.transient = search
    search:mount()
    -- Esc from either mode abandons the search: clear the query, drop the input,
    -- hand the cursor back to the list.
    local abandon = function()
        state.filters.search = nil
        close_transient(owner)
        render()
        focus_list(owner)
    end
    vim.keymap.set("n", "<Esc>", abandon, { buffer = search.bufnr, silent = true })
    vim.keymap.set("i", "<Esc>", function()
        vim.schedule(abandon)
    end, { buffer = search.bufnr, silent = true })
    vim.keymap.set({ "n", "i" }, "<C-q>", function()
        vim.schedule(abandon)
    end, { buffer = search.bufnr, silent = true })
    vim.keymap.set("n", "q", abandon, { buffer = search.bufnr, silent = true })
    vim.api.nvim_create_autocmd("WinLeave", {
        buffer = search.bufnr,
        once = true,
        callback = function()
            vim.schedule(function()
                if owner.closed or state.owner ~= owner or owner.transient ~= search then
                    return
                end
                local target_win = vim.api.nvim_get_current_win()
                close_transient(owner)
                if owner.mode == "float" and not owner_has_window(owner, target_win) then
                    M.close()
                else
                    render()
                end
            end)
        end,
    })
end

local function show_help()
    local owner = state.owner
    close_transient(owner)
    local help = Popup({
        relative = "editor",
        position = "50%",
        size = { width = math.max(10, math.min(90, vim.o.columns - 8)), height = 5 },
        enter = true,
        border = {
            style = config.get().ui.float.border,
            text = { top = " " .. i18n.t("help") .. " ", top_align = "center" },
        },
        win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
        zindex = 80,
    })
    owner.transient = help
    help:mount()
    vim.api.nvim_buf_set_lines(
        help.bufnr,
        0,
        -1,
        false,
        { "", "  " .. i18n.t("panel_help"), "", "  h/l focus list or details   [/] change view" }
    )
    local close = function()
        help:unmount()
        owner.transient = nil
        focus_list(owner)
    end
    vim.keymap.set("n", "q", close, { buffer = help.bufnr })
    vim.keymap.set("n", "<Esc>", close, { buffer = help.bufnr })
end

local function render_overlay(overlay)
    local lines, decorations = detail_content(selected_task())
    set_buffer(overlay.bufnr, lines)
    apply_decorations(overlay.bufnr, decorations)
end

local function open_details()
    local task = require_task()
    if not task then
        return
    end
    local owner = state.owner
    if owner.detail then
        vim.api.nvim_set_current_win(owner.detail.winid)
        return
    end
    if owner.detail_overlay then
        owner.detail_overlay:unmount()
    end
    local width = math.max(10, math.min(72, vim.o.columns - 6))
    local height = math.max(4, math.min(24, vim.o.lines - 6))
    local position = "50%"
    if owner.split and owner.split.winid and vim.api.nvim_win_is_valid(owner.split.winid) then
        local pos = vim.api.nvim_win_get_position(owner.split.winid)
        local split_width = vim.api.nvim_win_get_width(owner.split.winid)
        if pos[2] > width + 2 then
            position = { row = pos[1], col = pos[2] - width - 2 }
        elseif pos[2] + split_width + width + 2 < vim.o.columns then
            position = { row = pos[1], col = pos[2] + split_width + 1 }
        end
    end
    local overlay = Popup({
        bufnr = persistent_detail_bufnr(),
        relative = "editor",
        position = position,
        size = { width = width, height = height },
        enter = true,
        border = {
            style = config.get().ui.float.border,
            text = { top = " " .. i18n.t("details") .. " ", top_align = "center" },
        },
        win_options = vim.tbl_extend("force", {
            wrap = true,
            winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder",
        }, markdown.win_options(false)),
        zindex = 70,
    })
    owner.detail_overlay = overlay
    overlay:mount()
    markdown.attach(overlay.bufnr)
    render_overlay(overlay)
    local close = function()
        overlay:unmount()
        owner.detail_overlay = nil
        focus_list(owner)
    end
    vim.keymap.set("n", "q", close, { buffer = overlay.bufnr })
    vim.keymap.set("n", "<Esc>", close, { buffer = overlay.bufnr })
    vim.keymap.set("n", "e", edit_task, { buffer = overlay.bufnr })
    vim.keymap.set("n", "s", function()
        change_status("in_progress")
        render_overlay(overlay)
    end, { buffer = overlay.bufnr })
    vim.keymap.set("n", "x", function()
        change_status("done")
        render_overlay(overlay)
    end, { buffer = overlay.bufnr })
end

local function set_mappings(component, role)
    local buf = component.bufnr
    local opts = function(desc)
        return { buffer = buf, silent = true, desc = desc }
    end
    vim.keymap.set("n", "q", M.close, opts("Close todo dashboard"))
    -- Esc peels one layer: active filters first, then the panel itself.
    vim.keymap.set("n", "<Esc>", function()
        if #filter_summary() > 0 then
            state.filters = {}
            render()
        else
            M.close()
        end
    end, opts("Clear filters or close dashboard"))
    vim.keymap.set("n", "<Tab>", toggle_fold, opts("Toggle section"))
    vim.keymap.set("n", "za", toggle_fold, opts("Toggle section"))
    vim.keymap.set("n", "zM", function()
        set_all_folds(true)
    end, opts("Collapse all sections"))
    vim.keymap.set("n", "zR", function()
        set_all_folds(false)
    end, opts("Expand all sections"))
    vim.keymap.set("n", "j", function()
        select_delta(1)
    end, opts("Next task"))
    vim.keymap.set("n", "k", function()
        select_delta(-1)
    end, opts("Previous task"))
    vim.keymap.set("n", "a", add_task, opts("Add task"))
    vim.keymap.set("n", "n", add_notice, opts("Add notice"))
    vim.keymap.set("n", "e", edit_task, opts("Edit task"))
    vim.keymap.set("n", "s", function()
        change_status("in_progress")
    end, opts("Start task"))
    vim.keymap.set("n", "x", function()
        change_status("done")
    end, opts("Complete task"))
    vim.keymap.set("n", "c", function()
        change_status("cancelled")
    end, opts("Cancel task"))
    vim.keymap.set("n", "u", function()
        change_status("todo")
    end, opts("Reopen task"))
    vim.keymap.set("n", "A", function()
        archive_task(false)
    end, opts("Archive task"))
    vim.keymap.set("n", "R", function()
        archive_task(true)
    end, opts("Restore task"))
    vim.keymap.set("n", "D", delete_archived_task, opts("Permanently delete archived task"))
    vim.keymap.set("n", "r", render, opts("Refresh dashboard"))
    vim.keymap.set("n", "/", open_search, opts("Search tasks"))
    vim.keymap.set("n", "f", open_filter, opts("Filter tasks"))
    vim.keymap.set("n", "?", show_help, opts("Dashboard help"))
    vim.keymap.set("n", "g", function()
        require("todo").tags()
    end, opts("Manage tags"))
    vim.keymap.set("n", "[", function()
        cycle_view(-1)
    end, opts("Previous view"))
    vim.keymap.set("n", "]", function()
        cycle_view(1)
    end, opts("Next view"))
    vim.keymap.set("n", "v", function()
        local items = {}
        for _, view in ipairs(grouping.views) do
            items[#items + 1] = { label = i18n.t(view), value = view }
        end
        menu(state.owner, i18n.t("view"), items, change_view)
    end, opts("Choose view"))
    vim.keymap.set("n", "<CR>", open_details, opts("Open details"))
    if role == "list" and state.owner and state.owner.detail then
        vim.keymap.set("n", "l", function()
            vim.api.nvim_set_current_win(state.owner.detail.winid)
        end, opts("Focus details"))
    elseif role == "detail" then
        vim.keymap.set("n", "h", function()
            vim.api.nvim_set_current_win(state.owner.list.winid)
        end, opts("Focus list"))
    end
end

local function base_popup(label, opts)
    opts = opts or {}
    local win_options = {
        wrap = opts.wrap or false,
        cursorline = false,
        number = false,
        relativenumber = false,
        winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder",
    }
    if opts.markdown then
        win_options = vim.tbl_extend("force", win_options, markdown.win_options(false))
    end
    local component = Popup({
        bufnr = opts.bufnr,
        enter = opts.enter or false,
        focusable = opts.focusable ~= false,
        border = opts.border == false and "none" or {
            style = config.get().ui.float.border,
            text = { top = label and (" " .. label .. " ") or "", top_align = "left" },
        },
        buf_options = opts.bufnr and nil
            or { buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = false },
        win_options = win_options,
    })
    if opts.markdown then
        markdown.attach(component.bufnr)
    end
    return component
end

local function create_float(owner)
    local cfg = config.get().ui.float
    local width = math.max(10, math.min(vim.o.columns - 4, math.floor(vim.o.columns * cfg.width)))
    local height = math.max(6, math.min(vim.o.lines - 4, math.floor((vim.o.lines - 2) * cfg.height)))
    owner.wide = width >= 100
    -- Tabs wrap when they cannot fit, so the header box grows with them.
    local header_lines = select(1, header_content(false, width))
    owner.header = base_popup(nil, { border = false })
    owner.list = base_popup(i18n.t(state.view), { enter = true })
    owner.footer = base_popup(nil, { border = false })
    local body
    if owner.wide then
        owner.detail = base_popup(
            i18n.t("details"),
            { enter = false, wrap = true, markdown = true, bufnr = persistent_detail_bufnr() }
        )
        body = Layout.Box({
            Layout.Box(owner.list, { size = "58%" }),
            Layout.Box(owner.detail, { size = "42%" }),
        }, { dir = "row", grow = 1 })
    else
        body = Layout.Box(owner.list, { grow = 1 })
    end
    owner.layout = Layout(
        { relative = "editor", position = "50%", size = { width = width, height = height } },
        Layout.Box({
            Layout.Box(owner.header, { size = math.max(2, #header_lines) }),
            body,
            Layout.Box(owner.footer, { size = 1 }),
        }, { dir = "col" })
    )
    owner.layout:mount()
    set_mappings(owner.header, "header")
    set_mappings(owner.list, "list")
    set_mappings(owner.footer, "footer")
    if owner.detail then
        set_mappings(owner.detail, "detail")
    end
    vim.api.nvim_set_current_win(owner.list.winid)
end

local function create_sidebar(owner)
    local cfg = config.get().ui.sidebar
    owner.split = Split({
        relative = "editor",
        position = cfg.side,
        size = math.max(20, math.min(cfg.width, vim.o.columns - 2)),
        enter = true,
        buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false, modifiable = false },
        win_options = { wrap = false, number = false, relativenumber = false, winhighlight = "Normal:NormalFloat" },
    })
    owner.split:mount()
    set_mappings(owner.split, "sidebar")
end

function M.open(opts)
    opts = opts or {}
    if owner_valid() then
        M.close()
    end
    highlights.setup()
    state.mode = opts.mode or config.get().ui.default_mode
    state.view = opts.view or config.get().ui.default_view
    state.filters = opts.filters or state.filters or {}
    state.selected_id = opts.selected_id or state.selected_id
    -- Header height depends on the tab counts, so read stats before laying out.
    local ok, stats = pcall(function()
        return service():stats()
    end)
    state.stats = ok and stats or state.stats
    local owner = { closed = false, transient = nil, mode = state.mode }
    state.owner = owner
    if state.mode == "sidebar" then
        create_sidebar(owner)
    else
        create_float(owner)
    end
    render()
    owner.resize_group = vim.api.nvim_create_augroup("TodoDashboardResize", { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
        group = owner.resize_group,
        callback = function()
            if owner_valid() then
                local reopen = {
                    mode = state.mode,
                    view = state.view,
                    filters = vim.deepcopy(state.filters),
                    selected_id = state.selected_id,
                }
                vim.schedule(function()
                    M.open(reopen)
                end)
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = owner.resize_group,
        callback = function()
            if owner.mode ~= "float" then
                return
            end
            vim.schedule(function()
                if owner.closed or state.owner ~= owner then
                    return
                end
                if not todo_has_window(owner, vim.api.nvim_get_current_win()) then
                    M.close()
                end
            end)
        end,
    })
end

function M.close()
    local owner = state.owner
    if not owner then
        return
    end
    owner.closed = true
    close_transient(owner)
    if owner.detail_overlay then
        pcall(function()
            owner.detail_overlay:unmount()
        end)
    end
    if owner.layout then
        pcall(function()
            owner.layout:unmount()
        end)
    end
    if owner.split then
        pcall(function()
            owner.split:unmount()
        end)
    end
    if owner.resize_group then
        pcall(vim.api.nvim_del_augroup_by_id, owner.resize_group)
    end
    state.owner = nil
end

function M.toggle(opts)
    if owner_valid() then
        M.close()
    else
        M.open(opts)
    end
end

function M.refresh()
    if owner_valid() then
        render()
    end
end

function M.current_task()
    return selected_task()
end

function M.add(opts)
    if not owner_valid() then
        return false
    end
    add_task(opts)
    return true
end

function M.add_notice(opts)
    if not owner_valid() then
        return false
    end
    add_notice(opts)
    return true
end

function M.edit(id)
    if not owner_valid() then
        return false
    end
    local task = id and service().store:get(id) or selected_task()
    if not task then
        error(i18n.t("task_not_found", id or "?"))
    end
    if task.kind == "notice" then
        local reopen =
            { mode = state.mode, view = state.view, filters = vim.deepcopy(state.filters), selected_id = task.id }
        M.close()
        require("todo.ui.notice_form").open(task, function(input)
            local result, errors = service():update(task.id, input, task.sync_revision)
            if result then
                require("todo")._reschedule_reminders()
            end
            return result, errors
        end, {
            on_close = function()
                if not owner_valid() then
                    M.open(reopen)
                end
            end,
        })
    else
        open_task_form(task, function(input)
            local result, errors = service():update(task.id, input, task.sync_revision)
            if result then
                require("todo")._reschedule_reminders()
            end
            return result, errors
        end)
    end
    return true
end

function M.is_open()
    return owner_valid()
end

function M.inspect_state()
    return state
end

return M
