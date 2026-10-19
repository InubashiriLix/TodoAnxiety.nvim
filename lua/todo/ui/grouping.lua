local i18n = require("todo.i18n")
local urgency = require("todo.urgency")

local M = {}

M.views = { "active", "today", "emergency", "by_urgency", "by_time", "by_tag", "notices", "archived" }

-- Views regroup the active task set instead of defining their own scope.
M.regrouped = { by_urgency = true, by_time = true, by_tag = true }

-- Primary scopes are the only views shown as tabs. Grouping is a separate,
-- orthogonal choice so the tab bar does not grow with every way to sort tasks.
M.scopes = { "active", "today", "emergency", "notices", "archived" }
M.groups = { "status", "urgency", "time", "tag" }
local group_views = { urgency = "by_urgency", time = "by_time", tag = "by_tag" }

function M.scope_of(view)
    if M.regrouped[view] then
        return "active"
    end
    return view
end

function M.group_of(view)
    if view == "by_urgency" then
        return "urgency"
    elseif view == "by_time" then
        return "time"
    elseif view == "by_tag" then
        return "tag"
    end
    return "status"
end

function M.compose(scope, group)
    if scope == "active" and group_views[group] then
        return group_views[group]
    end
    return scope
end

function M.supports_group(scope)
    return scope == "active" or scope == "today" or scope == "emergency"
end

function M.group_view(scope, group)
    if M.supports_group(scope) and group_views[group] then
        return group_views[group]
    end
    return scope
end

-- Only the four scope tabs carry a count badge; the regrouped tabs show the
-- same population as "active" so repeating the number wastes header width.
M.counted = { active = true, emergency = true, notices = true, archived = true }

function M.is_view(view)
    for _, candidate in ipairs(M.views) do
        if candidate == view then
            return true
        end
    end
    return false
end

--- Compact "top two units" relative label, e.g. "3d 4h" or "overdue 2d".
function M.relative(epoch, now)
    if not epoch then
        return nil
    end
    now = now or os.time()
    local remaining = epoch - now
    local overdue = remaining < 0
    remaining = math.abs(remaining)
    local parts = {}
    for _, unit in ipairs({ { "d", 86400 }, { "h", 3600 }, { "m", 60 } }) do
        local amount = math.floor(remaining / unit[2])
        if amount > 0 and #parts < 2 then
            parts[#parts + 1] = amount .. unit[1]
            remaining = remaining % unit[2]
        end
    end
    if #parts == 0 then
        parts[1] = "<1m"
    end
    local text = table.concat(parts, " ")
    return overdue and (i18n.t("relative_overdue") .. " " .. text) or (i18n.t("relative_in") .. " " .. text)
end

local function due_epoch(task, now)
    local info = task.urgency or urgency.calculate(task, now)
    task.urgency = info
    return info.due_epoch
end

local function bucket_status(tasks)
    local order = { "in_progress", "todo", "done", "cancelled" }
    local buckets = {}
    for _, status in ipairs(order) do
        buckets[status] = {}
    end
    for _, task in ipairs(tasks) do
        local bucket = buckets[task.status]
        if bucket then
            bucket[#bucket + 1] = task
        end
    end
    local sections = {}
    for _, status in ipairs(order) do
        if #buckets[status] > 0 then
            sections[#sections + 1] = { key = status, label = i18n.t(status), tasks = buckets[status] }
        end
    end
    return sections
end

-- These are exactly the levels urgency.calculate can return; "priority_only"
-- is its label for a task with no deadline.
local function bucket_urgency(tasks, now)
    local order = { "overdue", "urgent", "high", "attention", "priority_only" }
    local buckets = {}
    for _, level in ipairs(order) do
        buckets[level] = {}
    end
    for _, task in ipairs(tasks) do
        local info = task.urgency or urgency.calculate(task, now)
        task.urgency = info
        local bucket = buckets[info.level]
        bucket[#bucket + 1] = task
    end
    local sections = {}
    for _, level in ipairs(order) do
        if #buckets[level] > 0 then
            sections[#sections + 1] = { key = level, label = i18n.t(level), tasks = buckets[level] }
        end
    end
    return sections
end

local function bucket_time(tasks, now)
    now = now or os.time()
    local order = { "overdue", "today", "this_week", "later", "no_deadline" }
    local labels = {
        overdue = "due_overdue",
        today = "due_today_group",
        this_week = "due_this_week",
        later = "due_later_group",
        no_deadline = "no_deadline_group",
    }
    local buckets = {}
    for _, key in ipairs(order) do
        buckets[key] = {}
    end
    for _, task in ipairs(tasks) do
        local epoch = due_epoch(task, now)
        local key
        if not epoch then
            key = "no_deadline"
        elseif epoch < now then
            key = "overdue"
        elseif epoch - now <= 86400 then
            key = "today"
        elseif epoch - now <= 7 * 86400 then
            key = "this_week"
        else
            key = "later"
        end
        local bucket = buckets[key]
        bucket[#bucket + 1] = task
    end
    local sections = {}
    for _, key in ipairs(order) do
        if #buckets[key] > 0 then
            sections[#sections + 1] = { key = key, label = i18n.t(labels[key]), tasks = buckets[key] }
        end
    end
    return sections
end

local function bucket_tags(tasks)
    local buckets, names, untagged = {}, {}, {}
    for _, task in ipairs(tasks) do
        local tags = task.tags or {}
        if #tags == 0 then
            untagged[#untagged + 1] = task
        end
        for _, tag in ipairs(tags) do
            if not buckets[tag] then
                buckets[tag] = {}
                names[#names + 1] = tag
            end
            local bucket = buckets[tag]
            bucket[#bucket + 1] = task
        end
    end
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    local sections = {}
    for _, name in ipairs(names) do
        sections[#sections + 1] = {
            key = "tag:" .. name,
            label = "#" .. name,
            tag = name,
            tasks = buckets[name],
            depth = 1,
        }
    end
    if #untagged > 0 then
        sections[#sections + 1] = { key = "untagged", label = i18n.t("untagged"), tasks = untagged, depth = 1 }
    end
    return sections
end

--- Build the section list for a view. Tasks arrive pre-sorted by service:list.
function M.sections(tasks, view, now)
    if view == "today" then
        local result = {}
        for _, g in ipairs({
            { "now", "Now", "现在做" },
            { "next", "Next", "接下来" },
            { "optional", "If time permits", "有余力再做" },
            { "review", "Review previous days", "往日待复核" },
        }) do
            local bucket = {}
            for _, t in ipairs(tasks) do
                if (t.planning or {}).group == g[1] then
                    bucket[#bucket + 1] = t
                end
            end
            if #bucket > 0 then
                result[#result + 1] = {
                    key = g[1],
                    label = require("todo.config").get().language == "zh-CN" and g[3] or g[2],
                    tasks = bucket,
                }
            end
        end
        return result
    elseif view == "active" then
        return bucket_status(tasks)
    elseif view == "by_urgency" then
        return bucket_urgency(tasks, now)
    elseif view == "by_time" then
        return bucket_time(tasks, now)
    elseif view == "by_tag" then
        return bucket_tags(tasks)
    end
    return { { key = view, label = i18n.t(view), tasks = tasks } }
end

--- Flatten sections into the render/cursor model. `collapsed` is keyed by
--- section key; collapsed sections contribute their header but no task rows.
function M.rows(sections, collapsed)
    collapsed = collapsed or {}
    local rows = {}
    for _, section in ipairs(sections) do
        local folded = collapsed[section.key] == true
        rows[#rows + 1] = {
            kind = "section",
            key = section.key,
            label = section.label,
            tag = section.tag,
            count = #section.tasks,
            collapsed = folded,
            depth = section.depth or 0,
        }
        if not folded then
            for _, task in ipairs(section.tasks) do
                rows[#rows + 1] = {
                    kind = "task",
                    task = task,
                    section_key = section.key,
                    depth = section.depth or 0,
                }
            end
        end
    end
    return rows
end

return M
