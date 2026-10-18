-- Durable local workspace. Cloud versions are separate from local revisions.
local codec = require("todo.sync.codec")
local M = { PROTOCOL_VERSION = 2 }
M.__index = M
local kinds = {
    memory = true,
    task = true,
    tag = true,
    plan = true,
    note = true,
    conversation = true,
    draft = true,
    usage = true,
    profile = true,
    attachment = true,
    routine = true,
    routine_run = true,
}
local function rows(db, sql, args)
    local r = db:eval(sql, args)
    return type(r) == "table" and r or {}
end
local function decode(s)
    local value = s and vim.json.decode(s) or nil
    if value == vim.NIL then
        return nil
    end
    return value
end
local function encode(v)
    return v == nil and "null" or codec.encode(v)
end
function M.migrate(db)
    db:execute(
        [[CREATE TABLE workspace_records(kind TEXT NOT NULL,key TEXT NOT NULL,value TEXT NOT NULL,revision TEXT NOT NULL,dirty INTEGER NOT NULL DEFAULT 1,server_version INTEGER NOT NULL DEFAULT 0,shadow TEXT NOT NULL DEFAULT 'null',PRIMARY KEY(kind,key))]]
    )
    db:execute(
        [[CREATE TABLE workspace_conflicts(kind TEXT NOT NULL,key TEXT NOT NULL,remote TEXT NOT NULL,PRIMARY KEY(kind,key))]]
    )
end
function M.new(store)
    if store.workspace then
        return store.workspace
    end
    local self = setmetatable({ store = store }, M)
    store.workspace = self
    self:observe(true)
    return self
end
function M:get(kind, key)
    require("todo.performance").count("workspace.get")
    local r = rows(
        self.store.db,
        "SELECT value,revision FROM workspace_records WHERE kind=:kind AND key=:key",
        { kind = kind, key = key }
    )[1]
    if r then
        return decode(r.value), r.revision
    end
end
function M:list(kind)
    require("todo.performance").count("workspace.list")
    local result = {}
    for _, r in
        ipairs(
            rows(
                self.store.db,
                "SELECT key,value,revision FROM workspace_records WHERE kind=:kind AND value!='null' ORDER BY key",
                { kind = kind }
            )
        )
    do
        result[#result + 1] = { key = r.key, value = decode(r.value), revision = r.revision }
    end
    return result
end
function M:_write(kind, key, value, revision)
    assert(kinds[kind] and type(key) == "string" and #key > 0 and #key <= 256, "invalid workspace identity")
    local old, rev = self:get(kind, key)
    if vim.deep_equal(old, value) then
        return rev
    end
    local newrev = revision or codec.uuid()
    self.store.db:eval(
        [[INSERT INTO workspace_records(kind,key,value,revision,dirty) VALUES(:kind,:key,:value,:revision,1)
        ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value,revision=excluded.revision,dirty=1]],
        { kind = kind, key = key, value = encode(value), revision = newrev }
    )
    self.store:set_setting("cloud_group:" .. kind .. ":" .. key, self.group_id or codec.uuid())
    return newrev
end
function M:notify(origin, changes)
    -- Advance synchronously: a UI callback can run before the scheduled User
    -- event. Presentation caches must already see committed writes then.
    self.generation = (self.generation or 0) + 1
    self.generations = self.generations or {}
    if changes then
        for _, c in ipairs(changes) do
            self.generations[c.kind] = self.generation
        end
    else
        self.reset_generation = self.generation
    end
    vim.schedule(function()
        pcall(
            vim.api.nvim_exec_autocmds,
            "User",
            { pattern = "TodoWorkspaceChanged", modeline = false, data = { origin = origin, changes = changes } }
        )
    end)
end
function M:batch(changes, origin)
    local previous = self.group_id
    self.group_id = previous or codec.uuid()
    local ok, result = pcall(self.store.transaction, self.store, function()
        for _, c in ipairs(changes) do
            local _, revision = self:get(c.kind, c.key)
            assert(
                c.expected_revision == nil or c.expected_revision == revision,
                "workspace conflict: " .. c.kind .. "/" .. c.key
            )
            assert(c.kind ~= "task" and c.kind ~= "tag", "task mutations must use task service")
        end
        local versions = {}
        for _, c in ipairs(changes) do
            versions[#versions + 1] = self:_write(c.kind, c.key, c.value)
        end
        return versions
    end)
    self.group_id = previous
    if not ok then
        error(result, 0)
    end
    local identities = {}
    for _, c in ipairs(changes) do
        identities[#identities + 1] = { kind = c.kind, key = c.key }
    end
    self:notify(origin, identities)
    return result
end
function M:put(kind, key, value, expected)
    local internal = kind == "conversation" and value and value.scope and value.scope:match("^daily_")
        or value and value.workflow_id
    return self:batch(
        { { kind = kind, key = key, value = value, expected_revision = expected } },
        internal and "ai_checkpoint" or nil
    )[1]
end
function M:observe(seed)
    if self.importing then
        return
    end
    local previous = self.group_id
    self.group_id = previous or (not seed and codec.uuid() or nil)
    local live = { task = {}, tag = {} }
    for _, archived in ipairs({ false, true }) do
        for _, t in ipairs(self.store:list({ archived = archived })) do
            live.task[t.sync_uuid] = { value = codec.snapshot(t), revision = t.sync_revision }
        end
    end
    for _, t in ipairs(self.store:list_tags()) do
        live.tag[t:lower()] = { value = { name = t } }
    end
    self.store:transaction(function()
        for _, kind in ipairs({ "task", "tag" }) do
            for _, r in ipairs(self:list(kind)) do
                if not live[kind][r.key] then
                    self:_write(kind, r.key, nil)
                end
            end
            for key, r in pairs(live[kind]) do
                self:_write(kind, key, r.value, r.revision)
            end
        end
    end)
    self.group_id = previous
    self:notify()
end
function M:export_pending()
    local old = self.store:get_setting("cloud_flight")
    if old and old ~= "" then
        return decode(old)
    end
    local changes, groups, order = {}, {}, {}
    for _, r in ipairs(rows(self.store.db, "SELECT * FROM workspace_records WHERE dirty=1 ORDER BY kind,key")) do
        if r.value ~= r.shadow then
            local refs = {}
            local ok, a = pcall(require, "todo.assets")
            if ok then
                refs = a.refs(r.value)
            end
            local group = self.store:get_setting("cloud_group:" .. r.kind .. ":" .. r.key) or r.kind .. "/" .. r.key
            if not groups[group] then
                groups[group] = {}
                order[#order + 1] = group
            end
            groups[group][#groups[group] + 1] = {
                kind = r.kind,
                key = r.key,
                base_version = tonumber(r.server_version),
                value = decode(r.value) or vim.NIL,
                attachments = refs,
            }
        else
            self.store.db:eval(
                "UPDATE workspace_records SET dirty=0 WHERE kind=:kind AND key=:key",
                { kind = r.kind, key = r.key }
            )
        end
    end
    local bytes = 0
    for _, id in ipairs(order) do
        local group = groups[id]
        local size = #codec.encode(group)
        assert(size <= 3000000 and #group <= 1000, "Sync transaction exceeds 3MB or 1000 changes; reduce the batch")
        if #changes + #group > 1000 or bytes + size > 3000000 then
            break
        end
        bytes = bytes + size
        vim.list_extend(changes, group)
    end
    if #changes == 0 then
        return nil
    end
    local op = { version = 2, operation_id = codec.uuid(), changes = changes }
    self.store:set_setting("cloud_flight", codec.encode(op))
    return op
end
-- Called only after a full pull: committed old IDs have already been acknowledged.
function M:upgrade_flight()
    local raw = self.store:get_setting("cloud_flight")
    local old = raw and raw ~= "" and decode(raw)
    if old and old.version ~= M.PROTOCOL_VERSION then
        assert(old.version == 1, "Unsupported pending sync protocol")
        old.version = M.PROTOCOL_VERSION
        old.operation_id = codec.uuid()
        self.store:set_setting("cloud_flight", codec.encode(old))
    end
end
function M:ack(op, response)
    assert(
        type(response) == "table" and response.version == 2 and type(response.changes) == "table",
        "invalid cloud acknowledgement"
    )
    self.store:transaction(function()
        local bykey = {}
        for _, c in ipairs(response.changes) do
            bykey[c.kind .. "/" .. c.key] = c
        end
        for _, c in ipairs(op.changes) do
            local r = assert(bykey[c.kind .. "/" .. c.key], "incomplete cloud acknowledgement")
            assert(type(r.version) == "number" and r.version > c.base_version, "invalid cloud revision")
            self.store.db:eval(
                [[UPDATE workspace_records SET server_version=:version,shadow=:shadow,
                dirty=CASE WHEN value=:shadow THEN 0 ELSE 1 END WHERE kind=:kind AND key=:key]],
                {
                    kind = c.kind,
                    key = c.key,
                    version = r.version,
                    shadow = encode(c.value == vim.NIL and nil or c.value),
                }
            )
        end
        self.store:set_setting("cloud_flight", "")
        self.store:set_setting("cloud_last_success", os.time())
    end)
end
function M:set_cursor(n)
    self.store:set_setting("cloud_cursor", n)
end
function M:cloud_status()
    local r = rows(self.store.db, "SELECT COUNT(*) AS n FROM workspace_records WHERE dirty=1")[1]
    return {
        cursor = tonumber(self.store:get_setting("cloud_cursor")) or 0,
        pending = tonumber(r.n),
        last_success = tonumber(self.store:get_setting("cloud_last_success")),
        conflicts = rows(self.store.db, "SELECT kind,key,remote FROM workspace_conflicts"),
    }
end
local function apply_records(self, changes)
    local taskchanges = {}
    for _, c in ipairs(changes) do
        if c.kind == "task" or c.kind == "tag" then
            taskchanges[#taskchanges + 1] =
                { kind = c.kind, key = c.key, value = c.value, deleted = c.value == nil or nil }
        end
    end
    if #taskchanges > 0 then
        local now = math.floor(select(1, (vim.uv or vim.loop).gettimeofday()) * 1000)
        now = math.max(now, (tonumber(self.store:get_setting("sync_clock_time")) or 0) + 1)
        local ev = {
            version = 1,
            id = codec.uuid(),
            device = self.store:get_setting("sync_device"),
            time = now,
            sequence = 0,
            changes = taskchanges,
        }
        self.importing = true
        local ok, err = pcall(require("todo.sync.store").import, self.store, { codec.encode(ev) })
        self.importing = false
        if not ok then
            error(err, 0)
        end
    end
    for _, c in ipairs(changes) do
        local rev = codec.uuid()
        if c.kind == "task" and c.value then
            local r = rows(self.store.db, "SELECT sync_revision FROM tasks WHERE sync_uuid=:key", { key = c.key })[1]
            rev = r and r.sync_revision or rev
        end
        self.store.db:eval(
            [[INSERT INTO workspace_records(kind,key,value,revision,dirty,server_version,shadow)
            VALUES(:kind,:key,:value,:revision,0,:version,:value) ON CONFLICT(kind,key) DO UPDATE SET
            value=excluded.value,revision=excluded.revision,dirty=0,server_version=excluded.server_version,shadow=excluded.shadow]],
            { kind = c.kind, key = c.key, value = encode(c.value), revision = rev, version = c.version }
        )
    end
end
function M:import_page(page)
    assert(
        type(page) == "table"
            and page.version == 2
            and type(page.operations) == "table"
            and type(page.cursor) == "number",
        "invalid cloud page"
    )
    local changes, conflicts, latest = {}, {}, {}
    for _, op in ipairs(page.operations) do
        local flight = self.store:get_setting("cloud_flight")
        if flight and flight ~= "" then
            local pending = decode(flight)
            if pending.operation_id == op.id then
                self:ack(pending, { version = 2, changes = op.changes })
            end
        end
        assert(type(op.changes) == "table", "invalid cloud operation")
        for _, c in ipairs(op.changes) do
            assert(kinds[c.kind] and type(c.key) == "string" and type(c.version) == "number", "invalid cloud change")
            c = vim.deepcopy(c)
            if c.value == vim.NIL then
                c.value = nil
            end
            local id = c.kind .. "/" .. c.key
            if not latest[id] or latest[id].version < c.version then
                latest[id] = c
            end
        end
    end
    for _, c in pairs(latest) do
        local localrow = rows(
            self.store.db,
            "SELECT * FROM workspace_records WHERE kind=:kind AND key=:key",
            { kind = c.kind, key = c.key }
        )[1]
        if not localrow or c.version > tonumber(localrow.server_version) then
            if localrow and tonumber(localrow.dirty) == 1 and localrow.value ~= encode(c.value) then
                conflicts[#conflicts + 1] = c
            else
                changes[#changes + 1] = c
            end
        end
    end
    if #conflicts > 0 then
        for _, c in ipairs(conflicts) do
            self.store.db:eval(
                "INSERT OR REPLACE INTO workspace_conflicts(kind,key,remote) VALUES(:kind,:key,:remote)",
                { kind = c.kind, key = c.key, remote = codec.encode(c) }
            )
        end
        error("Cloud conflict; use :Todo sync conflicts")
    end
    self.store:transaction(function()
        apply_records(self, changes)
        self:set_cursor(page.cursor)
    end)
    if #changes > 0 then
        self:notify()
    end
    return #changes
end
function M:resolve(kind, key, choice)
    local r = assert(
        rows(
            self.store.db,
            "SELECT remote FROM workspace_conflicts WHERE kind=:kind AND key=:key",
            { kind = kind, key = key }
        )[1],
        "conflict not found"
    )
    local c = decode(r.remote)
    self.store:transaction(function()
        if choice == "remote" then
            apply_records(self, { c })
        else
            assert(choice == "local", "invalid resolution")
            self.store.db:eval(
                "UPDATE workspace_records SET server_version=:version,shadow=:shadow,dirty=1 WHERE kind=:kind AND key=:key",
                { kind = kind, key = key, version = c.version, shadow = encode(c.value) }
            )
        end
        self.store.db:eval("DELETE FROM workspace_conflicts WHERE kind=:kind AND key=:key", { kind = kind, key = key })
        self.store:set_setting("cloud_flight", "")
    end)
    self:notify()
end
function M:restore(changes)
    return self.store:transaction(function()
        for _, c in ipairs(changes) do
            local _, revision = self:get(c.kind, c.key)
            assert(c.expected_revision == revision, "history conflict: " .. c.kind .. "/" .. c.key)
        end
        local tasks = {}
        for _, c in ipairs(changes) do
            if c.kind == "task" then
                local value = vim.deepcopy(c.value)
                if value then
                    value.updated_at = os.time()
                end
                tasks[#tasks + 1] = { kind = "task", key = c.key, value = value, deleted = value == nil or nil }
            else
                self:_write(c.kind, c.key, c.value)
            end
        end
        if #tasks > 0 then
            require("todo.sync.store").apply_local(self.store, tasks)
        end
        local versions = {}
        for _, c in ipairs(changes) do
            local _, rev = self:get(c.kind, c.key)
            versions[c.kind .. "/" .. c.key] = rev
        end
        self:notify()
        return versions
    end)
end
return M
