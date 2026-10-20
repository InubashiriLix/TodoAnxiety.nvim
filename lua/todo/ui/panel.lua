local config = require("todo.config")
local grouping = require("todo.ui.grouping")
local highlights = require("todo.ui.highlights")
local i18n = require("todo.i18n")
local form = require("todo.ui.form")
local markdown = require("todo.ui.markdown")
local model = require("todo.model")
local urgency = require("todo.urgency")
local viewmodel = require("todo.ui.viewmodel")
local actions = require("todo.ui.actions")
local hints = require("todo.ui.hints")

local Input = require("nui.input")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
local Popup = require("nui.popup")
local Split = require("nui.split")

local M = {}
local ns = vim.api.nvim_create_namespace("todo_dashboard")
local selection_ns = vim.api.nvim_create_namespace("todo_dashboard_selection")
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
    scope = "active",
    group = "status",
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
local function is_today()
    return state.scope == "today"
end
local function service_view()
    return grouping.compose(state.scope, state.group)
end
local function section_view()
    return grouping.group_view(state.scope, state.group)
end
local function scope_label(scope)
    return i18n.t(scope or state.scope)
end
local function group_label(group, short)
    group = group or state.group
    if group == "urgency" then
        return i18n.t(short and "by_urgency_short" or "by_urgency")
    elseif group == "time" then
        return i18n.t(short and "by_time_short" or "by_time")
    elseif group == "tag" then
        return i18n.t(short and "by_tag_short" or "by_tag")
    end
    return i18n.t("status")
end

local function current_row()
    return state.rows[state.cursor_row]
end

local function service()
    return require("todo")._service()
end
local function display_planner()
    local svc = service()
    local snapshot = state.owner and state.owner.snapshot
    return require("todo.planning").new(snapshot and snapshot.ws or require("todo.workspace").new(svc.store), svc)
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
    for _, name in ipairs({
        "split",
        "header",
        "list",
        "footer",
        "detail",
        "detail_overlay",
        "saved_detail",
        "max_overlay",
        "transient",
        "help",
    }) do
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
    for _, name in ipairs({ "popup", "transient", "help" }) do
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
        and (reminder_owner.component.winid == winid or (reminder_owner.help and reminder_owner.help.winid == winid))
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
    require("todo.ui.surface").write(buf, lines)
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
    for _, view in ipairs(grouping.scopes) do
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
    local capacity
    if is_today() then
        local p = display_planner():today()
        local planned = 0
        for _, i in ipairs(p.items) do
            planned = planned + (i.minutes or 0)
        end
        capacity = string.format(
            "%s · %dm / %dm · %dm %s",
            p.date,
            planned,
            p.capacity_minutes,
            math.floor(p.capacity_minutes * (p.reserve_ratio or 0.25)),
            config.get().language == "zh-CN" and "预留" or "reserve"
        )
    end
    local group_hint = grouping.supports_group(state.scope)
            and ("  " .. i18n.t("group") .. ": " .. group_label(state.group))
        or nil
    if compact then
        local title = "  TODO.NVIM · "
            .. (capacity or (scope_label() .. (group_hint and (" · " .. group_label(state.group, true)) or "")))
        local tab_lines, spans = tab_layout(true, width, 2, " ")
        local result = { viewmodel.truncate(title, width) }
        for _, line in ipairs(tab_lines) do
            result[#result + 1] = viewmodel.truncate(line, width)
        end
        if group_hint then
            result[#result + 1] = viewmodel.truncate(group_hint, width)
        end
        if #filters > 0 then
            result[#result + 1] = viewmodel.truncate("  " .. table.concat(filters, "   "), width)
        end
        return result, spans, 2
    end
    local tab_lines, spans = tab_layout(false, width, 1, "  TODO.NVIM  ")
    local result = vim.deepcopy(tab_lines)
    if group_hint then
        result[#result + 1] = group_hint
    end
    result[#result + 1] = #filters > 0 and ("  " .. table.concat(filters, "   "))
        or (capacity and ("  " .. capacity) or ("  / " .. i18n.t("search_placeholder")))
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
    local relative = state.group == "time"
    local rows = state.rows
    local marks = { today = {}, review = {}, ai = {} }
    local marked, value = pcall(function()
        local svc = service()
        if not svc.store.db then
            return { today = {}, review = {}, ai = {} }
        end
        local ws = require("todo.workspace").new(svc.store)
        local date = is_today() and display_planner():today().date or display_planner():date()
        return require("todo.ui.task_mark").marks(ws, svc, date, state.scope)
    end)
    if marked then
        marks = value
    end
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
        else
            local task = row.task
            local indent = string.rep("  ", row.depth)
            local reason, reason_group = urgency_label(task)
            local mark = require("todo.ui.task_mark")
            local plan_state = mark.plan_state(task, marks)
            local line1, line2, info = viewmodel.card(task, math.max(10, width - 3 - #indent), reason, {
                relative = relative,
                plan_state = plan_state,
                ai_selected = marks.ai[task.sync_uuid] == true,
                bars = false,
            })
            info = info
                or {
                    left_group = nil,
                    right_group = nil,
                    priority_group = "TodoMuted",
                    due_text = nil,
                    done = mark.done(task),
                    badge = string.format("[P%d]", task.priority or 3),
                }
            if task.planning then
                line2 = string.format(
                    "%dm %s · %s",
                    task.planning.minutes or 0,
                    task.planning.locked and "[locked]" or "",
                    task.planning.next_action or ""
                )
            end
            local base_prefix = indent
            local bar_prefix = base_prefix .. (info.left_group and "▌ " or "  ")
            local right_bar = info.right_group and "▐" or ""
            local function bar_line(content)
                local reserve = right_bar ~= "" and 1 or 0
                local available = math.max(1, width - vim.fn.strdisplaywidth(bar_prefix) - reserve)
                local text = viewmodel.truncate(content or "", available)
                local padding = width
                    - vim.fn.strdisplaywidth(bar_prefix)
                    - vim.fn.strdisplaywidth(text)
                    - reserve
                return bar_prefix .. text .. string.rep(" ", math.max(0, padding)) .. right_bar
            end
            local first = #lines + 1
            lines[#lines + 1] = bar_line(line1)
            lines[#lines + 1] = bar_line(line2)
            lines[#lines + 1] = bar_line("")
            mappings[first] = row
            mappings[first + 1] = row
            mappings[first + 2] = row
            order[#order + 1] = task
            local line1_text = lines[first]
            local line2_text = lines[first + 1]
            if info.left_group or info.ai_group then
                for row = 0, 2 do
                    local group = row == 0 and (info.ai_group or info.left_group) or info.left_group
                    if group then
                        decorations[#decorations + 1] = {
                            line = first - 1 + row,
                            from = #base_prefix,
                            to = #base_prefix + #"▌",
                            group = group,
                        }
                    end
                end
            end
            local badge = info.badge or string.format("[P%d]", task.priority)
            local badge_start = line1_text:find(badge, 1, true)
            if badge_start then
                decorations[#decorations + 1] = {
                    line = first - 1,
                    from = badge_start - 1,
                    to = badge_start - 1 + #badge,
                    group = info.priority_group or ("TodoPriority" .. task.priority),
                }
            end
            if info.due_text and info.due_text ~= "" then
                local due_start = line2_text:find(info.due_text, 1, true)
                if due_start then
                    decorations[#decorations + 1] = {
                        line = first,
                        from = due_start - 1,
                        to = due_start - 1 + #info.due_text,
                        group = info.due_group,
                    }
                end
            end
            if info.right_group then
                for _, line_index in ipairs({ first, first + 1, first + 2 }) do
                    local text = lines[line_index]
                    local right_start = text:find("▐", 1, true)
                    if right_start then
                        decorations[#decorations + 1] = {
                            line = line_index - 1,
                            from = right_start - 1,
                            to = right_start - 1 + #"▐",
                            group = info.right_group,
                        }
                    end
                end
            end
            if reason_group and reason then
                local reason_start = line2_text:find(reason, 1, true)
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
                local tag_start = line2_text:find(marker, 1, true)
                if tag_start then
                    decorations[#decorations + 1] = {
                        line = first,
                        from = tag_start - 1,
                        to = tag_start - 1 + #marker,
                        group = highlights.tag(tag),
                    }
                end
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
    if not task then
        return {}, {}
    end
    local snapshot = state.owner and state.owner.snapshot
    if not (snapshot and snapshot.live) then
        return markdown.task_lines(task, { notes = snapshot and snapshot:list("note") }), {}
    end
    local key = tostring(task.id)
        .. ":"
        .. tostring(snapshot and snapshot:version("task") or 0)
        .. ":"
        .. tostring(snapshot and snapshot:version("note") or 0)
    local owner = state.owner
    if owner and owner.detail_cache and owner.detail_cache.key == key then
        return owner.detail_cache.lines, owner.detail_cache.decorations
    end
    local lines = markdown.task_lines(task, { notes = snapshot and snapshot:list("note") })
    local decorations = {}
    if owner then
        owner.detail_cache = { key = key, lines = lines, decorations = decorations }
    end
    return lines, decorations
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

local render

local function L(en, zh)
    return config.get().language == "zh-CN" and zh or en
end

local function planning_membership(task, display)
    local svc = service()
    if not svc.store.db then
        return nil, os.date("%Y-%m-%d")
    end
    local planner = display and display_planner()
        or require("todo.planning").new(require("todo.workspace").new(svc.store), svc)
    local date = is_today() and planner:today().date or planner:date()
    local plan = planner:today(date)
    for _, item in ipairs(plan.items) do
        if task and item.task_uuid == task.sync_uuid then
            return item, date
        end
    end
    return nil, date
end

local function planner_action(action, role)
    local ok, err = pcall(function()
        local svc = service()
        local ws = require("todo.workspace").new(svc.store)
        local planner = require("todo.planning").new(ws, svc)
        local task = selected_task()
        if role == "list" or role == "sidebar" then
            local row = current_row()
            task = row and row.kind == "task" and row.task or nil
        end
        if action == "plan" then
            local scope = {}
            for _, task in ipairs(state.tasks or {}) do
                if task.status == "todo" or task.status == "in_progress" then
                    scope[#scope + 1] = task.sync_uuid
                end
            end
            local date = is_today() and (state.planning_date or planner:today().date) or nil
            local current = is_today() and planner:date() or nil
            if date and current and not state.planning_date_explicit and date < current then
                date = current
                state.planning_date = current
                ws.store:set_setting("planning_view_date", current)
            end
            require("todo").plan({
                date = date,
                view = state.scope,
                filters = vim.deepcopy(state.filters or {}),
                task_uuids = is_today() and nil or scope,
            })
            return
        end
        if action == "capacity" then
            local p = planner:today()
            vim.ui.input(
                { prompt = L("Available minutes: ", "可用分钟数："), default = tostring(p.capacity_minutes) },
                function(value)
                    local n = tonumber(value)
                    if n and n > 0 and n <= 1440 then
                        planner:transaction("Planning capacity", function()
                            p.capacity_minutes = n
                            ws:put("plan", p.date, p)
                        end)
                        render()
                    end
                end
            )
            return
        end
        if action == "date" then
            vim.ui.input(
                { prompt = L("Plan date YYYY-MM-DD: ", "计划日期 YYYY-MM-DD："), default = planner:today().date },
                function(date)
                    if date then
                        require("todo").today(date)
                    end
                end
            )
            return
        end
        assert(task, L("Select a task", "请选择任务"))
        local member, plan_date = planning_membership(task)
        if action == "clarify" then
            require("todo").clarify(task.id)
        elseif action == "toggle_today" or action == "add" then
            local item, date = planning_membership(task)
            if item then
                planner:change(date, task.sync_uuid, false)
            else
                assert(
                    not task.archived_at and (task.status == "todo" or task.status == "in_progress"),
                    "Only active tasks can be added"
                )
                planner:add(task.sync_uuid, date)
            end
            render()
        elseif action == "remove" then
            assert(member, "Task is not in the selected plan")
            planner:change(plan_date, task.sync_uuid, false)
            render()
        elseif action == "lock" then
            assert(member, "Task is not in the selected plan")
            planner:change(plan_date, task.sync_uuid, { locked = not member.locked })
            render()
        elseif action == "up" or action == "down" then
            assert(member, "Task is not in the selected plan")
            planner:move(plan_date, task.sync_uuid, action == "up" and -1 or 1)
            render()
        elseif action == "item" then
            local item = vim.deepcopy(assert(member, "Task is not in the selected plan"))
            local fields = {
                { key = "next_action", label = L("Next action", "下一步") },
                { key = "completion", label = L("Done when", "完成标准") },
                { key = "minutes", label = L("Estimated minutes", "预计分钟数") },
                { key = "group", label = L("Execution group", "执行分组") },
            }
            vim.ui.select(fields, {
                prompt = L("Planning details", "计划详情"),
                format_item = function(f)
                    return f.label
                end,
            }, function(field)
                if not field then
                    return
                end
                local function apply(value)
                    planner:change(plan_date, task.sync_uuid, { [field.key] = value })
                    render()
                end
                if field.key == "minutes" then
                    vim.ui.input(
                        { prompt = field.label .. ": ", default = tostring(item.minutes or 30) },
                        function(value)
                            local n = tonumber(value)
                            if n and n >= 0 and n <= 1440 then
                                apply(n)
                            end
                        end
                    )
                elseif field.key == "group" then
                    local groups = {
                        { key = "now", label = L("Now", "现在做") },
                        { key = "next", label = L("Next", "接下来") },
                        { key = "optional", label = L("If time permits", "有余力再做") },
                    }
                    vim.ui.select(groups, {
                        prompt = field.label,
                        format_item = function(g)
                            return g.label
                        end,
                    }, function(g)
                        if g then
                            apply(g.key)
                        end
                    end)
                else
                    require("todo.ui.planner").editor(field.label, item[field.key] or "", apply)
                end
            end)
        elseif action == "note" then
            local notes = { { label = L("New note", "新建备注") } }
            for _, r in ipairs(ws:list("note")) do
                if r.value.task_uuid == task.sync_uuid then
                    notes[#notes + 1] = { label = r.value.text:sub(1, 70), record = r }
                end
            end
            vim.ui.select(notes, {
                prompt = L("Task notes", "任务备注"),
                format_item = function(n)
                    return n.label
                end,
            }, function(choice)
                if not choice then
                    return
                end
                local r = choice.record
                require("todo.ui.planner").editor(
                    L("Task note", "任务备注"),
                    r and r.value.text or "",
                    function(value)
                        planner:transaction("Task note", function()
                            ws:put("note", r and r.key or require("todo.sync.codec").uuid(), {
                                task_uuid = task.sync_uuid,
                                text = value,
                                source = "user",
                                created_at = r and r.value.created_at or os.time(),
                            }, r and r.revision)
                        end)
                        render()
                    end,
                    svc.store
                )
            end)
        end
    end)
    if not ok then
        vim.notify(tostring(err), vim.log.levels.WARN)
    end
end

local function today_tasks(motion, count)
    local function tasks_from(direction, limit)
        local result = {}
        local index = state.cursor_row
        while index >= 1 and index <= #state.rows and #result < limit do
            local row = state.rows[index]
            if row.kind == "task" then
                result[#result + 1] = row.task
            end
            index = index + direction
        end
        return result
    end
    local function tasks_between(first, last)
        local result = {}
        for index = math.min(first, last), math.max(first, last) do
            local row = state.rows[index]
            if row.kind == "task" then
                result[#result + 1] = row.task
            end
        end
        return result
    end
    if motion == "top" then
        return tasks_between(1, state.cursor_row)
    elseif motion == "bottom" then
        return tasks_between(state.cursor_row, #state.rows)
    elseif motion == "down" then
        return tasks_from(1, count or 2)
    elseif motion == "up" then
        return tasks_from(-1, count or 2)
    end
    return {}
end

local function today_apply(motion, count, role)
    if motion == "single" then
        local row = current_row()
        if row and row.kind == "task" then
            planner_action("toggle_today", role)
        end
        return
    end
    local tasks = today_tasks(motion, count)
    if #tasks == 0 then
        return
    end
    local svc = service()
    local ws = require("todo.workspace").new(svc.store)
    local planner = require("todo.planning").new(ws, svc)
    local date = is_today() and display_planner():today().date or display_planner():date()
    local plan = planner:today(date)
    local present = {}
    local all_present = true
    for _, task in ipairs(tasks) do
        for _, item in ipairs(plan.items) do
            if item.task_uuid == task.sync_uuid then
                present[task.sync_uuid] = true
            end
        end
        if not present[task.sync_uuid] then
            all_present = false
        end
    end
    local ok, err = pcall(function()
        planner:transaction(all_present and "Remove today range" or "Add today range", function()
            for _, task in ipairs(tasks) do
                if not task.archived_at and (task.status == "todo" or task.status == "in_progress") then
                    if all_present then
                        if present[task.sync_uuid] then
                            planner:change(date, task.sync_uuid, false)
                        end
                    elseif not present[task.sync_uuid] then
                        planner:add(task.sync_uuid, date)
                    end
                end
            end
        end)
    end)
    if not ok then
        vim.notify(tostring(err), vim.log.levels.WARN)
        return
    end
    render()
    vim.api.nvim_echo(
        { { string.format(L("TODAY: %d task(s) marked", "今日标记：%d 个任务"), #tasks), "WarningMsg" } },
        false,
        {}
    )
end

local function map_today_range(buf, role, opts)
    vim.keymap.set("n", "T", function()
        vim.api.nvim_echo(
            { { L("T: range mark (Tj/Tk/T3j/Tgg/TG)", "T：范围标记（Tj/Tk/T3j/Tgg/TG）"), "WarningMsg" } },
            false,
            {}
        )
    end, opts)
    for _, spec in ipairs({
        { "Tj", "down", 2 },
        { "Tk", "up", 2 },
        { "Tgg", "top", nil },
        { "TG", "bottom", nil },
    }) do
        vim.keymap.set("n", spec[1], function()
            today_apply(spec[2], spec[3], role)
        end, opts)
    end
    for count = 1, 9 do
        for _, direction in ipairs({ "j", "k" }) do
            vim.keymap.set("n", "T" .. count .. direction, function()
                today_apply(direction == "j" and "down" or "up", count, role)
            end, opts)
        end
    end
end

local function context_task(role)
    if role == "detail" or role == "overlay" then
        return selected_task()
    end
    if role == "list" or role == "sidebar" then
        local row = current_row()
        return row and row.kind == "task" and row.task or nil
    end
end

local function panel_context(role)
    local entries = actions.task_actions(context_task(role))
    vim.list_extend(entries, require("todo.ui.history").actions())
    local function add(key, en, zh, group)
        entries[#entries + 1] = { key = key, label = L(en, zh), group = group, modes = { "n" } }
    end
    local nav, page = L("Navigation", "导航"), L("Page", "页面")
    add("+", "Maximize / restore pane", "最大化／还原当前区域", nav)
    add("P", "AI planning", "AI 编排", page)
    if context_task(role) then
        add("Q", "Clarify task with AI", "AI 澄清任务", page)
        local task = context_task(role)
        local item = planning_membership(task, true)
        if
            item
            or (
                not task.archived_at
                and (task.status == "todo" or task.status == "in_progress")
            )
        then
            add(
                "t",
                item and "Remove from plan" or "Add to plan",
                item and "移出计划" or "加入计划",
                page
            )
            add("T / Tj / T3j / Tgg / TG", "Mark today range", "今日范围内标记", page)
        end
        add("N", "Add note", "添加备注", page)
    end
    if is_today() then
        local item = planning_membership(context_task(role))
        if item then
            add("L", item.locked and "Unlock" or "Lock", item.locked and "解锁" or "锁定", page)
            add("J / K", "Reorder", "调整顺序", page)
            add("m", "Planning fields", "计划字段", page)
        end
        add("C", "Daily capacity", "每日容量", page)
        add("b", "Choose date", "选择日期", page)
    end
    if role == "detail" or role == "overlay" then
        add("j/k", "Read lines", "逐行阅读", nav)
        add("gg/G", "Top / bottom", "首行／末行", nav)
        add("Ctrl-u/d", "Half page", "半页滚动", nav)
        if role == "detail" then
            add("h", "Return to list", "返回列表", nav)
        end
    else
        add("j/k", "Select row", "选择条目", nav)
        add("gg/G", "First / last row", "首项／末项", nav)
        add("Ctrl-u/d", "Half page", "半页跳转", nav)
        if context_task(role) then
            add("Enter", "Details", "详情", nav)
        else
            add("Enter", "Fold section", "折叠分组", nav)
        end
        if state.owner and state.owner.detail and role == "list" then
            add("l", "Focus details", "进入详情", nav)
        end
        add("Tab / za", "Fold section", "折叠当前分组", nav)
        add("zR / zM", "Expand / collapse all", "全部展开／折叠", nav)
    end
    if role ~= "overlay" then
        add("a / n", "New task / notice", "新建任务／提醒", page)
        add("/", "Search", "搜索", page)
        add("f", "Filter", "筛选", page)
        add("[ / ]", "Previous / next scope", "上一／下一范围", page)
        add("v", "Choose view / grouping", "选择视图／分组", page)
        if grouping.supports_group(state.scope) then
            add("o", "Change grouping", "切换分组", page)
        end
        add("g", "Manage tags", "管理标签", page)
        add("r", "Refresh", "刷新", page)
        add("Esc", "Clear filters, else close", "清除筛选，否则关闭", page)
    end
    add(
        "q",
        role == "overlay" and "Close details" or "Close dashboard",
        role == "overlay" and "关闭详情" or "关闭面板",
        page
    )
    if role == "overlay" then
        add("Esc", "Close details", "关闭详情", page)
    end
    add("? / F1", "Complete help", "完整帮助", page)
    local title = (role == "detail" or role == "overlay") and i18n.t("details")
        or (scope_label() .. (grouping.supports_group(state.scope) and (" · " .. group_label(state.group)) or ""))
    local task = context_task(role)
    if task then
        title = title .. " · " .. i18n.t(task.status)
    end
    return { title = title, actions = entries }
end

local function footer_lines(width, role)
    return hints.compact(panel_context(role or "list").actions, width)
end

local function focus_selected(owner)
    local win = owner.split and owner.split.winid or owner.list.winid
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local target = current_row()
    local selected_line
    local buf = owner.split and owner.split.bufnr or owner.list.bufnr
    vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)
    for line, row in pairs(state.task_lines) do
        if row == target then
            selected_line = not selected_line and line or math.min(selected_line, line)
            vim.api.nvim_buf_set_extmark(buf, selection_ns, line - 1, 0, {
                end_row = line,
                end_col = 0,
                hl_group = "TodoSelected",
                hl_eol = true,
                priority = 80,
            })
        end
    end
    if selected_line then
        pcall(vim.api.nvim_win_set_cursor, win, { selected_line, 0 })
        pcall(vim.api.nvim_win_call, win, function()
            vim.cmd("normal! zz")
        end)
    end
end

local function render_float(owner)
    local header_visible = owner.header.winid and vim.api.nvim_win_is_valid(owner.header.winid)
    local header, spans, tab_line =
        header_content(false, header_visible and vim.api.nvim_win_get_width(owner.header.winid) or vim.o.columns)
    -- Counts can gain a digit while open and push tabs onto an extra line; the
    -- header box was sized at mount, so drop anything that no longer fits.
    local room = header_visible and vim.api.nvim_win_get_height(owner.header.winid) or #header
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
            span.view == state.scope and "TodoTabActive" or "TodoTabInactive"
        )
    end
    add_hl(owner.header.bufnr, #header - 1, 0, #header[#header], "TodoMuted")

    local width = vim.api.nvim_win_get_width(owner.list.winid)
    local lines, mappings, order, decorations = list_content(width)
    state.task_lines, state.task_order = mappings, order
    set_buffer(owner.list.bufnr, lines)
    owner.list.border:set_text(
        "top",
        " " .. scope_label() .. (grouping.supports_group(state.scope) and (" · " .. group_label(state.group)) or "") .. " ",
        "left"
    )
    apply_decorations(owner.list.bufnr, decorations)

    if owner.detail then
        local details, detail_decorations = detail_content(selected_task())
        set_buffer(owner.detail.bufnr, details)
        apply_decorations(owner.detail.bufnr, detail_decorations)
    end
    set_buffer(
        owner.footer.bufnr,
        footer_lines(
            owner.footer.winid
                    and vim.api.nvim_win_is_valid(owner.footer.winid)
                    and vim.api.nvim_win_get_width(owner.footer.winid)
                or vim.o.columns,
            "list"
        )
    )
    hints.highlight(owner.footer.bufnr)
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
    local footer_start = #lines
    owner.footer_start = footer_start
    vim.list_extend(lines, footer_lines(width, "sidebar"))
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
            span.view == state.scope and "TodoTabActive" or "TodoTabInactive"
        )
    end
    if filtered then
        add_hl(owner.split.bufnr, #header - 1, 0, -1, "TodoMuted")
    end
    apply_decorations(owner.split.bufnr, decorations, list_offset)
    hints.highlight(owner.split.bufnr, footer_start, #lines)
    focus_selected(owner)
end

render = function()
    if not owner_valid() then
        return
    end
    local ok, tasks, stats = pcall(function()
        return service():list(service_view(), state.filters), service():stats()
    end)
    if not ok then
        vim.notify(i18n.t("db_error", tasks), vim.log.levels.ERROR)
        return
    end
    state.tasks, state.stats = tasks, stats
    state.rows = grouping.rows(grouping.sections(tasks, section_view()), collapsed_map())
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

local function repaint(selection_only)
    if selection_only then
        local owner = state.owner
        if owner.split then
            local buf, start = owner.split.bufnr, owner.footer_start
            local lines = vim.api.nvim_buf_get_lines(buf, 0, start, false)
            vim.list_extend(lines, footer_lines(vim.api.nvim_win_get_width(owner.split.winid), "sidebar"))
            if require("todo.ui.surface").write(buf, lines) then
                hints.highlight(buf, start, #lines)
            end
        else
            if owner.detail then
                local lines = detail_content(selected_task())
                require("todo.ui.surface").write(owner.detail.bufnr, lines)
            end
            local lines = footer_lines(vim.api.nvim_win_get_width(owner.footer.winid), "list")
            if require("todo.ui.surface").write(owner.footer.bufnr, lines) then
                hints.highlight(owner.footer.bufnr)
            end
        end
        focus_selected(owner)
        return
    end
    if state.owner.split then
        render_sidebar(state.owner)
    else
        render_float(state.owner)
    end
end

local function select_row(index)
    if #state.rows == 0 then
        return
    end
    local started = require("todo.performance").start()
    state.cursor_row = math.max(1, math.min(#state.rows, index))
    local row = current_row()
    if row and row.kind == "task" then
        state.selected_id = row.task.id
    end
    repaint(true)
    require("todo.performance").finish("panel.navigate", started)
end

local function select_delta(delta)
    select_row(state.cursor_row + delta)
end

local function select_half_page(direction)
    if #state.rows == 0 then
        return
    end
    local owner = state.owner
    local win = owner.split and owner.split.winid or owner.list.winid
    local step = math.max(1, math.floor(vim.api.nvim_win_get_height(win) / 2))
    local current_line = vim.api.nvim_win_get_cursor(win)[1]
    local last_line = vim.api.nvim_buf_line_count(owner.split and owner.split.bufnr or owner.list.bufnr)
    local target_line = math.max(1, math.min(last_line, current_line + direction * step))
    local row_indices = {}
    for index, row in ipairs(state.rows) do
        row_indices[row] = index
    end
    -- Task cards span two mapped lines and a blank separator. Search in the
    -- jump direction so a target inside a card still advances to another row.
    for line = target_line, direction > 0 and last_line or 1, direction do
        local index = row_indices[state.task_lines[line]]
        if index and index ~= state.cursor_row then
            select_row(index)
            return
        end
    end
    select_row(direction > 0 and #state.rows or 1)
end

local function apply_view(scope, group)
    state.scope = scope
    state.group = grouping.supports_group(scope) and group or "status"
    state.view = grouping.compose(state.scope, state.group)
    state.selected_id, state.cursor_row = nil, 1
    render()
end

local function change_view(view)
    apply_view(grouping.scope_of(view), grouping.group_of(view))
end

local function change_scope(scope)
    apply_view(scope, state.group)
end

local function change_group(group)
    if not grouping.supports_group(state.scope) then
        return
    end
    apply_view(state.scope, group)
end

local function cycle_view(delta)
    local scopes = grouping.scopes
    local index = 1
    for i, scope in ipairs(scopes) do
        if scope == state.scope then
            index = i
            break
        end
    end
    apply_view(scopes[(index - 1 + delta) % #scopes + 1], state.group)
end

local function cycle_group(delta)
    if not grouping.supports_group(state.scope) then
        return
    end
    local groups = grouping.groups
    local index = 1
    for i, group in ipairs(groups) do
        if group == state.group then
            index = i
            break
        end
    end
    change_group(groups[(index - 1 + delta) % #groups + 1])
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
    state.rows = grouping.rows(grouping.sections(state.tasks, section_view()), collapsed)
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
    local sections = grouping.sections(state.tasks, section_view())
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
        view = state.scope,
        filters = vim.deepcopy(state.filters),
        selected_id = state.selected_id,
    }
    M.close()
    local persisted
    form.open(task, function(input)
        local result, errors
        if persisted then
            result, errors = service():update(persisted.id, input, persisted.sync_revision)
            if result then
                require("todo")._reschedule_reminders()
            end
        else
            result, errors = save_task(input)
        end
        if result then
            persisted = result
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
    local add_to_today = is_today()
    local last_interval = service():last_reminder_interval()
    open_task_form({
        title = opts.title or "",
        reminder = last_interval and { repeat_interval_seconds = last_interval } or nil,
    }, function(input)
        local result, errors
        if add_to_today then
            local svc = service()
            local planner = require("todo.planning").new(require("todo.workspace").new(svc.store), svc)
            result = planner:create(input)
        else
            result, errors = service():create(input)
        end
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
            { mode = state.mode, view = state.scope, filters = vim.deepcopy(state.filters), selected_id = task.id }
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
    hints.attach(component.bufnr, function()
        return {
            title = title,
            actions = {
                { key = "j/k / Up/Down / Tab/Shift-Tab", label = L("Choose item", "选择条目") },
                { key = "Enter", label = L("Confirm", "确认") },
                { key = "q / Esc / Ctrl-c", label = L("Cancel", "取消") },
            },
        }
    end, { owner = owner })
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
    local win = owner.max_overlay and owner.max_overlay.winid
        or owner.split and owner.split.winid
        or (owner.list and owner.list.winid)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_current_win, win)
    end
end

--- Return focus to the window that opened a transient when it is still part of
--- the panel; otherwise fall back to the list/sidebar.
local function focus_origin(owner, origin)
    if origin and vim.api.nvim_win_is_valid(origin) and todo_has_window(owner, origin) then
        pcall(vim.api.nvim_set_current_win, origin)
        return
    end
    if owner_valid() then
        focus_list(owner)
    end
end

--- An ordinary, unarchived todo/in-progress task whose deadline already passed.
local function postpone_eligible(task)
    if not task then
        return false
    end
    if (task.kind or "task") ~= "task" or task.archived_at then
        return false
    end
    if task.status ~= "todo" and task.status ~= "in_progress" then
        return false
    end
    return urgency.calculate(task).level == "overdue"
end

local function error_detail(errors)
    if type(errors) == "table" then
        local parts = {}
        for key, value in pairs(errors) do
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
        end
        if #parts > 0 then
            table.sort(parts)
            return table.concat(parts, ", ")
        end
    end
    return tostring(errors)
end

--- The sync Store wrapper raises the localized `sync_stale_form` text (it has no
--- English "conflict" marker), so match the actual localized phrase first.
local function is_conflict_error(err)
    local text = type(err) == "string" and err or tostring(err)
    local lowered = text:lower()
    local localized = (i18n.t("sync_stale_form") or ""):lower()
    if localized ~= "" and lowered:find(localized, 1, true) then
        return true
    end
    return lowered:find("conflict", 1, true) ~= nil or lowered:find("revision", 1, true) ~= nil
end

--- Explicit revision precheck: compare the captured revision with the live row.
local function revision_stale(id, revision)
    if revision == nil then
        return false
    end
    local ok, current = pcall(function()
        local svc = service()
        return svc.store and svc.store.get and svc.store:get(id)
    end)
    return ok and current ~= nil and current.sync_revision ~= revision
end

local function postpone_error_message(errors)
    errors = errors or {}
    if errors.duration then
        return i18n.t("postpone_invalid")
    elseif errors.eligible then
        return i18n.t("postpone_ineligible")
    elseif errors.id then
        return i18n.t("postpone_not_found")
    elseif errors.revision then
        return i18n.t("postpone_conflict")
    end
    return i18n.t("postpone_failed") .. ": " .. i18n.t("db_error", error_detail(errors))
end

local function refresh_overlay(owner)
    local overlay = owner and owner.detail_overlay
    if not overlay or not overlay.bufnr or not vim.api.nvim_buf_is_valid(overlay.bufnr) then
        return
    end
    local lines, decorations = detail_content(selected_task())
    set_buffer(overlay.bufnr, lines)
    apply_decorations(overlay.bufnr, decorations)
end

--- Open the postpone prompt for the current selection. `source` is "list" for
--- the list/sidebar (must use the highlighted row, never a stale selection)
--- and "detail" for the fixed pane or overlay (the displayed task).
local function postpone(source)
    local owner = state.owner
    if not owner_valid() then
        return
    end
    local task
    if source == "list" then
        local row = current_row()
        if not row or row.kind ~= "task" then
            vim.notify(i18n.t("missing_task"), vim.log.levels.WARN)
            return
        end
        task = row.task
    else
        task = selected_task()
    end
    if not task then
        vim.notify(i18n.t("missing_task"), vim.log.levels.WARN)
        return
    end
    if not postpone_eligible(task) then
        vim.notify(i18n.t("postpone_ineligible"), vim.log.levels.WARN)
        return
    end
    local id, revision = task.id, task.sync_revision
    local origin = vim.api.nvim_get_current_win()
    local token = (owner.transient_token or 0) + 1
    owner.transient_token = token

    local function open_input(default_value)
        if owner.closed or state.owner ~= owner or owner.transient_token ~= token then
            return
        end
        close_transient(owner)
        local input
        input = Input({
            relative = "editor",
            position = { row = 2, col = "50%" },
            size = { width = math.max(10, math.min(60, vim.o.columns - 8)) },
            border = {
                style = config.get().ui.float.border,
                text = {
                    top = " " .. i18n.t("postpone_title") .. " ",
                    bottom = " " .. i18n.t("postpone_hint") .. " ",
                    bottom_align = "center",
                },
            },
            win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
            zindex = 80,
        }, {
            default_value = default_value,
            on_submit = function(value)
                if owner.closed or state.owner ~= owner or owner.transient ~= input then
                    return
                end
                owner.transient = nil
                if revision_stale(id, revision) then
                    vim.notify(i18n.t("postpone_conflict"), vim.log.levels.ERROR)
                    focus_origin(owner, origin)
                    return
                end
                local ok, result, errors = pcall(function()
                    return service():postpone(id, value, os.time(), revision)
                end)
                if not ok then
                    local message
                    if is_conflict_error(result) then
                        message = i18n.t("postpone_conflict")
                    else
                        message = i18n.t("postpone_failed") .. ": " .. i18n.t("db_error", tostring(result))
                    end
                    vim.notify(message, vim.log.levels.ERROR)
                    focus_origin(owner, origin)
                    return
                end
                if not result then
                    local message = postpone_error_message(errors)
                    vim.notify(message, vim.log.levels.ERROR)
                    if errors and errors.duration then
                        -- NUI auto-unmounts on submit; reopen with the same text
                        -- unless the panel, prompt, or token was replaced meanwhile.
                        vim.schedule(function()
                            if owner.closed or state.owner ~= owner then
                                return
                            end
                            if owner.transient_token ~= token or owner.transient ~= nil then
                                return
                            end
                            open_input(value)
                        end)
                    else
                        focus_origin(owner, origin)
                    end
                    return
                end
                state.selected_id = id
                require("todo")._reconcile_reminders()
                vim.notify(i18n.t("postponed", model.deadline_text(result)), vim.log.levels.INFO)
                render()
                refresh_overlay(owner)
                focus_origin(owner, origin)
            end,
            on_close = function()
                if owner.transient == input then
                    owner.transient = nil
                end
            end,
        })
        owner.transient = input
        owner.transient_token = token
        input:mount()
        hints.attach(input.bufnr, function(mode)
            local entries = {
                { key = "Enter", label = L("Postpone by entered duration", "按输入时长延期") },
                { key = "Esc / Ctrl-q", label = L("Cancel", "取消") },
            }
            if mode == "n" then
                entries[#entries + 1] = { key = "q", label = L("Cancel", "取消") }
                entries[#entries + 1] = { key = "i", label = L("Edit duration", "输入时长") }
            end
            return { title = i18n.t("postpone_title"), actions = entries }
        end, { owner = owner })
        local cancel = function()
            if owner.closed or state.owner ~= owner or owner.transient ~= input then
                return
            end
            close_transient(owner)
            focus_origin(owner, origin)
        end
        vim.keymap.set("n", "<Esc>", cancel, { buffer = input.bufnr, silent = true })
        vim.keymap.set("i", "<Esc>", function()
            vim.schedule(cancel)
        end, { buffer = input.bufnr, silent = true })
        vim.keymap.set("n", "q", cancel, { buffer = input.bufnr, silent = true })
        vim.keymap.set({ "n", "i" }, "<C-q>", function()
            vim.schedule(cancel)
        end, { buffer = input.bufnr, silent = true })
        vim.api.nvim_create_autocmd("WinLeave", {
            buffer = input.bufnr,
            once = true,
            callback = function()
                vim.schedule(function()
                    if owner.closed or state.owner ~= owner or owner.transient ~= input then
                        return
                    end
                    -- NUI unmounts before its scheduled submit callback runs.
                    -- A destroyed input window is a submit/close, not a focus
                    -- escape; leave the callback to finish the operation.
                    if not input.winid or not vim.api.nvim_win_is_valid(input.winid) then
                        return
                    end
                    local target_win = vim.api.nvim_get_current_win()
                    if owner.help and owner.help.winid == target_win then
                        return
                    end
                    close_transient(owner)
                    if owner.mode == "float" and not owner_has_window(owner, target_win) then
                        M.close()
                    else
                        focus_origin(owner, origin)
                    end
                end)
            end,
        })
    end

    open_input("1d")
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
    hints.attach(search.bufnr, function(mode)
        local entries = {
            { key = "Enter", label = L("Apply search", "应用搜索") },
            { key = "Esc / Ctrl-q", label = L("Clear and return", "清除并返回") },
        }
        if mode == "n" then
            entries[#entries + 1] = { key = "q", label = L("Clear and return", "清除并返回") }
            entries[#entries + 1] = { key = "i", label = L("Edit query", "编辑搜索词") }
        end
        return { title = i18n.t("search"), actions = entries }
    end, { owner = owner })
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
                if owner.help and owner.help.winid == target_win then
                    return
                end
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
    local win = vim.api.nvim_get_current_win()
    local role = owner.detail and owner.detail.winid == win and "detail"
        or owner.detail_overlay and owner.detail_overlay.winid == win and "overlay"
        or owner.split and "sidebar"
        or "list"
    hints.show(function()
        return panel_context(role)
    end, { owner = owner })
end

local function dispatch_task(role, id, callback)
    return function()
        local task = context_task(role)
        if not actions.allowed(task, id) then
            vim.notify(
                L("This operation is unavailable for the current item", "当前条目不适用此操作"),
                vim.log.levels.WARN
            )
            return
        end
        callback()
        local owner = state.owner
        if
            owner
            and owner.detail_overlay
            and owner.detail_overlay.winid
            and vim.api.nvim_win_is_valid(owner.detail_overlay.winid)
        then
            refresh_overlay(owner)
        end
    end
end

local function contextual_keys(buf, role)
    local callbacks = {
        start = function()
            change_status("in_progress")
        end,
        reopen = function()
            change_status("todo")
        end,
        done = function()
            change_status("done")
        end,
        archive = function()
            archive_task(false)
        end,
        restore = function()
            archive_task(true)
        end,
    }
    for _, key in ipairs({ "s", "x", "A" }) do
        vim.keymap.set("n", key, function()
            local action = actions.for_key(context_task(role), key)
            if action then
                dispatch_task(role, action.id, callbacks[action.id])()
            end
        end, { buffer = buf, silent = true })
    end
end

local function render_overlay(overlay)
    local lines, decorations = detail_content(selected_task())
    set_buffer(overlay.bufnr, lines)
    apply_decorations(overlay.bufnr, decorations)
end

local function set_detail_navigation(buf)
    -- Both detail surfaces reuse this buffer, so overwrite any stale task
    -- navigation mappings whenever either surface is mounted.
    for _, mapping in ipairs({
        { "j", "Next detail line" },
        { "k", "Previous detail line" },
        { "gg", "Go to top of details" },
        { "G", "Go to bottom of details" },
        { "<C-u>", "Scroll details half a page up" },
        { "<C-d>", "Scroll details half a page down" },
    }) do
        vim.keymap.set("n", mapping[1], mapping[1], { buffer = buf, silent = true, desc = mapping[2] })
    end
end

local function guard_navigation(buf)
    for _, key in ipairs({
        "<C-h>",
        "<C-j>",
        "<C-k>",
        "<C-l>",
        "<LeftMouse>",
        "<LeftDrag>",
        "<LeftRelease>",
        "<2-LeftMouse>",
        "<3-LeftMouse>",
        "<4-LeftMouse>",
        "<RightMouse>",
        "<RightDrag>",
        "<RightRelease>",
        "<MiddleMouse>",
        "<MiddleDrag>",
        "<MiddleRelease>",
    }) do
        vim.keymap.set({ "n", "x" }, key, "<Nop>", { buffer = buf, silent = true, nowait = true })
    end
end

local function toggle_maximize(component)
    local owner = state.owner
    if not owner or owner.closed then
        return
    end
    if owner.split then
        if owner.max_overlay then
            owner.max_overlay:unmount()
            owner.max_overlay = nil
            focus_list(owner)
        else
            owner.max_overlay = Popup({
                bufnr = component.bufnr,
                relative = "editor",
                position = "50%",
                size = require("todo.ui.responsive").size(vim.o.columns, vim.o.lines),
                enter = true,
                border = { style = "rounded", text = { top = " TODO · + " .. L("Restore", "还原") .. " " } },
                win_options = { wrap = false, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
                zindex = 65,
            })
            owner.max_overlay:mount()
        end
    else
        if owner.maximized then
            owner.maximized = nil
        else
            owner.maximized = component
        end
        owner.reflow()
        if component.winid and vim.api.nvim_win_is_valid(component.winid) then
            vim.api.nvim_set_current_win(component.winid)
        end
    end
end

local function open_details()
    local task = require_task()
    if not task then
        return
    end
    local owner = state.owner
    if owner.maximized and owner.saved_detail then
        owner.maximized = owner.saved_detail
        owner.reflow()
        vim.api.nvim_set_current_win(owner.saved_detail.winid)
        return
    end
    if owner.detail then
        vim.api.nvim_set_current_win(owner.detail.winid)
        return
    end
    if owner.detail_overlay then
        owner.detail_overlay:unmount()
    end
    local width = math.max(1, math.min(72, vim.o.columns - 6))
    local height = math.max(1, math.min(24, vim.o.lines - 6))
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
    require("todo.ui.responsive").popup(overlay, 72, 24)
    markdown.attach(overlay.bufnr)
    render_overlay(overlay)
    local close = function()
        overlay:unmount()
        owner.detail_overlay = nil
        focus_list(owner)
    end
    vim.keymap.set("n", "q", close, { buffer = overlay.bufnr })
    vim.keymap.set("n", "<Esc>", close, { buffer = overlay.bufnr })
    local callbacks = {
        edit = edit_task,
        start = function()
            change_status("in_progress")
        end,
        done = function()
            change_status("done")
        end,
        cancel = function()
            change_status("cancelled")
        end,
        reopen = function()
            change_status("todo")
        end,
        archive = function()
            archive_task(false)
        end,
        restore = function()
            archive_task(true)
        end,
        delete = delete_archived_task,
        postpone = function()
            postpone("detail")
        end,
    }
    local keys = {
        edit = "e",
        start = "s",
        done = "x",
        cancel = "c",
        reopen = "u",
        archive = "A",
        restore = "R",
        delete = "D",
        postpone = "p",
    }
    for id, callback in pairs(callbacks) do
        vim.keymap.set("n", keys[id], dispatch_task("overlay", id, callback), { buffer = overlay.bufnr, silent = true })
    end
    -- The persistent buffer can retain fixed-pane page actions from a prior
    -- layout. The overlay owns only reading, task operations and its close keys.
    for _, key in ipairs({ "a", "n", "/", "f", "[", "]", "v", "g", "r", "<Tab>", "za", "zM", "zR", "<CR>" }) do
        pcall(vim.keymap.del, "n", key, { buffer = overlay.bufnr })
    end
    vim.keymap.set("n", "h", "h", { buffer = overlay.bufnr, silent = true })
    require("todo.ui.history").attach(overlay.bufnr)
    hints.attach(overlay.bufnr, function()
        return panel_context("overlay")
    end, { owner = owner })
    for key, action in pairs({ P = "plan", Q = "clarify", t = "toggle_today", N = "note" }) do
        vim.keymap.set("n", key, function()
            planner_action(action)
        end, { buffer = overlay.bufnr, silent = true })
    end
    contextual_keys(overlay.bufnr, "overlay")
    map_today_range(overlay.bufnr, "overlay", { buffer = overlay.bufnr, silent = true, desc = "Mark today range" })
    set_detail_navigation(overlay.bufnr)
    guard_navigation(overlay.bufnr)
    vim.keymap.set("n", "+", function()
        require("todo.ui.responsive").toggle_maximize(overlay, 72, 24)
    end, { buffer = overlay.bufnr, silent = true, nowait = true })
end

local function set_mappings(component, role)
    local buf = component.bufnr
    guard_navigation(buf)
    vim.keymap.set("n", "+", function()
        toggle_maximize(component)
    end, { buffer = buf, nowait = true, silent = true })
    local opts = function(desc)
        return { buffer = buf, silent = true, desc = desc }
    end
    for key, action in pairs({ P = "plan", Q = "clarify", t = "toggle_today", N = "note" }) do
        vim.keymap.set("n", key, function()
            planner_action(action, role)
        end, opts("Planning: " .. action))
    end
    for key, action in pairs({ L = "lock", J = "down", K = "up", m = "item", C = "capacity", b = "date" }) do
        vim.keymap.set("n", key, function()
            if is_today() then
                planner_action(action, role)
            end
        end, opts("Today: " .. action))
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
    if role == "list" or role == "sidebar" then
        vim.keymap.set("n", "gg", function()
            select_row(1)
        end, opts("First task or section"))
        vim.keymap.set("n", "G", function()
            select_row(#state.rows)
        end, opts("Last task or section"))
        vim.keymap.set("n", "<C-u>", function()
            select_half_page(-1)
        end, opts("Move selection half a page up"))
        vim.keymap.set("n", "<C-d>", function()
            select_half_page(1)
        end, opts("Move selection half a page down"))
    elseif role == "detail" then
        set_detail_navigation(buf)
    end
    if role == "list" or role == "sidebar" then
        vim.keymap.set("n", "p", function()
            postpone("list")
        end, opts("Postpone task"))
    elseif role == "detail" then
        vim.keymap.set("n", "p", function()
            postpone("detail")
        end, opts("Postpone task"))
    end
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
    vim.keymap.set("n", "<C-p>", show_help, opts("Dashboard help"))
    vim.keymap.set("n", "g", function()
        require("todo").tags()
    end, opts("Manage tags"))
    vim.keymap.set("n", "[", function()
        cycle_view(-1)
    end, opts("Previous view"))
    vim.keymap.set("n", "]", function()
        cycle_view(1)
    end, opts("Next view"))
    vim.keymap.set("n", "o", function()
        if grouping.supports_group(state.scope) then
            cycle_group(1)
        end
    end, opts("Change grouping"))
    vim.keymap.set("n", "v", function()
        local items = {}
        for _, scope in ipairs(grouping.scopes) do
            items[#items + 1] = {
                label = (scope == state.scope and "● " or "  ") .. scope_label(scope),
                value = { scope = scope },
            }
        end
        for _, group in ipairs(grouping.groups) do
            items[#items + 1] = {
                label = (scope == state.scope and group == state.group and "● " or "  ")
                    .. i18n.t("group")
                    .. ": "
                    .. group_label(group),
                value = { group = group },
            }
        end
        menu(state.owner, i18n.t("view"), items, function(value)
            if value.scope then
                change_scope(value.scope)
            elseif value.group then
                change_group(value.group)
            end
        end)
    end, opts("Choose view and grouping"))
    vim.keymap.set("n", "<CR>", function()
        if current_row() and current_row().kind == "section" then
            toggle_fold()
        else
            open_details()
        end
    end, opts("Open details"))
    local callbacks = {
        e = { "edit", edit_task },
        s = {
            "start",
            function()
                change_status("in_progress")
            end,
        },
        x = {
            "done",
            function()
                change_status("done")
            end,
        },
        c = {
            "cancel",
            function()
                change_status("cancelled")
            end,
        },
        u = {
            "reopen",
            function()
                change_status("todo")
            end,
        },
        A = {
            "archive",
            function()
                archive_task(false)
            end,
        },
        R = {
            "restore",
            function()
                archive_task(true)
            end,
        },
        D = { "delete", delete_archived_task },
        p = {
            "postpone",
            function()
                postpone(role == "detail" and "detail" or "list")
            end,
        },
    }
    for key, value in pairs(callbacks) do
        if key ~= "p" or role == "list" or role == "sidebar" or role == "detail" then
            vim.keymap.set("n", key, dispatch_task(role, value[1], value[2]), opts(value[1]))
        end
    end
    contextual_keys(buf, role)
    map_today_range(buf, role, opts("Mark today range"))
    if role == "detail" then
        for _, key in ipairs({ "<Tab>", "za", "zM", "zR" }) do
            pcall(vim.keymap.del, "n", key, { buffer = buf })
        end
    end
    require("todo.ui.history").attach(buf)
    hints.attach(buf, function()
        return panel_context(role)
    end, {
        owner = state.owner,
        on_update = function(ctx)
            local owner = state.owner
            if owner and owner.footer and owner.footer.winid and vim.api.nvim_win_is_valid(owner.footer.winid) then
                set_buffer(
                    owner.footer.bufnr,
                    hints.compact(ctx.actions, vim.api.nvim_win_get_width(owner.footer.winid))
                )
                hints.highlight(owner.footer.bufnr)
            end
        end,
    })
    if role == "list" and state.owner then
        vim.keymap.set("n", "l", function()
            if state.owner.maximized then
                open_details()
            elseif state.owner.detail then
                vim.api.nvim_set_current_win(state.owner.detail.winid)
            else
                open_details()
            end
        end, opts("Focus details"))
    elseif role == "detail" then
        vim.keymap.set("n", "h", function()
            if state.owner.maximized then
                state.owner.maximized = state.owner.list
                state.owner.reflow()
            end
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
    local responsive = require("todo.ui.responsive")
    owner.header = base_popup(nil, { border = false })
    owner.list = base_popup(scope_label(), { enter = true })
    owner.footer = base_popup(nil, { border = false })
    owner.saved_detail = base_popup(
        i18n.t("details"),
        { enter = false, wrap = true, markdown = true, bufnr = persistent_detail_bufnr() }
    )
    local function geometry()
        local size = responsive.size(math.floor(vim.o.columns * cfg.width), math.floor((vim.o.lines - 2) * cfg.height))
        owner.wide = size.width >= 100
        owner.detail = owner.wide and owner.saved_detail or nil
        local body = owner.detail
                and Layout.Box(
                    { Layout.Box(owner.list, { size = "58%" }), Layout.Box(owner.detail, { size = "42%" }) },
                    { dir = "row", grow = 1 }
                )
            or Layout.Box(owner.list, { grow = 1 })
        local boxes = { body }
        if size.height >= 10 then
            local header = select(1, header_content(false, size.width))
            table.insert(boxes, 1, Layout.Box(owner.header, { size = math.min(4, math.max(2, #header)) }))
            boxes[#boxes + 1] = Layout.Box(owner.footer, { size = 3 })
        end
        return { relative = "editor", position = "50%", size = size }, Layout.Box(boxes, { dir = "col" })
    end
    local placement, box = geometry()
    owner.layout = Layout(placement, box)
    owner.layout:mount()
    owner.reflow = function()
        local focused = owner_has_window(owner, vim.api.nvim_get_current_win())
        local views = {}
        for _, pop in ipairs({ owner.list, owner.saved_detail }) do
            if pop.winid and vim.api.nvim_win_is_valid(pop.winid) then
                views[pop.bufnr] = vim.api.nvim_win_call(pop.winid, vim.fn.winsaveview)
            end
        end
        local next_placement, next_box = geometry()
        owner.layout:update(next_placement, next_box)
        if owner.maximized then
            owner.maximized:show()
            owner.maximized:update_layout({
                relative = "editor",
                position = "50%",
                size = responsive.size(vim.o.columns, vim.o.lines),
                zindex = 65,
            })
            if focused then
                vim.api.nvim_set_current_win(owner.maximized.winid)
            end
        end
        render()
        for _, pop in ipairs({ owner.list, owner.saved_detail }) do
            if pop.winid and vim.api.nvim_win_is_valid(pop.winid) and views[pop.bufnr] then
                vim.api.nvim_win_call(pop.winid, function()
                    vim.fn.winrestview(views[pop.bufnr])
                end)
            end
        end
    end
    set_mappings(owner.header, "header")
    set_mappings(owner.list, "list")
    set_mappings(owner.footer, "footer")
    set_mappings(owner.saved_detail, "detail")
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
    owner.reflow = function()
        if owner.max_overlay then
            owner.max_overlay:update_layout({
                relative = "editor",
                position = "50%",
                size = require("todo.ui.responsive").size(vim.o.columns, vim.o.lines),
            })
        end
        render()
    end
end

function M.open(opts)
    opts = opts or {}
    if owner_valid() then
        M.close()
    end
    highlights.setup()
    local previous_view = state.view
    state.mode = opts.mode or config.get().ui.default_mode
    local requested_view = opts.view or config.get().ui.default_view
    state.scope = grouping.scope_of(requested_view)
    state.group = grouping.group_of(requested_view)
    state.view = grouping.compose(state.scope, state.group)
    state.filters = opts.filters or state.filters or {}
    local normalized_date = opts.planning_date
    local explicit_date = type(normalized_date) == "string"
        and require("todo.model").parse_deadline(normalized_date) ~= nil
    state.planning_date, state.planning_date_explicit = nil, explicit_date
    pcall(function()
        local svc = service()
        if not svc.store.db then
            return
        end
        local ws = require("todo.workspace").new(svc.store)
        if not explicit_date then
            normalized_date = require("todo.planning").new(ws, svc):date()
        end
        ws.store:set_setting("planning_view_date", normalized_date)
        state.planning_date = normalized_date
    end)
    if opts.selected_id == nil and opts.view and previous_view and state.view ~= previous_view then
        state.selected_id = nil
    end
    state.selected_id = opts.selected_id or state.selected_id
    -- Header height depends on the tab counts, so read stats before laying out.
    local ok, stats = pcall(function()
        return service():stats()
    end)
    state.stats = ok and stats or state.stats
    local owner = { closed = false, transient = nil, mode = state.mode }
    if service().store.workspace then
        owner.snapshot = require("todo.ui.snapshot").new(service())
    end
    state.owner = owner
    if state.mode == "sidebar" then
        create_sidebar(owner)
    else
        create_float(owner)
    end
    render()
    owner.close = M.close
    owner.resize_group = vim.api.nvim_create_augroup("TodoDashboardResize", { clear = true })
    require("todo.ui.responsive").watch(owner, function()
        if state.owner == owner and owner.reflow then
            owner.reflow()
        end
    end)
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
    if owner.reflow_group then
        pcall(vim.api.nvim_del_augroup_by_id, owner.reflow_group)
    end
    hints.close(owner)
    close_transient(owner)
    if owner.max_overlay then
        owner.max_overlay:unmount()
    end
    if owner.detail_overlay then
        pcall(function()
            owner.detail_overlay:unmount()
        end)
    end
    if owner.saved_detail then
        pcall(owner.saved_detail.unmount, owner.saved_detail)
    end
    if owner.header then
        pcall(owner.header.unmount, owner.header)
    end
    if owner.footer then
        pcall(owner.footer.unmount, owner.footer)
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
        if state.owner.snapshot then
            state.owner.snapshot:invalidate()
        end
        render()
        refresh_overlay(state.owner)
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
            { mode = state.mode, view = state.scope, filters = vim.deepcopy(state.filters), selected_id = task.id }
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
