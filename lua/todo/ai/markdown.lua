-- Advisory Markdown checks for AI-authored task descriptions and notes.
-- This module never rewrites content: the review UI shows warnings and the
-- user decides whether to apply the original text.
local M = {}

local function add(issues, seen, code, line)
    if not seen[code] then
        seen[code] = true
        issues[#issues + 1] = { code = code, line = line }
    end
end

function M.check(text, kind)
    local issues, seen = {}, {}
    text = tostring(text or "")
    if vim.trim(text) == "" then
        add(issues, seen, "empty", 1)
        return issues
    end
    if text:find("[%z\1-\8\11\12\14-\31]") then
        add(issues, seen, "control", 1)
    end
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = vim.split(normalized, "\n", { plain = true })
    local first = nil
    for index, line in ipairs(lines) do
        local trimmed = vim.trim(line)
        if trimmed ~= "" and not trimmed:match("^```") then
            first = { index = index, text = trimmed }
            break
        end
    end
    if first then
        local lower = first.text:lower()
        if
            lower:match("^#+%s*description%s*[:：]")
            or lower:match("^#+%s*description%s*$")
            or lower:match("^#+%s*note%s*[:：]")
            or lower:match("^#+%s*note%s*$")
            or lower:match("^description%s*[:：]")
            or lower:match("^note%s*[:：]")
            or first.text:match("^描述%s*[:：]")
            or first.text:match("^备注%s*[:：]")
        then
            add(issues, seen, "meta", first.index)
        end
        if kind == "note" and first.text:match("^#+%s+") then
            add(issues, seen, "note_heading", first.index)
        end
    end
    local trimmed = vim.trim(normalized)
    local fence, inner = trimmed:match("^```([%w_%-]*)\n(.-)\n```$")
    if fence and not inner:find("```", 1, true) then
        add(issues, seen, "wrapped", first and first.index or 1)
    end
    local fence_count = 0
    local fence_open = false
    for index, line in ipairs(lines) do
        if line:match("^%s*```") then
            fence_count = fence_count + 1
            if not fence_open and index > 1 and vim.trim(lines[index - 1]) ~= "" then
                add(issues, seen, "fence_space", index)
            end
            fence_open = not fence_open
        end
    end
    if fence_count % 2 == 1 then
        add(issues, seen, "fence", #lines)
    end
    local previous_blank = true
    local in_fence = false
    local in_list = false
    for index, line in ipairs(lines) do
        local blank = vim.trim(line) == ""
        if line:match("^%s*```") then
            in_fence = not in_fence
            in_list = false
        elseif not in_fence then
            if line:match("^%s*#%s+") then
                add(issues, seen, "h1", index)
            end
            if line:match("^%s*#+%s+") then
                if not previous_blank then
                    add(issues, seen, "heading_space", index)
                elseif lines[index + 1] and vim.trim(lines[index + 1]) ~= "" then
                    add(issues, seen, "heading_space", index)
                end
            end
            local list_item = line:match("^%s*[-*+]%s+") or line:match("^%s*%d+[.)]%s+")
            local indent = line:match("^(%s*)") or ""
            if list_item and not in_list and not previous_blank and #indent == 0 then
                add(issues, seen, "list_space", index)
            end
            in_list = list_item ~= nil
        end
        if blank then
            previous_blank = true
        elseif not in_fence then
            previous_blank = false
        end
    end
    local html_fence = false
    for index, line in ipairs(lines) do
        if line:match("^%s*```") then
            html_fence = not html_fence
        elseif not html_fence and line:find("<%a[%w%-]*[%s/>]") then
            add(issues, seen, "html", index)
            break
        end
    end
    return issues
end

return M
