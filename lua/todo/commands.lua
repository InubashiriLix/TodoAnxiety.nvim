local M = {}

local actions = {
    start = "in_progress",
    done = "done",
    cancel = "cancelled",
    reopen = "todo",
}

local function split_words(value)
    return vim.split(vim.trim(value or ""), "%s+", { trimempty = true })
end

local function resolve_id(raw)
    if raw and raw ~= "" then
        local id = tonumber(raw)
        if not id or id < 1 or id % 1 ~= 0 then
            error("task ID must be a number")
        end
        return id
    end
    local task = require("todo.ui.panel").current_task()
    if not task then
        error(require("todo.i18n").t("missing_task"))
    end
    return task.id
end

local function notify_error(err)
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = "todo.nvim" })
end

function M.run(args)
    local command, rest = (args or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command ~= "" and command or "open"
    local todo = require("todo")
    local ok, err = pcall(function()
        if command == "open" then
            local words = split_words(rest)
            local mode, view
            for _, word in ipairs(words) do
                if word == "float" or word == "sidebar" then
                    mode = word
                end
                if require("todo.ui.grouping").is_view(word) then
                    view = word
                end
            end
            todo.open({ mode = mode, view = view })
        elseif command == "toggle" then
            local words = split_words(rest)
            todo.toggle({ mode = words[1] })
        elseif command == "add" then
            todo.add({ title = rest })
        elseif command == "image" then
            local buf = vim.api.nvim_get_current_buf()
            assert(
                vim.bo[buf].modifiable and vim.bo[buf].filetype == "markdown",
                "Open a task description or AI answer editor first"
            )
            local asset = require("todo.assets").import(rest, { store = todo._service().store })
            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = vim.api.nvim_get_current_line()
            local col = math.min(cursor[2], #line)
            vim.api.nvim_buf_set_text(buf, cursor[1] - 1, col, cursor[1] - 1, col, { asset.markdown })
        elseif command == "diagnostics" then
            require("todo.diagnostics").open()
        elseif command == "today" then
            todo.today(rest)
        elseif command == "plan" then
            todo.plan(rest ~= "" and { date = rest } or nil)
        elseif command == "clarify" then
            todo.clarify(resolve_id(rest))
        elseif command == "ai" then
            if rest == "memory" then
                require("todo.ui.planner").memory()
            elseif rest == "setup" then
                require("todo.ui.ai_setup").open()
            elseif rest == "key" then
                require("todo.credentials").prompt()
            elseif rest == "settings" then
                require("todo.ui.planner").settings()
            elseif rest == "usage" then
                todo.ai_usage()
            elseif rest == "balance" then
                require("todo.ui.planner").balance()
            else
                error("usage: Todo ai settings|key|usage|balance|memory")
            end
        elseif command == "notice" then
            todo.notice({ title = rest })
        elseif command == "tags" then
            todo.tags()
        elseif command == "sync" then
            if rest == "conflicts" then
                require("todo.ui.planner").conflicts()
            elseif rest == "status" then
                todo.sync_status()
            elseif rest == "" then
                todo.sync()
            else
                error("usage: Todo sync [status]")
            end
        elseif command == "edit" then
            todo.edit(resolve_id(rest))
        elseif actions[command] then
            todo.set_status(resolve_id(rest), actions[command])
        elseif command == "archive" then
            todo.archive(resolve_id(rest))
        elseif command == "restore" then
            todo.restore(resolve_id(rest))
        elseif command == "delete" then
            todo.delete(resolve_id(rest))
        elseif command == "close" then
            todo.close()
        else
            error("unknown Todo subcommand: " .. command)
        end
    end)
    if not ok then
        notify_error(err)
    end
end

function M.complete(arglead, cmdline)
    local input = cmdline:gsub("^%s*", "")
    if input:sub(1, 1) == ":" then
        input = input:sub(2):gsub("^%s*", "")
    end
    local after_todo = input:match("^Todo!?%s*(.*)$") or ""
    local command = after_todo:match("^(%S+)%s+")
    if not command then
        local commands = {
            "today",
            "plan",
            "clarify",
            "ai",
            "diagnostics",
            "image",
            "open",
            "toggle",
            "add",
            "notice",
            "tags",
            "sync",
            "edit",
            "start",
            "done",
            "cancel",
            "reopen",
            "archive",
            "restore",
            "delete",
            "close",
        }
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, commands)
    end
    if command == "image" then
        return vim.fn.getcompletion(arglead, "file")
    end
    if command == "open" then
        local options = { "float", "sidebar" }
        vim.list_extend(options, require("todo.ui.grouping").views)
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, options)
    elseif command == "sync" then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, { "status", "conflicts" })
    elseif command == "ai" then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, { "setup", "settings", "key", "usage", "balance", "memory" })
    elseif command == "toggle" then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, { "float", "sidebar" })
    end
    return {}
end

return M
