local codec = require("todo.sync.codec")
local M = {}
local materialize

local function rows(db, sql, args)
    local value = db:eval(sql, args)
    return type(value) == "table" and value or {}
end

function M.migrate(db)
    db:execute("ALTER TABLE tasks ADD COLUMN sync_uuid TEXT")
    db:execute("ALTER TABLE tasks ADD COLUMN sync_revision TEXT")
    db:execute("CREATE UNIQUE INDEX idx_tasks_sync_uuid ON tasks(sync_uuid)")
    db:execute([[CREATE TABLE sync_events (
        id TEXT PRIMARY KEY, payload TEXT NOT NULL, published INTEGER NOT NULL DEFAULT 0
    )]])
    db:execute([[CREATE TABLE sync_heads (
        kind TEXT NOT NULL, key TEXT NOT NULL, event_id TEXT NOT NULL REFERENCES sync_events(id),
        payload TEXT NOT NULL, PRIMARY KEY(kind, key)
    )]])
    db:execute([[CREATE TABLE sync_lock (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1), pid INTEGER NOT NULL, token TEXT NOT NULL
    )]])
    db:execute([[CREATE TABLE sync_tag_resets (
        key TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES sync_events(id)
    )]])
end

local function identities(store)
    for _, row in ipairs(rows(store.db, "SELECT id FROM tasks WHERE sync_uuid IS NULL")) do
        store.db:eval("UPDATE tasks SET sync_uuid = :uuid WHERE id = :id", { uuid = codec.uuid(), id = row.id })
    end
end

local function snapshot(store)
    local result = { task = {}, tag = {} }
    for _, archived in ipairs({ false, true }) do
        for _, task in ipairs(store:list({ archived = archived })) do
            result.task[task.sync_uuid] = codec.snapshot(task)
        end
    end
    for _, tag in ipairs(store:list_tags()) do
        result.tag[tag:lower()] = { name = tag }
    end
    return result
end

local function changes(before, after)
    local result = {}
    for _, kind in ipairs({ "task", "tag" }) do
        local keys = vim.tbl_extend("force", before[kind], after[kind])
        for _, key in ipairs(vim.fn.sort(vim.tbl_keys(keys))) do
            if not vim.deep_equal(before[kind][key], after[kind][key]) then
                result[#result + 1] = {
                    kind = kind,
                    key = key,
                    value = after[kind][key],
                    deleted = after[kind][key] == nil and true or nil,
                }
            end
        end
    end
    return result
end

local function observe(store, event)
    local time = tonumber(store:get_setting("sync_clock_time")) or 0
    local sequence = tonumber(store:get_setting("sync_clock_sequence")) or 0
    if event.time > time or (event.time == time and event.sequence > sequence) then
        store:set_setting("sync_clock_time", event.time)
        store:set_setting("sync_clock_sequence", event.sequence)
    end
end

local function record(store, event, published)
    local payload = codec.encode(event)
    local previous = rows(store.db, "SELECT payload FROM sync_events WHERE id = :id", { id = event.id })[1]
    if previous then
        assert(previous.payload == payload, "sync record ID has different content: " .. event.id)
        return false
    end
    store.db:eval("INSERT INTO sync_events(id, payload, published) VALUES(:id, :payload, :published)", {
        id = event.id,
        payload = payload,
        published = published and 1 or 0,
    })
    observe(store, event)
    for _, change in ipairs(event.changes) do
        if change.kind == "tag" and change.deleted then
            local reset = rows(
                store.db,
                [[SELECT sync_events.payload FROM sync_tag_resets
                JOIN sync_events ON sync_events.id = sync_tag_resets.event_id WHERE key = :key]],
                { key = change.key }
            )[1]
            if codec.newer(event, reset and vim.json.decode(reset.payload)) then
                store.db:eval(
                    [[INSERT INTO sync_tag_resets(key, event_id) VALUES(:key, :id)
                    ON CONFLICT(key) DO UPDATE SET event_id = excluded.event_id]],
                    { key = change.key, id = event.id }
                )
            end
        end
        local head = rows(
            store.db,
            [[SELECT sync_events.payload FROM sync_heads
            JOIN sync_events ON sync_events.id = sync_heads.event_id
            WHERE kind = :kind AND key = :key]],
            { kind = change.kind, key = change.key }
        )[1]
        if codec.newer(event, head and vim.json.decode(head.payload)) then
            store.db:eval(
                [[INSERT INTO sync_heads(kind, key, event_id, payload)
                VALUES(:kind, :key, :event_id, :payload) ON CONFLICT(kind, key) DO UPDATE SET
                event_id = excluded.event_id, payload = excluded.payload]],
                {
                    kind = change.kind,
                    key = change.key,
                    event_id = event.id,
                    payload = codec.encode(change),
                }
            )
            if change.kind == "task" then
                store.db:eval(
                    "UPDATE tasks SET sync_revision = :revision WHERE sync_uuid = :uuid",
                    { revision = event.id, uuid = change.key }
                )
            end
        end
    end
    return true
end

local function append(store, delta)
    if #delta == 0 then
        return
    end
    local sec, usec = (vim.uv or vim.loop).gettimeofday()
    local time = sec * 1000 + math.floor(usec / 1000)
    local previous = tonumber(store:get_setting("sync_clock_time")) or 0
    local sequence = 0
    if previous >= time then
        time = previous
        sequence = (tonumber(store:get_setting("sync_clock_sequence")) or 0) + 1
    end
    local event = {
        version = 1,
        id = codec.uuid(),
        device = store:get_setting("sync_device"),
        time = time,
        sequence = sequence,
        changes = delta,
    }
    codec.validate(event)
    record(store, event, false)
    materialize(store)
end

function M.initialize(store)
    store:transaction(function()
        if not store:get_setting("sync_device") then
            store:set_setting("sync_device", codec.uuid())
        end
        identities(store)
        if not store:get_setting("sync_initialized") then
            append(store, changes({ task = {}, tag = {} }, snapshot(store)))
            store:set_setting("sync_initialized", "1")
        end
    end)
end

function M.wrap(Store)
    for _, method in ipairs({
        "create",
        "update",
        "set_status",
        "archive",
        "restore",
        "delete_archived",
        "create_tag",
        "rename_tag",
        "delete_tag",
        "snooze",
        "advance_occurrence",
        "set_reminder_enabled",
    }) do
        local original = Store[method]
        Store[method] = function(store, ...)
            local args = { ... }
            local argc = select("#", ...)
            return store:transaction(function()
                if method == "update" and args[3] ~= nil then
                    local current = store:get(args[1])
                    if not current or current.sync_revision ~= args[3] then
                        error(require("todo.i18n").t("sync_stale_form"))
                    end
                end
                local before = snapshot(store)
                local result = original(store, unpack(args, 1, argc))
                identities(store)
                append(store, changes(before, snapshot(store)))
                if type(result) == "table" and result.id then
                    return store:get(result.id)
                end
                return result
            end)
        end
    end
end

function M.events(store)
    return rows(store.db, "SELECT id, payload, published FROM sync_events ORDER BY id")
end

materialize = function(store)
    local tasks, tags, resets = {}, {}, {}
    for _, reset in ipairs(rows(store.db, "SELECT key FROM sync_tag_resets")) do
        resets[reset.key] = true
    end
    for _, head in
        ipairs(rows(
            store.db,
            [[SELECT sync_heads.*, sync_events.payload AS event_payload
        FROM sync_heads JOIN sync_events ON sync_events.id = sync_heads.event_id]]
        ))
    do
        local change = vim.json.decode(head.payload, { luanil = { object = true, array = true } })
        if head.kind == "task" then
            tasks[head.key] =
                { value = change.value, revision = head.event_id, event = vim.json.decode(head.event_payload) }
        else
            tags[head.key] = change.value or false
            if resets[head.key] then
                resets[head.key] = vim.json.decode(head.event_payload)
            end
        end
    end
    -- Tag tombstones are authoritative even when an old task snapshot mentions the name.
    for _, tag in ipairs(store:list_tags()) do
        if tags[tag:lower()] == false then
            store.db:eval("DELETE FROM tags WHERE name = :name COLLATE NOCASE", { name = tag })
        end
    end
    for _, tag in pairs(tags) do
        if tag then
            store.db:eval(
                [[INSERT INTO tags(name) VALUES(:name) ON CONFLICT(name)
                DO UPDATE SET name = excluded.name]],
                { name = tag.name }
            )
        end
    end
    for uuid, head in pairs(tasks) do
        local row = rows(store.db, "SELECT id FROM tasks WHERE sync_uuid = :uuid", { uuid = uuid })[1]
        local old = row and store:get(tonumber(row.id)) or nil
        local task = head.value and vim.deepcopy(head.value)
        if not task then
            store.db:eval("DELETE FROM tasks WHERE sync_uuid = :uuid", { uuid = uuid })
        else
            task.tags = vim.tbl_filter(function(tag)
                local key = tag:lower()
                -- Recreating a deleted name does not resurrect its previous associations.
                return tags[key] ~= false and (not resets[key] or not codec.newer(resets[key], head.event))
            end, task.tags)
            for i, tag in ipairs(task.tags) do
                if tags[tag:lower()] then
                    task.tags[i] = tags[tag:lower()].name
                end
            end
            if not old then
                store.db:eval(
                    [[INSERT INTO tasks(sync_uuid, title, created_at, updated_at)
                    VALUES(:uuid, :title, :created_at, :updated_at)]],
                    {
                        uuid = uuid,
                        title = task.title,
                        created_at = task.created_at,
                        updated_at = task.updated_at,
                    }
                )
                row = rows(store.db, "SELECT id FROM tasks WHERE sync_uuid = :uuid", { uuid = uuid })[1]
            end
            -- Include the visible projection: a tag tombstone can change a task
            -- without replacing its winning task event.
            task.sync_revision = head.revision .. ":" .. vim.fn.sha256(codec.encode(task))
            task.id = tonumber(row.id)
            local params = vim.deepcopy(task)
            params.tags, params.reminder = nil, nil
            store.db:eval(
                [[UPDATE tasks SET kind = :kind, title = :title, description = :description,
                status = :status, priority = :priority, due_date = :due_date, due_time = :due_time,
                created_at = :created_at, updated_at = :updated_at, completed_at = :completed_at,
                archived_at = :archived_at, sync_revision = :sync_revision WHERE id = :id]],
                params
            )
            store:_set_tags(task.id, task.tags)
            if task.reminder then
                local same = old and vim.deep_equal(codec.snapshot(old).reminder, task.reminder)
                if same then
                    task.reminder = old.reminder
                else
                    task.reminder.next_reminder_at = task.reminder.snoozed_until or task.reminder.scheduled_at
                end
            end
            store:_set_reminder(task.id, task.reminder)
        end
    end
end

function M.import(store, payloads)
    -- Validate the entire batch before touching any state.
    local events = {}
    for _, payload in ipairs(payloads) do
        events[#events + 1] = codec.decode(payload)
    end
    return store:transaction(function()
        local count = 0
        for _, event in ipairs(events) do
            if record(store, event, true) then
                count = count + 1
            end
        end
        if count > 0 then
            materialize(store)
        end
        return count
    end)
end

function M.published(store, ids)
    store:transaction(function()
        for _, id in ipairs(ids) do
            store.db:eval("UPDATE sync_events SET published = 1 WHERE id = :id", { id = id })
        end
        store:set_setting("sync_last_success", os.time())
        store:set_setting("sync_last_error", "")
    end)
end

function M.status(store)
    local row = rows(store.db, "SELECT COUNT(*) AS count FROM sync_events WHERE published = 0")[1]
    return {
        pending = tonumber(row.count),
        last_success = tonumber(store:get_setting("sync_last_success")),
        last_error = store:get_setting("sync_last_error"),
    }
end

-- SQLite serializes lock acquisition across all Neovim processes using this database.
function M.lock(store)
    return store:transaction(function()
        local old = rows(store.db, "SELECT * FROM sync_lock")[1]
        if old then
            local alive, err = (vim.uv or vim.loop).kill(tonumber(old.pid), 0)
            assert(not alive and tostring(err):find("ESRCH"), require("todo.i18n").t("sync_busy"))
            store.db:execute("DELETE FROM sync_lock")
        end
        local token = codec.uuid()
        store.db:eval("INSERT INTO sync_lock(singleton, pid, token) VALUES(1, :pid, :token)", {
            pid = vim.fn.getpid(),
            token = token,
        })
        return token
    end)
end

function M.unlock(store, token)
    store.db:eval("DELETE FROM sync_lock WHERE token = :token", { token = token })
end

return M
