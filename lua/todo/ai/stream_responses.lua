-- OpenAI Responses API SSE decoder. Produces the same display-only partial
-- JSON message as the Chat Completions decoder.
local M = {}

local function partial_message(content)
    return require("todo.ai.stream").message(content)
end

function M.new(on_text)
    local self = { buffer = "", content = "", done = false, usage = nil, status = nil, finish_reason = nil, display = "" }
    function self:feed(bytes)
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
                    local ok, event = pcall(vim.json.decode, value, { luanil = { object = true, array = true } })
                    if ok and type(event) == "table" then
                        if event.type == "response.output_text.delta" then
                            self.content = self.content .. (event.delta or "")
                            local display = partial_message(self.content)
                            if display ~= self.display then
                                self.display = display
                                if on_text then
                                    on_text(display)
                                end
                            end
                        elseif event.type == "response.completed" then
                            self.done = true
                            self.usage = event.response and event.response.usage
                            self.status = "completed"
                            self.finish_reason = "completed"
                            if self.content == "" and event.response then
                                self.content = event.response.output_text or ""
                            end
                        elseif event.type == "response.failed" then
                            error("AI stream failed: " .. vim.inspect(event.response and event.response.error or event))
                        end
                    end
                end
            end
        end
    end
    function self:response()
        return { output_text = self.content, usage = self.usage, status = self.status }
    end
    return self
end

return M
