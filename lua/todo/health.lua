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
