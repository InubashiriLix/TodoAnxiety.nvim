-- Anthropic Messages API SSE decoder.
local M = {}

function M.new(on_text)
    local self = { buffer = "", content = "", done = false, usage = nil, stop_reason = nil, finish_reason = nil, display = "" }
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
                local ok, event = pcall(vim.json.decode, table.concat(data, "\n"), {
                    luanil = { object = true, array = true },
                })
                if ok and type(event) == "table" then
                    if event.type == "content_block_delta" and event.delta and event.delta.type == "text_delta" then
                        self.content = self.content .. (event.delta.text or "")
                        local display = require("todo.ai.stream").message(self.content)
                        if display ~= self.display then
                            self.display = display
                            if on_text then
                                on_text(display)
                            end
                        end
                    elseif event.type == "message_delta" then
                        self.usage = vim.tbl_extend("force", self.usage or {}, event.usage or {})
                        self.stop_reason = event.delta and event.delta.stop_reason or self.stop_reason
                        self.finish_reason = self.stop_reason
                    elseif event.type == "message_stop" then
                        self.done = true
                        self.finish_reason = self.stop_reason or "stop"
                    elseif event.type == "error" then
                        error("AI stream failed: " .. vim.inspect(event.error or event))
                    end
                end
            end
        end
    end
    function self:response()
        return {
            content = { { type = "text", text = self.content } },
            usage = self.usage,
            stop_reason = self.stop_reason,
        }
    end
    return self
end

return M
