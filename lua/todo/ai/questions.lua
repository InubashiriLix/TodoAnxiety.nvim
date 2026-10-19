local M = {}
local codec = require("todo.sync.codec")
local function text(value, max, name)
    assert(type(value) == "string" and #value > 0 and #value <= max, "invalid " .. name)
    return value
end
function M.normalize(result, limit)
    limit = math.max(1, math.floor(tonumber(limit) or 4))
    local list = result.questions or { { question = result.question, options = {} } }
    assert(vim.islist(list) and #list >= 1, "invalid question count")
    local out, seen = {}, {}
    for i, q in ipairs(list) do
        if #out >= limit then
            -- The provider may ignore the per-round cap; keep the first valid
            -- questions usable instead of discarding the whole response.
            break
        end
        assert(type(q) == "table", "invalid question")
        -- Drop a malformed entry instead of discarding the whole round; the
        -- remaining questions are still useful and the provider can be repaired
        -- on a later round.
        if type(q.question) == "string" and #q.question > 0 then
            local id = q.id
            if type(id) ~= "string" or id == "" or #id > 128 or seen[id] then
                id = tostring(i)
                local suffix = 1
                while seen[id] do
                    id = tostring(i) .. "_" .. suffix
                    suffix = suffix + 1
                end
            end
            seen[id] = true
            local options, ids = {}, {}
            local raw_options = q.options
            if type(raw_options) ~= "table" or not vim.islist(raw_options) then
                raw_options = {}
            elseif #raw_options > 5 then
                -- Providers sometimes return more alternatives than the schema
                -- allows; keep the first five instead of failing the whole round.
                raw_options = { unpack(raw_options, 1, 5) }
            end
            -- An open-ended question may have no options. Once a question offers
            -- choices, require 3-5 concrete alternatives (OpenCode-style tool
            -- schema validation) instead of accepting two-option shortcuts.
            require("todo.ai.tools").validate_option_count(#raw_options, q.multiple == true)
            local labels = {}
            for j, o in ipairs(raw_options) do
                if type(o) == "string" then
                    o = { label = o }
                end
                if type(o) == "table" and type(o.label) == "string" and o.label ~= "" then
                    local oid = o.id
                    if type(oid) ~= "string" or oid == "" or #oid > 128 or ids[oid] then
                        oid = tostring(j)
                        local suffix = 1
                        while ids[oid] do
                            oid = tostring(j) .. "_" .. suffix
                            suffix = suffix + 1
                        end
                    end
                    ids[oid] = true
                    local label = vim.fn.strcharpart(o.label, 0, 500)
                    local key = label:lower():gsub("%s+", " ")
                    assert(not labels[key], "duplicate option label")
                    labels[key] = true
                    local description
                    if type(o.description) == "string" and o.description ~= "" then
                        description = vim.fn.strcharpart(o.description, 0, 2000)
                    end
                    options[#options + 1] = {
                        id = oid,
                        label = label,
                        description = description,
                    }
                end
            end
            out[#out + 1] = {
                id = id,
                header = q.header and text(q.header, 120, "header") or tostring(i),
                question = text(q.question, 4000, "question"),
                multiple = q.multiple == true,
                intent = q.intent,
                options = options,
            }
        end
    end
    assert(#out > 0, "invalid question")
    return { id = codec.uuid(), questions = out, answers = {}, tab = 1, selected = 1, status = "pending" }
end
function M.transcript(round)
    local lines = { "Question round " .. round.id }
    local answered = {}
    for _, q in ipairs(round.questions) do
        local a = round.answers[q.id] or { selected = {}, notes = {} }
        local labels, has_note = {}, false
        lines[#lines + 1] = q.question
        if a.declined then
            lines[#lines + 1] = "Answer: user skipped this question; no answer needed. Do not ask it again."
            lines[#lines + 1] = ""
            answered[q.id] =
                { selected = {}, notes = {}, custom = "", declined = true }
        else
            for _, o in ipairs(q.options) do
                if a.selected and a.selected[o.id] then
                    labels[#labels + 1] = o.label
                end
                local note = a.notes and a.notes[o.id]
                if note and note ~= "" then
                    has_note = true
                    lines[#lines + 1] = "Option "
                        .. o.label
                        .. " ["
                        .. (a.selected and a.selected[o.id] and "selected" or "not selected")
                        .. "] note: "
                        .. note
                end
            end
            if a.custom and a.custom ~= "" then
                labels[#labels + 1] = a.custom
            end
            answered[q.id] =
                { selected = vim.deepcopy(a.selected or {}), notes = vim.deepcopy(a.notes or {}), custom = a.custom or "" }
            lines[#lines + 1] = #labels > 0 and "Answer: " .. table.concat(labels, "; ")
                or has_note and "Answer: see the user's option notes above; no option was selected. Do not infer acceptance of the unselected option."
                or "Answer: unknown / skipped"
            lines[#lines + 1] = ""
        end
    end
    return table.concat(lines, "\n"), answered
end

--- A question counts as answered when an option is selected, any option has a
--- note (selected or not), or the custom answer is non-empty.
function M.answered(round, q)
    local a = round.answers and round.answers[q.id]
    if not a then
        return false
    end
    if a.declined then
        return true
    end
    if a.custom and a.custom ~= "" then
        return true
    end
    for _, option in ipairs(q.options or {}) do
        if (a.selected or {})[option.id] then
            return true
        end
        local note = (a.notes or {})[option.id]
        if note and note ~= "" then
            return true
        end
    end
    return false
end

function M.missing(round)
    local result = {}
    for _, q in ipairs(round.questions or {}) do
        if not M.answered(round, q) then
            result[#result + 1] = q
        end
    end
    return result
end

function M.validate(round)
    local missing = M.missing(round)
    if #missing == 0 then
        return true
    end
    local headers = {}
    for _, q in ipairs(missing) do
        headers[#headers + 1] = q.header or q.question
    end
    return nil, "Answer or explain every question first: " .. table.concat(headers, ", ")
end
function M.display(round)
    local zh = require("todo.config").get().language == "zh-CN"
    local lines = {}
    for _, q in ipairs(round.questions) do
        local a = round.answers[q.id] or {}
        lines[#lines + 1] = q.question
        if a.declined then
            lines[#lines + 1] = zh and "已跳过（不需要答案）" or "Skipped (no answer needed)"
        else
            local provided = false
            for _, o in ipairs(q.options) do
                if (a.selected or {})[o.id] then
                    lines[#lines + 1] = "✓ " .. o.label
                    provided = true
                end
                local note = (a.notes or {})[o.id]
                if note and note ~= "" then
                    lines[#lines + 1] = "↳ "
                        .. o.label
                        .. ((a.selected or {})[o.id] and "" or (zh and "（未勾选）" or " (not selected)"))
                        .. ": "
                        .. note
                    provided = true
                end
            end
            if a.custom and a.custom ~= "" then
                lines[#lines + 1] = a.custom
                provided = true
            end
            if not provided then
                lines[#lines + 1] = zh and "未回答" or "Not answered"
            end
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end
return M
