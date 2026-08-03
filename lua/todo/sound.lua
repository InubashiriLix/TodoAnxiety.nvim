local M = { warned = false }

local function fallback(message)
    vim.api.nvim_out_write("\7")
    if message and not M.warned then
        M.warned = true
        vim.notify(message, vim.log.levels.WARN, { title = "todo.nvim" })
    end
end

local function detected_command()
    for _, candidate in ipairs({
        { "mpv",    "--no-video", "--really-quiet" },
        { "ffplay", "-nodisp",    "-autoexit",     "-loglevel", "quiet" },
        { "paplay" },
        { "afplay" },
    }) do
        if vim.fn.executable(candidate[1]) == 1 then
            return candidate
        end
    end
end

function M.play(opts)
    opts = opts or {}
    local path = vim.fn.expand(opts.path or "")
    if path == "" then
        fallback()
        return false
    end
    if vim.fn.filereadable(path) ~= 1 then
        fallback("Reminder sound file is not readable: " .. path)
        return false
    end
    local command = opts.command ~= false and opts.command or detected_command()
    if not command then
        fallback("No supported reminder sound player was found")
        return false
    end
    local argv = vim.deepcopy(command)
    argv[#argv + 1] = path
    local ok, err = pcall(vim.system, argv, { detach = true }, function(result)
        if result.code ~= 0 and not M.warned then
            vim.schedule(function()
                fallback("Reminder sound player failed with exit code " .. result.code)
            end)
        end
    end)
    if not ok then
        fallback("Could not start reminder sound: " .. tostring(err))
        return false
    end
    return true
end

function M.reset_warning()
    M.warned = false
end

return M
