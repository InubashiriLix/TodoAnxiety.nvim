-- First-run AI configuration. The key is device-local; provider/endpoint/model
-- are stored in a local overlay so config.lua can still override them.
local M = {}

local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end

local presets = {
    deepseek = { base_url = "https://api.deepseek.com", model = "deepseek-flash" },
    openai = { base_url = "https://api.openai.com/v1", model = "" },
    anthropic = { base_url = "https://api.anthropic.com", model = "" },
    openai_compatible = { base_url = "", model = "" },
}

local order = { "deepseek", "openai", "anthropic", "openai_compatible" }

local function notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "todo.nvim AI" })
end

local function ask_key(callback)
    vim.fn.inputsave()
    local ok, key = pcall(vim.fn.inputsecret, L("AI API Key (hidden): ", "AI API Key（隐藏输入）："))
    vim.fn.inputrestore()
    if not ok or key == nil then
        callback(nil)
        return
    end
    callback(key)
end

function M.open(callback)
    callback = callback or function() end
    local config = require("todo.config")
    local cfg = config.get().ai
    if not cfg.enabled then
        vim.ui.select({
            L("Enable AI and configure a key", "启用 AI 并配置密钥"),
            L("Cancel", "取消"),
        }, { prompt = L("AI is disabled", "AI 尚未启用") }, function(choice, index)
            if index ~= 1 then
                callback(false)
                return
            end
            config.set_local_ai({ enabled = true })
            M.open(callback)
        end)
        return
    end
    local labels = {}
    local index_of = {}
    for index, provider in ipairs(order) do
        labels[index] = provider
        index_of[provider] = index
    end
    vim.ui.select(labels, {
        prompt = L("AI provider (current: ", "AI 供应商（当前：") .. (cfg.provider or "deepseek") .. ")",
        format_item = function(provider)
            return provider
        end,
    }, function(provider)
        if not provider then
            callback(false)
            return
        end
        local preset = presets[provider] or {}
        local default_base = cfg.provider == provider and cfg.base_url or preset.base_url
        local default_model = cfg.provider == provider and cfg.model or preset.model
        vim.ui.input({
            prompt = L("Base URL: ", "Base URL："),
            default = default_base or "",
        }, function(base_url)
            if not base_url or base_url == "" then
                callback(false)
                return
            end
            vim.ui.input({
                prompt = L("Model: ", "模型："),
                default = default_model or "",
            }, function(model)
                if not model or model == "" then
                    notify(L("Model is required", "必须填写模型"), vim.log.levels.ERROR)
                    callback(false)
                    return
                end
                ask_key(function(key)
                    if not key or key == "" then
                        local existing = require("todo.credentials").get()
                        if not existing then
                            notify(L("API key is required", "必须填写 API Key"), vim.log.levels.ERROR)
                            callback(false)
                            return
                        end
                    end
                    local ok, err = pcall(function()
                        config.set_local_ai({
                            enabled = true,
                            provider = provider,
                            base_url = base_url,
                            model = model,
                        })
                        if key and key ~= "" then
                            require("todo.credentials").set(key)
                        end
                        -- Re-validate the runtime configuration immediately.
                        config.setup({ ai = { enabled = true, provider = provider, base_url = base_url, model = model } })
                    end)
                    if not ok then
                        notify(tostring(err), vim.log.levels.ERROR)
                        callback(false)
                        return
                    end
                    notify(L("AI configured for this device", "AI 已在本机配置完成"))
                    callback(true)
                end)
            end)
        end)
    end)
end

--- Ensure a usable key before opening a planning UI.
function M.ensure(callback)
    callback = callback or function() end
    local cfg = require("todo.config").get().ai
    if cfg.enabled then
        local key = require("todo.credentials").get()
        if key then
            callback(true)
            return
        end
    end
    M.open(callback)
end

return M
