-- Presentation-only reads. Command/AI validation continues to use the live
-- service. Versions advance at commit, before asynchronous UI notifications.
local M = {}
M.__index = M
function M.new(service)
    local self = setmetatable({ source = service, records = {}, documents = {}, usages = {} }, M)
    self.live = service.store.workspace
    self.store = {
        get = function(_, id)
            return self:task(id)
        end,
        get_setting = function(_, key)
            local version = self.live.generation or 0
            if self.settings_version ~= version then
                self.settings, self.settings_version = {}, version
            end
            if not self.settings[key] then
                self.settings[key] = { service.store:get_setting(key) }
            end
            return unpack(self.settings[key])
        end,
    }
    self.ws = {
        store = self.store,
        get = function(_, kind, key)
            self:list(kind)
            local r = self.records[kind].by_key[key]
            if r then
                return r.value, r.revision
            end
        end,
        list = function(_, kind)
            return self:list(kind)
        end,
    }
    self.service = { store = self.store }
    return self
end
function M:version(kind)
    local live = self.live
    if not live then
        return 0
    end
    return math.max(live.reset_generation or 0, (live.generations or {})[kind] or 0)
end
function M:invalidate()
    self.records, self.documents, self.usages = {}, {}, {}
    self.task_version, self.settings_version, self.card_key = nil, nil, nil
end
function M:list(kind)
    local version = self:version(kind)
    local cached = self.records[kind]
    if not cached or cached.version ~= version then
        local rows, by_key = self.live:list(kind), {}
        for _, r in ipairs(rows) do
            by_key[r.key] = r
        end
        cached = { rows = rows, by_key = by_key, version = version }
        self.records[kind] = cached
    end
    return cached.rows
end
function M:task(id)
    local version = self:version("task")
    if self.task_version ~= version then
        self.tasks, self.task_version = {}, version
        for _, archived in ipairs({ false, true }) do
            for _, task in ipairs(self.source.store:list({ archived = archived })) do
                self.tasks[task.id] = task
            end
        end
    end
    return self.tasks[id]
end
function M:document(entry)
    local task = self:task(entry.task_id)
    if not task then
        return
    end
    local version = self:version("task") .. ":" .. self:version("note")
    local cached = self.documents[entry.uuid]
    if not cached or cached.version ~= version then
        cached = {
            version = version,
            value = require("todo.memory").new(self.ws, self.service):task_document(task),
        }
        self.documents[entry.uuid] = cached
    end
    return cached.value
end
function M:daily(controller)
    local display = setmetatable(
        { ws = self.ws, service = self.service, task_version = self:version("task"), presentation = self },
        { __index = controller }
    )
    display.document = function(_, entry)
        return self:document(entry)
    end
    local counts
    display.counts = function(c)
        if not counts then
            counts = { controller.counts(c) }
        end
        return unpack(counts)
    end
    display.ai = {
        usage = function(_, id)
            local version = self:version("usage") .. ":" .. os.date("%Y-%m-%d")
            local cached = self.usages[id]
            if not cached or cached.version ~= version then
                cached = { version = version, value = controller.ai.usage({ ws = self.ws }, id) }
                self.usages[id] = cached
            end
            return cached.value
        end,
    }
    return display
end
return M
