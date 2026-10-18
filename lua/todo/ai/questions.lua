local M = {}
local codec = require("todo.sync.codec")
local function text(value, max, name)
    assert(type(value) == "string" and #value > 0 and #value <= max, "invalid " .. name)
    return value
end
function M.normalize(result, limit)
    local list = result.questions or { { question = result.question, options = {} } }
    assert(vim.islist(list) and #list >= 1 and #list <= limit, "invalid question count")
    local out, seen = {}, {}
    for i, q in ipairs(list) do
        assert(type(q) == "table", "invalid question")
        local id = q.id or tostring(i)
        assert(type(id) == "string" and #id <= 128 and not seen[id], "duplicate question ID")
        seen[id] = true
        local options, ids = {}, {}
        local raw_options = q.options or {}
        assert(vim.islist(raw_options) and #raw_options <= 5, "invalid options")
        -- An open-ended question may have no options. Once a question offers
        -- choices, require 3-5 concrete alternatives (OpenCode-style tool
        -- schema validation) instead of accepting two-option shortcuts.
        require("todo.ai.tools").validate_option_count(#raw_options, q.multiple == true)
        local labels = {}
        for j, o in ipairs(raw_options) do
            if type(o) == "string" then
                o = { label = o }
            end
            assert(type(o) == "table", "invalid option")
            local oid = o.id or tostring(j)
            assert(type(oid) == "string" and #oid <= 128 and not ids[oid], "duplicate option ID")
            ids[oid] = true
            local label = text(o.label, 500, "option label")
            local key = label:lower():gsub("%s+", " ")
            assert(not labels[key], "duplicate option label")
            labels[key] = true
            options[#options + 1] = {
                id = oid,
                label = label,
                description = o.description and text(o.description, 2000, "option description"),
            }
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
    return { id = codec.uuid(), questions = out, answers = {}, tab = 1, selected = 1, status = "pending" }
end
function M.transcript(round)
    local lines = { "Question round " .. round.id }
    local answered = {}
    for _, q in ipairs(round.questions) do
        local a = round.answers[q.id] or { selected = {}, notes = {} }
        local labels, has_note = {}, false
        lines[#lines + 1] = q.question
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
    return table.concat(lines, "\n"), answered
end

--- A question counts as answered when an option is selected, any option has a
--- note (selected or not), or the custom answer is non-empty.
function M.answered(round, q)
    local a = round.answers and round.answers[q.id]
    if not a then
        return false
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
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end
return M
