local config = require("todo.config")
local i18n = require("todo.i18n")

local M = {}
local store_instance
local service_instance
local scheduler_instance
local sync_handle
local cloud_stop
local ai_instance
local registered_maps = {}
local highlights_registered = false

local function close_store()
    if package.loaded["todo.ui.daily"] then
        package.loaded["todo.ui.daily"].close()
    end
    local planner_ui = package.loaded["todo.ui.planner"]
    if planner_ui then
        planner_ui.close()
    end
    local network_ui = package.loaded["todo.ui.network_progress"]
    if network_ui then
        network_ui.close()
    end
    if cloud_stop then
        cloud_stop()
        cloud_stop = nil
    end
    if ai_instance then
        for _, handle in pairs(ai_instance.active) do
            handle.cancel()
        end
        ai_instance = nil
    end
    if sync_handle then
        sync_handle.cancel()
        sync_handle = nil
    end
    local progress = package.loaded["todo.ui.sync_progress"]
    if progress then
        progress.close()
    end
    if scheduler_instance then
        pcall(function()
            scheduler_instance:stop()
        end)
        scheduler_instance = nil
    end
    if store_instance then
        pcall(function()
            store_instance:close()
        end)
    end
    local core = package.loaded["todo.core"]
    if core then
        pcall(core.stop)
    end
    store_instance, service_instance = nil, nil
end

local function start_scheduler()
    if not config.get().reminders.enabled then
        if scheduler_instance then
            scheduler_instance:stop()
            scheduler_instance = nil
        end
        return
    end
    if not scheduler_instance then
        scheduler_instance = require("todo.scheduler").new(M._service())
    end
    scheduler_instance:start()
end

local function map_is_ours(lhs)
    local mapping = vim.fn.maparg(lhs, "n", false, true)
    return type(mapping) == "table" and type(mapping.desc) == "string" and vim.startswith(mapping.desc, "todo.nvim:")
end

local function register_which_key(definitions)
    local ok, which_key = pcall(require, "which-key")
    if not ok or type(which_key.add) ~= "function" then
        return
    end
    local specs = {}
    for _, definition in ipairs(definitions) do
        local lhs, icon = definition[1], definition[4]
        if lhs ~= false and icon ~= false and icon ~= "" and map_is_ours(lhs) then
            local registered_lhs = lhs
            specs[#specs + 1] = {
                lhs,
                mode = "n",
                icon = icon,
                cond = function()
                    return map_is_ours(registered_lhs)
                end,
            }
        end
    end
    if #specs > 0 then
        which_key.add(specs)
    end
end

local function register_keymaps()
    for _, lhs in ipairs(registered_maps) do
        if map_is_ours(lhs) then
            pcall(vim.keymap.del, "n", lhs)
        end
    end
    registered_maps = {}
    local maps = config.get().keymaps
    local icons = config.get().icons or {}
    local definitions = {
        {
            maps.toggle,
            function()
                M.toggle()
            end,
            "toggle",
            icons.toggle or "",
        },
        {
            maps.add,
            function()
                M.add()
            end,
            "add task",
            icons.add or "",
        },
        {
            maps.open_float,
            function()
                M.open({ mode = "float" })
            end,
            "open float",
            icons.open_float or "",
        },
        {
            maps.open_sidebar,
            function()
                M.open({ mode = "sidebar" })
            end,
            "open sidebar",
            icons.open_sidebar or "",
        },
        {
            maps.open_emergency,
            function()
                M.open({ mode = "float", view = "emergency" })
            end,
            "open emergency",
            icons.open_emergency or "",
        },
        {
            maps.manage_tags,
            function()
                M.tags()
            end,
            "manage tags",
            icons.manage_tags or "",
        },
        {
            maps.add_notice,
            function()
                M.notice()
            end,
            "add notice",
            icons.add_notice or "",
        },
    }
    for _, definition in ipairs(definitions) do
        local lhs = definition[1]
        if lhs == false then
            goto continue
        end
        if vim.fn.maparg(lhs, "n") == "" then
            vim.keymap.set("n", lhs, definition[2], { silent = true, desc = "todo.nvim: " .. definition[3] })
            registered_maps[#registered_maps + 1] = lhs
        else
            vim.schedule(function()
                vim.notify(i18n.t("key_conflict", lhs), vim.log.levels.WARN, { title = "todo.nvim" })
            end)
        end
        ::continue::
    end
    register_which_key(definitions)
end

function M.setup(opts)
    local old_path = config.get().db_path
    local old_sync = vim.deepcopy(config.get().sync)
    local result = config.setup(opts)
    local core_ok, core_error = require("todo.core").start()
    assert(core_ok, core_error)
    if sync_handle and not vim.deep_equal(old_sync, result.sync) then
        sync_handle.cancel()
        sync_handle = nil
    end
    if old_path ~= result.db_path then
        close_store()
    end
    if cloud_stop then
        cloud_stop()
        cloud_stop = nil
    end
    if ai_instance then
        for _, handle in pairs(ai_instance.active) do
            handle.cancel()
        end
    end
    ai_instance = nil
    register_keymaps()
    if result.sync.enabled and result.sync.provider == "server" then
        vim.schedule(function()
            local workspace = require("todo.workspace").new(M._service().store)
            cloud_stop = require("todo.cloud").start_auto(workspace, result.sync, function()
                require("todo.ui.panel").refresh()
                M._reconcile_reminders()
            end)
        end)
    end
    if result.reminders.enabled then
        vim.schedule(start_scheduler)
    else
        start_scheduler()
    end
    return result
end

function M._bootstrap()
    require("todo.ui.highlights").setup()
    if not highlights_registered then
        highlights_registered = true
        local group = vim.api.nvim_create_augroup("TodoNvimHighlights", { clear = true })
        vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = close_store })
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = group,
            callback = function()
                require("todo.ui.highlights").setup()
            end,
        })
    end
    register_keymaps()
end

function M._service()
    if service_instance then
        return service_instance
    end
    local core_ok, core_error = require("todo.core").start()
    assert(core_ok, core_error)
    local Store = require("todo.store")
    store_instance = Store.open(config.get().db_path)
    require("todo.workspace").new(store_instance)
    service_instance = require("todo.service").new(store_instance)
    return service_instance
end

-- Rendering contextual hints must not open a database as a side effect.
function M._existing_service()
    return service_instance
end

function M._reschedule_reminders()
    start_scheduler()
end

function M._reconcile_reminders()
    if scheduler_instance then
        scheduler_instance:reconcile()
    end
    start_scheduler()
end

function M.sync()
    local sync_opts = config.get().sync
    if sync_opts.enabled and sync_opts.provider == "server" then
        sync_handle = require("todo.cloud").run(
            require("todo.workspace").new(M._service().store),
            sync_opts,
            function(err, result)
                sync_handle = nil
                if err then
                    vim.notify(err, vim.log.levels.ERROR)
                else
                    require("todo.ui.panel").refresh()
                    M._reconcile_reminders()
                    vim.notify("Sync complete · " .. result.pending .. " pending")
                end
            end
        )
        return
    end
    local progress = require("todo.ui.sync_progress")
    if sync_handle and sync_handle.running then
        progress.busy()
        return
    end
    local feedback = progress.start()
    local ok, err = pcall(function()
        local store = M._service().store
        local opts = vim.deepcopy(config.get().sync)
        opts.on_progress = function(event)
            feedback:update(event)
        end
        opts.on_import = function()
            require("todo.ui.panel").refresh()
            if scheduler_instance then
                scheduler_instance:reconcile()
            end
        end
        sync_handle = require("todo.sync").run(store, opts, function(failure, result)
            sync_handle = nil
            feedback:finish(failure, result)
        end)
    end)
    if not ok then
        feedback:finish(err)
    end
end

function M.sync_status()
    if config.get().sync.provider == "server" then
        local status = require("todo.workspace").new(M._service().store):cloud_status()
        vim.notify(vim.inspect(status), vim.log.levels.INFO, { title = "Todo server sync" })
        return status
    end
    local store = M._service().store
    local status = require("todo.sync.store").status(store)
    local success = status.last_success and os.date("%Y-%m-%d %H:%M:%S", status.last_success) or "—"
    vim.notify(
        i18n.t(
            "sync_status",
            config.get().sync.enabled and "on" or "off",
            success,
            status.pending,
            status.last_error or "",
            require("todo.sync").directory(store)
        ),
        vim.log.levels.INFO,
        { title = "todo.nvim" }
    )
    return status
end

function M._ai()
    if not ai_instance then
        ai_instance = require("todo.ai").new(require("todo.workspace").new(M._service().store), M._service())
    end
    return ai_instance
end
function M.today(date)
    local ws = require("todo.workspace").new(M._service().store)
    local planner = require("todo.planning").new(ws, M._service())
    date = date and date ~= "" and date or planner:date()
    assert(require("todo.model").parse_deadline(date), "invalid planning date")
    ws.store:set_setting("planning_view_date", date)
    M.open({ view = "today" })
end
function M.plan(opts)
    local result
    require("todo.ui.ai_setup").ensure(function(ok)
        if ok then
            result = require("todo.ui.daily").open(opts)
        end
    end)
    return result
end
function M.clarify(id)
    require("todo.ui.planner").sessions({ task_id = id })
end
function M.ai_usage()
    local u = M._ai():usage()
    vim.notify(
        string.format(
            "AI estimated: $%.6f · today $%.6f · %d requests · %d unknown costs",
            u.usd,
            u.today_usd,
            u.requests,
            u.unknown
        )
    )
    return u
end
function M.open(opts)
    require("todo.ui.panel").open(opts)
end

function M.toggle(opts)
    require("todo.ui.panel").toggle(opts)
end

function M.close()
    if package.loaded["todo.ui.daily"] then
        require("todo.ui.daily").close()
    end
    require("todo.ui.panel").close()
end

function M.tags()
    require("todo.ui.tag_panel").open({
        on_close = function()
            require("todo.ui.panel").refresh()
        end,
    })
end

function M.add(opts)
    opts = opts or {}
    local panel = require("todo.ui.panel")
    if panel.add(opts) then
        return
    end
    local last_interval = M._service():last_reminder_interval()
    require("todo.ui.form").open({
        title = opts.title or "",
        reminder = last_interval and { repeat_interval_seconds = last_interval } or nil,
    }, function(input, saved_task)
        local result, errors
        if saved_task and saved_task.id then
            result, errors = M._service():update(saved_task.id, input, saved_task.sync_revision)
        else
            result, errors = M._service():create(input)
        end
        if result then
            require("todo.ui.panel").refresh()
            start_scheduler()
        end
        return result, errors
    end)
end

function M.notice(opts)
    opts = opts or {}
    local panel = require("todo.ui.panel")
    if panel.add_notice(opts) then
        return
    end
    local default_interval = M._service():last_reminder_interval()
    require("todo.ui.notice_form").open({ title = opts.title or "" }, function(input)
        local result, errors = M._service():create(input)
        if result then
            panel.refresh()
            start_scheduler()
        end
        return result, errors
    end, {
        default_interval = default_interval and require("todo.duration").format(default_interval) or "",
    })
end

function M.edit(id)
    local panel = require("todo.ui.panel")
    if panel.edit(id) then
        return
    end
    local task = M._service().store:get(id)
    if not task then
        error(i18n.t("task_not_found", id))
    end
    local form_module = task.kind == "notice" and "todo.ui.notice_form" or "todo.ui.form"
    require(form_module).open(task, function(input)
        local result, errors = M._service():update(id, input, task.sync_revision)
        if result then
            task = result
            require("todo.ui.panel").refresh()
            start_scheduler()
        end
        return result, errors
    end)
end

function M.set_status(id, status)
    local result, errors = M._service():set_status(id, status)
    if not result then
        if errors and errors.id then
            error(i18n.t("task_not_found", id))
        end
        error("invalid status: " .. tostring(status))
    end
    require("todo.ui.panel").refresh()
    if scheduler_instance then
        scheduler_instance:reschedule()
    end
    return result
end

function M.archive(id)
    local result, errors = M._service():archive(id)
    if not result then
        error(errors and i18n.t("task_not_found", id) or "archive failed")
    end
    require("todo.ui.panel").refresh()
    if scheduler_instance then
        scheduler_instance:reschedule()
    end
    return result
end

function M.restore(id)
    local result, errors = M._service():restore(id)
    if not result then
        error(errors and i18n.t("task_not_found", id) or "restore failed")
    end
    require("todo.ui.panel").refresh()
    if scheduler_instance then
        scheduler_instance:reschedule()
    end
    return result
end

function M.delete(id)
    local result, errors = M._service():delete_archived(id)
    if not result then
        if errors and errors.id then
            error(i18n.t("task_not_found", id))
        elseif errors and errors.archived then
            error(i18n.t("delete_archived_only"))
        end
        error(i18n.t("delete_failed"))
    end
    require("todo.ui.panel").refresh()
    return result
end

function M._reset_for_tests()
    close_store()
end

return M
