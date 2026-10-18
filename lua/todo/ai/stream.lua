-- SSE framing and a display-only projection of the top-level JSON message.
local M = {}
local function string_end(s, start)
    local escaped = false
    for i = start + 1, #s do
        local c = s:sub(i, i)
        if escaped then
            escaped = false
        elseif c == "\\" then
            escaped = true
        elseif c == '"' then
            return i
        end
    end
end
function M.message(s)
    local depth, i = 0, 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == "{" or c == "[" then
            depth = depth + 1
        elseif c == "}" or c == "]" then
            depth = depth - 1
        elseif c == '"' then
            local finish = string_end(s, i)
            if not finish then
                return ""
            end
            if depth == 1 and s:sub(i, finish) == '"message"' then
                local _, e = s:sub(finish + 1):find('^%s*:%s*"')
                if e then
                    local value_start = finish + e
                    local value_end = string_end(s, value_start)
                    local raw = s:sub(value_start + 1, value_end and value_end - 1 or #s)
                    for trim = 0, math.min(12, #raw) do
                        local ok, value = pcall(vim.json.decode, '"' .. raw:sub(1, #raw - trim) .. '"')
                        if ok then
                            return value
                        end
                    end
                    return ""
                end
            end
            i = finish
        end
        i = i + 1
    end
    return ""
end
function M.new(on_text)
    local self = { buffer = "", content = "", done = false, finish_reason = nil, usage = nil, display = "" }
    function self:feed(bytes)
        assert(not self.done or bytes:match("^%s*$"), "data after SSE completion")
        self.buffer = (self.buffer .. bytes):gsub("\r\n", "\n")
        while true do
            local a, b = self.buffer:find("\n\n", 1, true)
            if not a then
                break
            end
            local frame = self.buffer:sub(1, a - 1)
            self.buffer = self.buffer:sub(b + 1)
            local data = {}
            for line in (frame .. "\n"):gmatch("(.-)\n") do
                if line:sub(1, 5) == "data:" then
                    data[#data + 1] = line:sub(6):gsub("^ ", "")
                end
            end
            if #data > 0 then
                local value = table.concat(data, "\n")
                if value == "[DONE]" then
                    self.done = true
                else
                    assert(not self.done, "event after SSE completion")
                    local event = vim.json.decode(value, { luanil = { object = true, array = true } })
                    assert(type(event) == "table" and not event.error, "invalid SSE event")
                    if type(event.usage) == "table" then
                        self.usage = event.usage
                    end
                    local choice = event.choices and event.choices[1]
                    if choice then
                        if choice.finish_reason then
                            self.finish_reason = choice.finish_reason
                        end
                        local delta = choice.delta and choice.delta.content
                        if delta then
                            assert(type(delta) == "string", "invalid content delta")
                            self.content = self.content .. delta
                        end
                        local display = M.message(self.content)
                        if display ~= self.display then
                            self.display = display
                            if on_text then
                                on_text(display)
                            end
                        end
                    end
                end
            end
        end
    end
    function self:response()
        return {
            choices = { { message = { content = self.content }, finish_reason = self.finish_reason } },
            usage = self.usage,
        }
    end
    return self
end
return M
