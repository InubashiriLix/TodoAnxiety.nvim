-- Durable, sourced memories; search indexes are disposable and device-local.
local M = {}
M.__index = M
local codec = require("todo.sync.codec")
local function cfg()
    return require("todo.config").get().ai.memory
end
local function terms(text)
    local out, seen, previous = {}, {}, nil
    local function add(word)
        if not seen[word] then
            out[#out + 1] = word
            seen[word] = true
        end
    end
    for word in text:lower():gmatch("[%w_]+") do
        add(word)
    end
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #char > 1 then
            if previous then
                add(previous .. char)
            end
            previous = char
        else
            previous = nil
        end
    end
    return out
end
function M.new(ws, service)
    return setmetatable({ ws = ws, service = service }, M)
end
function M:list(pending, date)
    local result = {}
    for _, r in ipairs(self.ws:list("memory")) do
        local m = r.value
        if
            (pending or m.status == "confirmed")
            and (not date or m.scope == "global" or m.scope == date)
            and (not m.expires_at or m.expires_at > os.time())
        then
            result[#result + 1] = { id = r.key, value = m, revision = r.revision }
        end
    end
    table.sort(result, function(a, b)
        if a.value.pinned ~= b.value.pinned then
            return a.value.pinned == true
        end
        return (a.value.updated_at or 0) > (b.value.updated_at or 0)
    end)
    return result
end
function M:save(text, opts)
    opts = opts or {}
    assert(type(text) == "string" and #text > 0 and #text <= 16000, "invalid memory text")
    assert(not opts.status or opts.status == "confirmed" or opts.status == "pending", "invalid memory status")
    assert(
        not opts.scope
            or opts.scope == "global"
            or type(opts.scope) == "string" and require("todo.model").parse_deadline(opts.scope),
        "invalid memory scope"
    )
    local id = opts.id or codec.uuid()
    local m = {
        text = text,
        status = opts.status or "confirmed",
        scope = opts.scope or "global",
        source = opts.source,
        quote = opts.quote,
        expires_at = opts.expires_at,
        pinned = opts.pinned or false,
        category = opts.category,
        task_uuid = opts.task_uuid,
        task_revision = opts.task_revision,
        fact_key = opts.fact_key,
        updated_at = os.time(),
    }
    self.ws:batch(
        { { kind = "memory", key = id, value = m, expected_revision = opts.expected_revision } },
        opts.workflow_id and "ai_checkpoint" or nil
    )
    return id
end
function M:remove(id)
    local m, rev = self.ws:get("memory", id)
    assert(m, "memory not found")
    self.ws:batch({
        { kind = "memory", key = id, value = nil, expected_revision = rev },
        { kind = "profile", key = "memory_generation", value = codec.uuid() },
        { kind = "profile", key = "forgotten:" .. id, value = { source = m.source, quote = m.quote, text = m.text } },
    })
    -- Summaries can contain the forgotten fact. Invalidate them instead of
    -- allowing a model to reconstruct deleted memory from a derived record.
    for _, r in ipairs(self.ws:list("conversation")) do
        if r.value.summary then
            r.value.summary = nil
            self.ws:put("conversation", r.key, r.value, r.revision)
        end
    end
end
function M:capture(session, candidates)
    if not cfg().enabled then
        return
    end
    assert(type(candidates or {}) == "table" and #(candidates or {}) <= 16, "invalid memory candidates")
    local sources = {}
    for _, msg in ipairs(session.messages) do
        if msg.role == "user" and msg.id then
            sources[msg.id] = msg
        end
    end
    for _, c in ipairs(candidates or {}) do
        if type(c.text) == "string" and c.text ~= "" and #c.text <= 4000 then
            local source = sources[c.source_id]
            local explicit = source
                and type(c.quote) == "string"
                and #c.quote > 0
                and source.content:find(c.quote, 1, true)
            local forgotten = false
            for _, r in ipairs(self.ws:list("profile")) do
                if
                    r.key:match("^forgotten:")
                    and (
                        r.value.source == c.source_id and r.value.quote == c.quote
                        or r.value.text == (explicit and c.quote or c.text)
                    )
                then
                    forgotten = true
                end
            end
            if not forgotten then
                -- Automatic facts preserve the exact user quote, never an AI paraphrase.
                local text = explicit and c.quote or c.text
                local category = ({ preference = true, project = true, task_state = true })[c.category] and c.category
                    or "task_state"
                local lasting = c.scope == "global" and c.stable == true and category ~= "task_state"
                local uuid = category == "task_state" and (session.subject_uuid or session.task_uuid) or nil
                local scope = lasting and "global" or uuid and "global" or session.date
                local fact_key = type(c.fact_key) == "string" and c.fact_key:sub(1, 128) or nil
                local task_revision
                for _, task in ipairs(self.service.store:list({ archived = false })) do
                    if task.sync_uuid == uuid then
                        task_revision = task.sync_revision
                    end
                end
                local normalized = vim.trim(text):lower():gsub("%s+", " ")
                local id = vim.fn.sha256(scope .. ":" .. (uuid or "") .. ":" .. normalized)
                local duplicate, conflict = false, false
                for _, record in ipairs(self:list(true)) do
                    local old = record.value
                    if old.scope == scope and old.task_uuid == uuid then
                        if vim.trim(old.text):lower():gsub("%s+", " ") == normalized then
                            duplicate = true
                        end
                        if fact_key and old.fact_key == fact_key and old.text ~= text and old.status == "confirmed" then
                            conflict = true
                        end
                    end
                end
                if not duplicate and not self.ws:get("memory", id) then
                    self:save(text, {
                        id = id,
                        workflow_id = session.workflow_id,
                        status = explicit and c.inferred ~= true and not conflict and "confirmed" or "pending",
                        source = c.source_id or session.id,
                        quote = explicit and c.quote or nil,
                        scope = scope,
                        expires_at = not lasting and os.time() + (uuid and 7 * 86400 or 86400) or nil,
                        category = category,
                        task_uuid = uuid,
                        task_revision = task_revision,
                        fact_key = fact_key,
                    })
                end
            end
        end
    end
end
-- Select relevant durable facts locally. No embedding calls and no whole memory dump.
function M:select(tasks, date, budget)
    local query, uuids, revisions = {}, {}, {}
    for _, task in ipairs(tasks) do
        local uuid = task.task_uuid or task.sync_uuid
        uuids[uuid] = true
        query[#query + 1] = (task.title or "")
            .. " "
            .. table.concat(task.tags or {}, " ")
            .. " "
            .. (task.description or ""):sub(1, 1600)
    end
    for _, task in ipairs(self.service.store:list({ archived = false })) do
        revisions[task.sync_uuid] = task.sync_revision
    end
    local keys = terms(table.concat(query, " "))
    local ranked = {}
    for _, r in ipairs(self:list(false, date)) do
        local m = r.value
        local current = not m.task_uuid
            or uuids[m.task_uuid] and (not m.task_revision or m.task_revision == revisions[m.task_uuid])
        if current then
            local score = m.pinned and 1000 or m.category == "preference" and 100 or m.task_uuid and 50 or 0
            local lower = m.text:lower()
            for _, key in ipairs(keys) do
                if lower:find(key, 1, true) then
                    score = score + 1
                end
            end
            if score > 0 then
                ranked[#ranked + 1] = { record = r, score = score }
            end
        end
    end
    table.sort(ranked, function(a, b)
        if a.score == b.score then
            return (a.record.value.updated_at or 0) > (b.record.value.updated_at or 0)
        end
        return a.score > b.score
    end)
    local selected, bytes = {}, 0
    for _, rank in ipairs(ranked) do
        local r = rank.record
        local m = {
            id = r.id,
            text = r.value.text,
            source = r.value.source,
            scope = r.value.scope,
            task_uuid = r.value.task_uuid,
            updated_at = r.value.updated_at,
        }
        local size = #codec.encode(m)
        if bytes + size <= budget then
            selected[#selected + 1] = m
            bytes = bytes + size
        end
        if #selected >= cfg().search_limit then
            break
        end
    end
    return selected
end
function M:is_current(m, tasks)
    if not m.task_uuid then
        return true
    end
    for _, task in ipairs(tasks or self.service.store:list({ archived = false })) do
        if task.sync_uuid == m.task_uuid then
            return (task.status == "todo" or task.status == "in_progress")
                and (not m.task_revision or task.sync_revision == m.task_revision)
        end
    end
    return false
end
-- Checking one item must never construct the complete searchable corpus.
function M:task_document(task, notes)
    if not task or task.kind == "notice" then
        return
    end
    local text = task.description or ""
    for _, r in ipairs(notes or self.ws:list("note")) do
        if r.value.task_uuid == task.sync_uuid then
            text = text .. "\n" .. (r.value.text or "")
        end
    end
    return {
        id = task.sync_uuid,
        kind = "task",
        title = task.title,
        text = text,
        status = task.status,
        priority = task.priority,
        deadline = task.due_date,
        hash = vim.fn.sha256(text),
    }
end
function M:documents(date)
    local docs = {}
    local notes = self.ws:list("note")
    local tasks = self.service.store:list({ archived = false })
    for _, t in ipairs(tasks) do
        docs[#docs + 1] = self:task_document(t, notes)
    end
    for _, r in ipairs(self:list(false, date)) do
        if self:is_current(r.value, tasks) then
            docs[#docs + 1] = {
                id = r.id,
                kind = "memory",
                title = r.value.scope,
                text = r.value.text,
                source = r.value.source,
                pinned = r.value.pinned,
            }
        end
    end
    for _, r in ipairs(self.ws:list("conversation")) do
        if
            r.value.summary
            and r.value.summary ~= ""
            and (not date or r.value.date == date)
            and r.value.summary_generation == self.ws:get("profile", "memory_generation")
        then
            docs[#docs + 1] = { id = r.key, kind = "conversation", title = r.value.date, text = r.value.summary }
        end
    end
    return docs
end
function M:search(query, kind, limit, date)
    assert(type(query) == "string" and #query <= 1000, "invalid memory query")
    limit = math.max(1, math.min(8, tonumber(limit) or cfg().search_limit))
    local docs = self:documents(date)
    local keys = terms(query)
    local db = self.ws.store.db
    local single = query ~= "" and vim.fn.strchars(query) == 1 and #query > 1
    if single then
        keys = { query }
    end
    local fts = not single
        and pcall(function()
            db:execute("CREATE VIRTUAL TABLE IF NOT EXISTS todo_memory_fts USING fts5(identity UNINDEXED, tokens)")
            local digest = vim.fn.sha256(codec.encode(docs))
            if
                self.ws.store:get_setting("memory_index_digest") == digest
                and tonumber((db:eval("SELECT COUNT(*) AS n FROM todo_memory_fts")[1] or {}).n) == #docs
            then
                return
            end
            self.ws.store:transaction(function()
                db:eval("DELETE FROM todo_memory_fts")
                for i, d in ipairs(docs) do
                    db:eval(
                        "INSERT INTO todo_memory_fts(identity,tokens) VALUES(:id,:tokens)",
                        { id = tostring(i), tokens = table.concat(terms((d.title or "") .. " " .. d.text), " ") }
                    )
                end
                self.ws.store:set_setting("memory_index_digest", digest)
            end)
        end)
    local results = {}
    if fts and #keys > 0 then
        local quoted = {}
        for _, key in ipairs(keys) do
            quoted[#quoted + 1] = '"' .. key:gsub('"', '""') .. '"'
        end
        local query_ok, rows = pcall(
            db.eval,
            db,
            "SELECT identity FROM todo_memory_fts WHERE todo_memory_fts MATCH :query ORDER BY rank",
            { query = table.concat(quoted, " OR ") }
        )
        if not query_ok then
            fts = false
        end
        for _, r in ipairs(query_ok and type(rows) == "table" and rows or {}) do
            local d = docs[tonumber(r.identity)]
            if d and (not kind or d.kind == kind) then
                results[#results + 1] = d
            end
        end
    end
    if not fts or #keys == 0 then
        for _, d in ipairs(docs) do
            local score = 0
            local text = ((d.title or "") .. " " .. d.text):lower()
            for _, key in ipairs(keys) do
                if text:find(key, 1, true) then
                    score = score + 1
                end
            end
            if (score > 0 or query == "") and (not kind or d.kind == kind) then
                results[#results + 1] = vim.tbl_extend("force", d, { score = score })
            end
        end
        table.sort(results, function(a, b)
            return (a.score or 0) > (b.score or 0)
        end)
    end
    local out = {}
    for i = 1, math.min(limit, #results) do
        local d = vim.deepcopy(results[i])
        d.text = vim.fn.strcharpart(d.text, 0, 600)
        out[#out + 1] = d
    end
    return out
end
function M:lookup(call, session)
    assert(type(call) == "table" and type(call.args) == "table", "invalid lookup")
    local a = call.args
    assert(cfg().enabled or call.tool == "read_tasks" or call.tool == "search_tasks", "AI memory disabled")
    if call.tool == "search_tasks" or call.tool == "search_memory" then
        return self:search(a.query or "", call.tool == "search_tasks" and "task" or "memory", a.limit, session.date)
    end
    if call.tool == "get_memory" then
        local m = self.ws:get("memory", assert(a.id))
        assert(
            m
                and m.status == "confirmed"
                and self:is_current(m)
                and (m.scope == "global" or m.scope == session.date)
                and (not m.expires_at or m.expires_at > os.time()),
            "memory unavailable"
        )
        return { id = a.id, text = m.text, quote = m.quote, source = m.source, scope = m.scope }
    end
    assert(call.tool == "read_tasks", "unknown read-only tool")
    local ids = a.ids or { a.id }
    assert(type(ids) == "table" and #ids <= 8, "read at most eight tasks")
    local out = {}
    for _, id in ipairs(ids) do
        local found
        for _, d in ipairs(self:documents()) do
            if d.kind == "task" and d.id == id then
                found = d
                break
            end
        end
        assert(found, "task not found")
        local offset = math.max(0, math.floor(tonumber(a.offset) or 0))
        local chunk = math.max(
            128,
            math.min(3000, math.floor(require("todo.config").get().ai.context_tokens * 0.3 / math.max(1, #ids)))
        )
        local text = vim.fn.strcharpart(found.text, offset, chunk)
        local finish = offset + vim.fn.strchars(text)
        session.read_sources = session.read_sources or {}
        local previous = session.read_sources[id]
        local contiguous = offset == 0 or previous and previous.hash == found.hash and previous.offset == offset
        if contiguous then
            session.read_sources[id] =
                { hash = found.hash, offset = finish, complete = finish >= vim.fn.strchars(found.text) }
        end
        out[#out + 1] = {
            id = id,
            title = found.title,
            text = text,
            offset = offset,
            next_offset = finish,
            complete = finish >= vim.fn.strchars(found.text),
            hash = found.hash,
        }
    end
    return out
end
return M
