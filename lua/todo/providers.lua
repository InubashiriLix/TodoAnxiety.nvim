-- Explicit capabilities: do not probe paid endpoints or silently change models.
local M = {}

function M.capabilities(cfg)
    local provider = cfg.provider or "deepseek"
    local defaults = {
        streaming = false,
        stream_usage = false,
        vision = false,
        balance = false,
        json_mode = false,
        thinking_control = false,
    }
    if provider == "deepseek" then
        defaults = {
            streaming = true,
            stream_usage = true,
            vision = true,
            balance = true,
            json_mode = true,
            thinking_control = true,
        }
    elseif provider == "openai" then
        defaults = { streaming = true, vision = true, json_mode = true }
    elseif provider == "anthropic" then
        defaults = { streaming = true, vision = true }
    end
    return vim.tbl_extend("force", defaults, cfg.capabilities or {})
end

function M.key_env(cfg)
    if cfg.provider == "openai" then
        return "OPENAI_API_KEY"
    elseif cfg.provider == "anthropic" then
        return "ANTHROPIC_API_KEY"
    elseif cfg.provider == "openai_compatible" and cfg.api_key_env == "DEEPSEEK_API_KEY" then
        return "AI_API_KEY"
    end
    return cfg.api_key_env
end

function M.namespace(cfg)
    return vim.fn.sha256((cfg.provider or "deepseek") .. ":" .. cfg.base_url:gsub("/+$", ""))
end

function M.deepseek_credentials(cfg)
    return (cfg.provider or "deepseek") == "deepseek" and cfg.base_url:gsub("/+$", "") == "https://api.deepseek.com"
end

-- Chat Completions body used by DeepSeek and OpenAI-compatible providers.
function M.body(cfg, messages)
    local caps = M.capabilities(cfg)
    local body = { model = cfg.model, messages = messages }
    body[cfg.max_tokens_field or "max_tokens"] = cfg.max_output_tokens
    if caps.json_mode then
        body.response_format = { type = "json_object" }
    end
    if caps.thinking_control then
        body.thinking = { type = "disabled" }
    end
    return body
end

local function content_text(value)
    if type(value) == "string" then
        return value
    end
    if type(value) == "table" then
        local parts = {}
        for _, item in ipairs(value) do
            if type(item) == "string" then
                parts[#parts + 1] = item
            elseif type(item) == "table" then
                parts[#parts + 1] = item.text or item.content or ""
            end
        end
        return table.concat(parts)
    end
    return ""
end

local function anthropic_content(value)
    if type(value) == "string" then
        return value
    end
    local out = {}
    for _, part in ipairs(value or {}) do
        if type(part) == "string" then
            out[#out + 1] = { type = "text", text = part }
        elseif part.type == "text" then
            out[#out + 1] = { type = "text", text = part.text or "" }
        elseif part.type == "image_url" and part.image_url and part.image_url.url then
            local mime, data = part.image_url.url:match("^data:([^;]+);base64,(.+)$")
            if mime and data then
                out[#out + 1] = {
                    type = "image",
                    source = { type = "base64", media_type = mime, data = data },
                }
            end
        end
    end
    return out
end

local function responses_content(value)
    if type(value) == "string" then
        return { { type = "input_text", text = value } }
    end
    local out = {}
    for _, part in ipairs(value or {}) do
        if type(part) == "string" then
            out[#out + 1] = { type = "input_text", text = part }
        elseif part.type == "text" then
            out[#out + 1] = { type = "input_text", text = part.text or "" }
        elseif part.type == "image_url" and part.image_url and part.image_url.url then
            out[#out + 1] = { type = "input_image", image_url = part.image_url.url }
        end
    end
    return out
end

--- Provider-specific request envelope.
function M.request(cfg, messages, opts)
    opts = opts or {}
    local provider = cfg.provider or "deepseek"
    local base = cfg.base_url:gsub("/+$", "")
    if provider == "anthropic" then
        local system, turns = {}, {}
        for _, message in ipairs(messages) do
            if message.role == "system" then
                system[#system + 1] = content_text(message.content)
            else
                turns[#turns + 1] = {
                    role = message.role == "assistant" and "assistant" or "user",
                    content = anthropic_content(message.content),
                }
            end
        end
        local body = {
            model = cfg.model,
            max_tokens = cfg.max_output_tokens,
            messages = turns,
        }
        if #system > 0 then
            body.system = table.concat(system, "\n\n")
        end
        if opts.stream then
            body.stream = true
        end
        return {
            url = base .. "/v1/messages",
            headers = {
                ["x-api-key"] = opts.key,
                ["anthropic-version"] = "2023-06-01",
                ["content-type"] = "application/json",
            },
            body = body,
        }
    elseif provider == "openai" then
        local instructions, input = {}, {}
        for _, message in ipairs(messages) do
            if message.role == "system" then
                instructions[#instructions + 1] = content_text(message.content)
            else
                input[#input + 1] = {
                    role = message.role == "assistant" and "assistant" or "user",
                    content = responses_content(message.content),
                }
            end
        end
        local body = {
            model = cfg.model,
            input = input,
            max_output_tokens = cfg.max_output_tokens,
        }
        if #instructions > 0 then
            body.instructions = table.concat(instructions, "\n\n")
        end
        if M.capabilities(cfg).json_mode then
            body.text = { format = { type = "json_object" } }
        end
        return {
            url = base .. "/responses",
            headers = {
                Authorization = "Bearer " .. opts.key,
                ["Content-Type"] = "application/json",
            },
            body = body,
        }
    end
    local body = M.body(cfg, messages)
    if opts.stream then
        body.stream = true
        if M.capabilities(cfg).stream_usage then
            body.stream_options = { include_usage = true }
        end
    end
    return {
        url = base .. "/chat/completions",
        headers = { Authorization = "Bearer " .. opts.key, ["Content-Type"] = "application/json" },
        body = body,
    }
end

--- Normalize a provider response into { content, usage, finish_reason }.
function M.parse(cfg, response)
    local provider = cfg.provider or "deepseek"
    if provider == "anthropic" then
        local text = {}
        for _, block in ipairs(response.content or {}) do
            if block.type == "text" and type(block.text) == "string" then
                text[#text + 1] = block.text
            end
        end
        local usage = response.usage or {}
        return {
            content = table.concat(text),
            finish_reason = response.stop_reason,
            usage = {
                prompt_tokens = usage.input_tokens,
                completion_tokens = usage.output_tokens,
                prompt_cache_hit_tokens = usage.cache_read_input_tokens,
            },
        }
    elseif provider == "openai" then
        local text = response.output_text
        if not text and type(response.output) == "table" then
            local parts = {}
            for _, item in ipairs(response.output) do
                for _, block in ipairs(item.content or {}) do
                    if block.type == "output_text" then
                        parts[#parts + 1] = block.text or ""
                    end
                end
            end
            text = table.concat(parts)
        end
        local usage = response.usage or {}
        return {
            content = text or "",
            finish_reason = response.status,
            usage = {
                prompt_tokens = usage.input_tokens,
                completion_tokens = usage.output_tokens,
                prompt_cache_hit_tokens = usage.input_tokens_details
                    and usage.input_tokens_details.cached_tokens,
            },
        }
    end
    local choice = response.choices and response.choices[1]
    return {
        content = choice and choice.message and choice.message.content or "",
        finish_reason = choice and choice.finish_reason,
        usage = response.usage,
    }
end

function M.decoder(cfg, on_text)
    if cfg.provider == "openai" then
        return require("todo.ai.stream_responses").new(on_text)
    elseif cfg.provider == "anthropic" then
        return require("todo.ai.stream_anthropic").new(on_text)
    end
    return require("todo.ai.stream").new(on_text)
end

return M
