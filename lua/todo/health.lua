local M = {}

function M.check()
    vim.health.start("todo.nvim")

    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim 0.10+ detected")
    else
        vim.health.error("todo.nvim requires Neovim 0.10 or newer")
    end

    local ok, sqlite = pcall(require, "sqlite.db")
    if ok then
        vim.health.ok("kkharji/sqlite.lua is available")
    else
        vim.health.error("kkharji/sqlite.lua is missing", {
            "Install https://github.com/kkharji/sqlite.lua with your plugin manager",
            tostring(sqlite),
        })
    end

    local nui_ok, nui = pcall(require, "nui.popup")
    if nui_ok then
        vim.health.ok("MunifTanjim/nui.nvim is available")
    else
        vim.health.error("MunifTanjim/nui.nvim is missing", {
            "Install https://github.com/MunifTanjim/nui.nvim with your plugin manager",
            tostring(nui),
        })
    end

    local cfg_ok, cfg = pcall(function()
        return require("todo.config").get()
    end)
    if not cfg_ok then
        vim.health.error("Configuration is invalid: " .. tostring(cfg))
        return
    end

    local parent = vim.fs.dirname(cfg.db_path)
    if vim.fn.isdirectory(parent) == 1 then
        if vim.fn.filewritable(parent) == 2 then
            vim.health.ok("Database directory is writable: " .. parent)
        else
            vim.health.error("Database directory is not writable: " .. parent)
        end
    else
        local ancestor = vim.fs.dirname(parent)
        if vim.fn.filewritable(ancestor) == 2 then
            vim.health.ok("Database directory can be created: " .. parent)
        else
            vim.health.warn("Could not confirm database directory is writable: " .. parent)
        end
    end

    if ok then
        local opened, err = pcall(function()
            local db = sqlite:open(":memory:")
            db:eval("SELECT sqlite_version() AS version")
            db:close()
        end)
        if opened then
            vim.health.ok("SQLite dynamic library can be loaded")
        else
            vim.health.error("SQLite dynamic library could not be loaded", { tostring(err) })
        end
    end

    if cfg.reminders.enabled then
        local sound = cfg.reminders.sound
        local path = vim.fn.expand(sound.path)
        if path == "" then
            vim.health.warn("Reminder sound path is empty; reminders will use the terminal bell")
        elseif vim.fn.filereadable(path) == 1 then
            vim.health.ok("Reminder sound file is readable: " .. path)
        else
            vim.health.error("Reminder sound file is not readable: " .. path)
        end
        if sound.command == false then
            vim.health.info("Reminder player will be auto-detected")
        elseif vim.fn.executable(sound.command[1]) == 1 then
            vim.health.ok("Reminder sound player is executable: " .. sound.command[1])
        else
            vim.health.error("Reminder sound player is not executable: " .. sound.command[1])
        end
    else
        vim.health.info("Reminder scheduler is disabled")
    end

    vim.health.start("todo.nvim sync (local checks only)")
    if not cfg.sync.enabled then
        vim.health.info("Git sync is disabled")
    elseif cfg.sync.provider == "server" then
        if vim.fn.executable("curl") == 1 then
            vim.health.ok("curl is available for asynchronous server sync")
        else
            vim.health.error("curl is required for server sync")
        end
        local configured, token = pcall(require("todo.secrets").sync, cfg.sync)
        if configured and token then
            vim.health.ok("Sync token configured")
        else
            vim.health.error("Sync token missing or invalid; configure sync.token_file, sync.token or sync.token_env")
        end
        if cfg.sync.url:match("^http://") then
            vim.health.warn("HTTP does not encrypt tasks or tokens; enable allow_http explicitly")
        end
        if not cfg.sync.tls_verify then
            vim.health.warn("Certificate verification is disabled for this sync endpoint")
        end
        vim.health.info("Server is checked only during sync; :Todo diagnostics shows network failures")
    else
        if vim.fn.executable("git") == 1 then
            vim.health.ok("Git is available; authentication is checked only by :Todo sync")
        else
            vim.health.error("Git is required for sync")
        end
        if cfg.sync.remote ~= "" then
            vim.health.ok("Sync remote configured, branch: " .. cfg.sync.branch)
        else
            vim.health.error("sync.remote is required")
        end
        local directory = require("todo.sync").directory({ path = cfg.db_path })
        local ancestor = directory
        while vim.fn.isdirectory(ancestor) == 0 and vim.fs.dirname(ancestor) ~= ancestor do
            ancestor = vim.fs.dirname(ancestor)
        end
        if vim.fn.filewritable(ancestor) == 2 then
            vim.health.ok("Sync directory is writable or can be created: " .. directory)
        else
            vim.health.error("Sync directory is not writable: " .. directory)
        end
    end

    vim.health.start("todo.nvim AI and attachments (local checks only)")
    local core = require("todo.core")
    pcall(core.start)
    local core_ok, core_status = pcall(core.status)
    if core_ok and core_status.running then
        vim.health.ok(
            "Rust core "
                .. tostring(core_status.info and core_status.info.version or "?")
                .. " (protocol "
                .. tostring(core_status.info and core_status.info.protocol or "?")
                .. ")"
        )
    else
        vim.health.error(
            "Rust core is not running: "
                .. tostring(core.binary() or "binary not found")
                .. "; build core/ or set core.bin"
        )
    end
    if cfg.ai.enabled then
        if vim.fn.executable("curl") == 1 then
            vim.health.ok("curl is available for asynchronous AI requests")
        else
            vim.health.error("curl is required for AI")
        end
        vim.health.info("Permission mode: " .. cfg.ai.mode .. "; scopes and approvals are device-local")
        if vim.fn.executable("bwrap") == 1 then
            vim.health.ok("bubblewrap found; command tools fail closed if the OS blocks sandbox creation")
        else
            vim.health.info(
                "Sandbox commands unavailable: install bubblewrap on Linux; file/web tools remain available"
            )
        end
        if vim.fn.executable("rg") == 1 then
            vim.health.ok("ripgrep is available for bounded text search")
        else
            vim.health.info("Local text search needs ripgrep (rg)")
        end
        local valid, key, source = pcall(require("todo.credentials").get)
        if valid and key then
            vim.health.ok("AI key configured: " .. source)
        else
            vim.health.warn("AI key missing; run :Todo ai setup")
        end
        vim.health.info(
            "Question limit "
                .. cfg.ai.max_questions
                .. ", request limit "
                .. cfg.ai.max_requests
                .. "; charges are estimates"
        )
    else
        vim.health.info("AI is disabled; local Today planning remains available")
    end
    if vim.fn.executable("wl-paste") == 1 or vim.fn.executable("xclip") == 1 or cfg.attachments.clipboard_command then
        vim.health.ok("An image clipboard provider is available")
    else
        vim.health.info("Image clipboard unavailable; use file import")
    end
    local image_ok = pcall(require, "image")
    vim.health.info(
        image_ok and "image.nvim is available for inline images"
            or "Inline images optional: install image.nvim, or use gx to open images"
    )

    for name, lhs in pairs(cfg.keymaps) do
        if lhs == false then
            goto continue
        end
        local mapping = vim.fn.maparg(lhs, "n", false, true)
        if mapping.lhs then
            if type(mapping.desc) == "string" and vim.startswith(mapping.desc, "todo.nvim:") then
                vim.health.ok("Default mapping active: " .. lhs)
            else
                vim.health.warn("Default mapping conflicts with an existing mapping: " .. lhs)
            end
        end
        ::continue::
    end
end

return M
