-- Versioned, deterministic wire format. Never serialize local row IDs or bell state.
local M = {}

function M.uuid()
    local bytes = assert((vim.uv or vim.loop).random(16))
    local hex = bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end)
    local variant = string.format("%x", 8 + tonumber(hex:sub(17, 17), 16) % 4)
    return hex:sub(1, 8)
        .. "-"
        .. hex:sub(9, 12)
        .. "-4"
        .. hex:sub(14, 16)
        .. "-"
        .. variant
        .. hex:sub(18, 20)
        .. "-"
        .. hex:sub(21)
end

function M.encode(value)
    if type(value) ~= "table" then
        return vim.json.encode(value)
    end
    local parts = {}
    if vim.islist(value) then
        for _, item in ipairs(value) do
            parts[#parts + 1] = M.encode(item)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = vim.tbl_keys(value)
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = vim.json.encode(key) .. ":" .. M.encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function M.snapshot(task)
    local result = {}
    for _, key in ipairs({
        "kind",
        "title",
        "description",
        "status",
        "priority",
        "due_date",
        "due_time",
        "created_at",
        "updated_at",
        "completed_at",
        "archived_at",
        "tags",
    }) do
        result[key] = vim.deepcopy(task[key])
    end
    if task.reminder then
        result.reminder = vim.deepcopy(task.reminder)
        result.reminder.next_reminder_at = nil
        result.reminder.last_reminded_at = nil
    end
    return result
end

local function integer(value, minimum)
    return type(value) == "number"
        and value == value
        and value >= minimum
        and value <= 9007199254740991
        and value % 1 == 0
end

local function uuid(value)
    return type(value) == "string"
        and #value == 36
        and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function name(value)
    return type(value) == "string" and value ~= "" and value == vim.trim(value) and not value:find("%z")
end

local function fields(value, allowed)
    assert(type(value) == "table", "expected object")
    for key in pairs(value) do
        assert(allowed[key], "unknown field: " .. tostring(key))
    end
end

local function allowed(names)
    local result = {}
    for word in names:gmatch("%S+") do
        result[word] = true
    end
    return result
end

-- Validate calendar text without the receiver's timezone/DST conversion.
local function deadline(task)
    if task.due_date == nil then
        return task.due_time == nil
    end
    if type(task.due_date) ~= "string" then
        return false
    end
    local y, m, d = task.due_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or m < 1 or m > 12 then
        return false
    end
    local leap = y % 400 == 0 or (y % 4 == 0 and y % 100 ~= 0)
    local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if d < 1 or d > days[m] then
        return false
    end
    if task.due_time == nil then
        return true
    end
    if type(task.due_time) ~= "string" then
        return false
    end
    local hour, minute = task.due_time:match("^(%d%d):(%d%d)$")
    return hour ~= nil and tonumber(hour) < 24 and tonumber(minute) < 60
end

function M.validate(event)
    fields(event, allowed("version id device time sequence changes"))
    assert(event.version == 1, "unsupported sync format")
    assert(uuid(event.id) and uuid(event.device), "invalid sync identity")
    assert(integer(event.time, 0) and integer(event.sequence, 0), "invalid sync clock")
    assert(
        type(event.changes) == "table" and vim.islist(event.changes) and #event.changes > 0,
        "empty or invalid changes"
    )
    local seen = {}
    for _, change in ipairs(event.changes) do
        fields(change, allowed("kind key value deleted"))
        assert(change.kind == "task" or change.kind == "tag", "invalid entity kind")
        assert(type(change.key) == "string", "invalid entity key")
        assert(not seen[change.kind .. change.key], "duplicate entity in transaction")
        seen[change.kind .. change.key] = true
        assert(
            (change.deleted == true and change.value == nil)
                or (change.deleted == nil and type(change.value) == "table"),
            "invalid deletion"
        )
        if change.kind == "tag" then
            assert(name(change.key) and change.key == change.key:lower(), "invalid tag key")
            if change.value then
                fields(change.value, allowed("name"))
                assert(name(change.value.name) and change.value.name:lower() == change.key, "invalid tag")
            end
        else
            assert(uuid(change.key), "invalid task UUID")
            local t = change.value
            if t then
                fields(
                    t,
                    allowed(
                        "kind title description status priority due_date due_time created_at updated_at completed_at archived_at tags reminder"
                    )
                )
                assert(t.kind == "task" or t.kind == "notice", "invalid task kind")
                assert(type(t.title) == "string" and vim.trim(t.title) ~= "", "invalid title")
                assert(type(t.description) == "string", "invalid description")
                assert(require("todo.model").statuses[t.status], "invalid task status")
                assert(integer(t.priority, 0) and t.priority <= 3, "invalid priority")
                for _, key in ipairs({ "created_at", "updated_at" }) do
                    assert(integer(t[key], 0), "invalid timestamp: " .. key)
                end
                for _, key in ipairs({ "completed_at", "archived_at" }) do
                    assert(t[key] == nil or integer(t[key], 0), "invalid timestamp: " .. key)
                end
                assert(deadline(t), "invalid deadline")
                assert(type(t.tags) == "table" and vim.islist(t.tags), "invalid tags")
                local tags = {}
                for _, tag in ipairs(t.tags) do
                    assert(name(tag) and not tags[tag:lower()], "invalid or duplicate tag")
                    tags[tag:lower()] = true
                end
                local r = t.reminder
                assert(r == nil or type(r) == "table", "invalid reminder")
                if r then
                    fields(
                        r,
                        allowed(
                            "enabled recurrence repeat_interval_seconds scheduled_at snoozed_until occurrence_started_at"
                        )
                    )
                    assert(type(r.enabled) == "boolean", "invalid reminder enabled")
                    assert(integer(r.repeat_interval_seconds, 1), "invalid reminder interval")
                    assert(
                        integer(r.scheduled_at, 0) and integer(r.occurrence_started_at, 0),
                        "invalid reminder schedule"
                    )
                    assert(r.snoozed_until == nil or integer(r.snoozed_until, 0), "invalid snooze")
                    fields(r.recurrence, allowed("kind every unit weekdays"))
                    local rule = require("todo.recurrence").normalize(r.recurrence)
                    assert(rule and vim.deep_equal(rule, r.recurrence), "invalid recurrence")
                end
                assert(t.kind ~= "notice" or r, "notice requires reminder")
            end
        end
    end
    return event
end

function M.decode(payload)
    return M.validate(vim.json.decode(payload, { luanil = { object = true, array = true } }))
end

function M.newer(a, b)
    if not b then
        return true
    end
    for _, key in ipairs({ "time", "sequence", "device", "id" }) do
        if a[key] ~= b[key] then
            return a[key] > b[key]
        end
    end
    return false
end

return M
