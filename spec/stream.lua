package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local stream = require("todo.ai.stream")
local content = vim.json.encode({ message = '你好 🌟\n"quoted" \\ text', action = "draft", changes = {} })
local expected = vim.json.decode(content).message
local frames = ": heartbeat\r\n\r\n"
for i = 1, #content do
    frames = frames
        .. "data: "
        .. vim.json.encode({ choices = { { delta = { content = content:sub(i, i) } } } })
        .. "\r\n\r\n"
end
frames = frames
    .. "data: "
    .. vim.json.encode({ choices = { { delta = {}, finish_reason = "stop" } }, usage = {
        prompt_tokens = 12,
        completion_tokens = 8,
    } })
    .. "\r\n\r\ndata: [DONE]\r\n\r\n"
for _, step in ipairs({ 1, 2, 3, 7, 1024, #frames }) do
    local seen = {}
    local decoder = stream.new(function(s)
        seen[#seen + 1] = s
        assert(not s:find('"action"', 1, true))
    end)
    for i = 1, #frames, step do
        decoder:feed(frames:sub(i, i + step - 1))
    end
    assert(decoder.done and decoder.finish_reason == "stop")
    assert(decoder.display == expected, vim.inspect(decoder.display))
    assert(decoder:response().usage.prompt_tokens == 12)
    assert(decoder.content == content)
end
assert(stream.message('{"nested":{"message":"secret"},"message":"visible') == "visible")
assert(stream.message('{"message":"abc\\u4f') == "abc")
local bad = stream.new()
assert(not pcall(bad.feed, bad, "data: invalid\n\n"))
local truncated = stream.new()
truncated:feed('data: {"choices":[]}\n\n')
assert(not truncated.done)
print("ok - SSE byte fragmentation, UTF-8, CRLF, usage, JSON display projection and malformed events")
vim.cmd("qa!")
