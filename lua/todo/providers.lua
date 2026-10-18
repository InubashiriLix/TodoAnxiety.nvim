-- Explicit capabilities: do not probe paid endpoints or silently change models.
local M = {}
function M.capabilities(cfg)
    local deepseek = (cfg.provider or "deepseek") == "deepseek"
    return vim.tbl_extend(
        "force",
        {
            streaming = deepseek,
            stream_usage = deepseek,
            vision = deepseek,
            balance = deepseek,
            json_mode = deepseek,
            thinking_control = deepseek,
        },
        cfg.capabilities or {}
    )
end
function M.key_env(cfg)
    if cfg.provider == "openai_compatible" and cfg.api_key_env == "DEEPSEEK_API_KEY" then
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
return M
