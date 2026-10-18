package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local providers = require("todo.providers")
local function eq(a, b, label)
    assert(vim.deep_equal(a, b), (label or "value") .. ": " .. vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local base = {
    model = "test-model",
    max_output_tokens = 128,
    api_key_env = "AI_API_KEY",
    capabilities = {},
}

local deepseek = vim.tbl_extend("force", base, {
    provider = "deepseek",
    base_url = "https://api.deepseek.com",
})
local request = providers.request(deepseek, { { role = "user", content = "hi" } }, { key = "secret", stream = true })
eq(request.url, "https://api.deepseek.com/chat/completions", "deepseek url")
eq(request.headers.Authorization, "Bearer secret", "deepseek auth")
eq(request.body.stream, true, "deepseek stream")
eq(request.body.response_format, { type = "json_object" }, "deepseek json mode")
eq(request.body.max_tokens, 128, "deepseek token field")

local compatible = vim.tbl_extend("force", deepseek, {
    provider = "openai_compatible",
    base_url = "https://example.test/v1",
    capabilities = { json_mode = false, thinking_control = false, streaming = false },
})
request = providers.request(compatible, { { role = "user", content = "hi" } }, { key = "secret" })
eq(request.url, "https://example.test/v1/chat/completions", "compatible url")
eq(request.body.response_format, nil, "compatible omits json mode")
eq(request.body.thinking, nil, "compatible omits thinking")

local openai = vim.tbl_extend("force", base, {
    provider = "openai",
    base_url = "https://api.openai.com/v1",
    capabilities = { json_mode = true },
})
request = providers.request(openai, {
    { role = "system", content = "be brief" },
    { role = "user", content = "hi" },
}, { key = "secret" })
eq(request.url, "https://api.openai.com/v1/responses", "openai url")
eq(request.body.instructions, "be brief", "openai instructions")
eq(request.body.input[1].content[1].type, "input_text", "openai input text")
eq(request.body.max_output_tokens, 128, "openai max output")
local parsed = providers.parse(openai, {
    output = { { content = { { type = "output_text", text = "hello" } } } },
    usage = { input_tokens = 5, output_tokens = 2, input_tokens_details = { cached_tokens = 1 } },
    status = "completed",
})
eq(parsed.content, "hello", "openai content")
eq(parsed.usage.prompt_tokens, 5, "openai prompt usage")
eq(parsed.usage.prompt_cache_hit_tokens, 1, "openai cache usage")

local anthropic = vim.tbl_extend("force", base, {
    provider = "anthropic",
    base_url = "https://api.anthropic.com",
})
request = providers.request(anthropic, {
    { role = "system", content = "be brief" },
    { role = "user", content = "hi" },
}, { key = "secret", stream = true })
eq(request.url, "https://api.anthropic.com/v1/messages", "anthropic url")
eq(request.headers["x-api-key"], "secret", "anthropic auth")
eq(request.headers["anthropic-version"], "2023-06-01", "anthropic version")
eq(request.body.system, "be brief", "anthropic system")
eq(request.body.messages[1].role, "user", "anthropic turns")
eq(request.body.stream, true, "anthropic stream")
parsed = providers.parse(anthropic, {
    content = { { type = "text", text = "hello" } },
    usage = { input_tokens = 7, output_tokens = 3, cache_read_input_tokens = 2 },
    stop_reason = "end_turn",
})
eq(parsed.content, "hello", "anthropic content")
eq(parsed.usage.prompt_tokens, 7, "anthropic prompt usage")
eq(parsed.usage.completion_tokens, 3, "anthropic completion usage")
eq(parsed.finish_reason, "end_turn", "anthropic finish")

local responses_stream = providers.decoder(openai, function() end)
responses_stream:feed('data: {"type":"response.output_text.delta","delta":"hi"}\n\n')
responses_stream:feed('data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}\n\n')
eq(responses_stream.content, "hi", "responses stream content")
assert(responses_stream.done and responses_stream.finish_reason == "completed")

local anthropic_stream = providers.decoder(anthropic, function() end)
anthropic_stream:feed(
    'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n'
)
anthropic_stream:feed('data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n')
anthropic_stream:feed('data: {"type":"message_stop"}\n\n')
eq(anthropic_stream.content, "hi", "anthropic stream content")
assert(anthropic_stream.done and anthropic_stream.finish_reason == "end_turn")

print("ok - provider envelopes, normalized usage and streaming decoders")
vim.cmd("qa!")
