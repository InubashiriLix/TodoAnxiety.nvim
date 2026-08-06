local config = require("todo.config")
local highlights = require("todo.ui.highlights")
local i18n = require("todo.i18n")
local viewmodel = require("todo.ui.viewmodel")

local Input = require("nui.input")
local Menu = require("nui.menu")
local Popup = require("nui.popup")

local M = {}
local current
local ns = vim.api.nvim_create_namespace("todo_tag_panel")

local function service()
    return require("todo")._service()
end

local function set_lines(component, lines)
    if not component or not vim.api.nvim_buf_is_valid(component.bufnr) then
        return
    end
    vim.bo[component.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false, lines)
    vim.bo[component.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(component.bufnr, ns, 0, -1)
end

local function selected_names(owner)
    local names = {}
    for _, item in ipairs(owner.tags) do
        if owner.selected[item.name:lower()] then
            names[#names + 1] = item.name
        end
    end
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    return names
end

local function close_transient(owner)
    if owner.transient then
        pcall(function()
            owner.transient:unmount()
        end)
        owner.transient = nil
    end
end

local function refresh_tags(owner)
    local existing = {}
    owner.tags = owner.service:tag_stats()
    for _, item in ipairs(owner.tags) do
        existing[item.name:lower()] = true
    end
    for key, name in pairs(owner.selected) do
        if name and not existing[key] then
            owner.tags[#owner.tags + 1] = { name = name, task_count = 0 }
        end
    end
    table.sort(owner.tags, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
end

local function visible_tags(owner)
    if owner.filter == "" then
        return owner.tags
    end
    local needle = owner.filter:lower()
    return vim.tbl_filter(function(item)
        return item.name:lower():find(needle, 1, true) ~= nil
    end, owner.tags)
end

local render

local function notify_change(owner)
    if owner.on_change then
        owner.on_change(selected_names(owner))
    end
end

local function toggle_current(owner)
    local item = owner.visible[owner.cursor]
    if not item then
        return
    end
    local key = item.name:lower()
    if owner.selected[key] then
        owner.selected[key] = nil
    else
        owner.selected[key] = item.name
    end
    notify_change(owner)
    render(owner)
end

local function select_delta(owner, delta)
    if #owner.visible == 0 then
        return
    end
    owner.cursor = math.max(1, math.min(#owner.visible, owner.cursor + delta))
    render(owner)
end

local function input_dialog(owner, title, default_value, on_submit)
    close_transient(owner)
    local component = Input({
        relative = "editor",
        position = "50%",
        size = { width = math.max(24, math.min(52, vim.o.columns - 8)) },
        border = {
            style = config.get().ui.float.border,
            text = { top = " " .. title .. " ", top_align = "center" },
        },
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
        zindex = 110,
    }, {
        default_value = default_value or "",
        on_submit = function(value)
            owner.transient = nil
            on_submit(value)
        end,
        on_close = function()
            owner.transient = nil
        end,
    })
    owner.transient = component
    component:mount()
    local close_input = function()
        component:unmount()
        owner.transient = nil
        if owner.popup.winid and vim.api.nvim_win_is_valid(owner.popup.winid) then
            vim.api.nvim_set_current_win(owner.popup.winid)
        end
    end
    vim.keymap.set({ "n", "i" }, "<C-q>", close_input, { buffer = component.bufnr, silent = true })
    vim.keymap.set("n", "q", close_input, { buffer = component.bufnr, silent = true })
    vim.keymap.set("n", "<Esc>", close_input, { buffer = component.bufnr, silent = true })
    vim.keymap.set("i", "<Esc>", function()
        vim.schedule(close_input)
    end, { buffer = component.bufnr, silent = true })
end

local function create_tag(owner)
    input_dialog(owner, i18n.t("tag_create"), owner.filter, function(value)
        local name, errors = owner.service:create_tag(value)
        if not name then
            vim.notify(i18n.t("tag_invalid"), vim.log.levels.ERROR)
            return errors
        end
        if owner.select_mode then
            owner.selected[name:lower()] = name
            notify_change(owner)
        end
        owner.filter = ""
        refresh_tags(owner)
        render(owner)
    end)
end

local function rename_tag(owner)
    local item = owner.visible[owner.cursor]
    if not item then
        return
    end
    input_dialog(owner, i18n.t("tag_rename"), item.name, function(value)
        local renamed = owner.service:rename_tag(item.name, value)
        if not renamed then
            vim.notify(i18n.t("tag_invalid"), vim.log.levels.ERROR)
            return
        end
        local was_selected = owner.selected[item.name:lower()] ~= nil
        owner.selected[item.name:lower()] = nil
        if was_selected then
            owner.selected[renamed:lower()] = renamed
            notify_change(owner)
        end
        refresh_tags(owner)
        render(owner)
    end)
end

local function delete_tag(owner)
    local item = owner.visible[owner.cursor]
    if not item then
        return
    end
    close_transient(owner)
    local menu = Menu({
        relative = "editor",
        position = "50%",
        border = {
            style = config.get().ui.float.border,
            text = { top = " " .. i18n.t("tag_delete_title") .. " ", top_align = "center" },
        },
        win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder,CursorLine:TodoSelected" },
        zindex = 110,
    }, {
        lines = {
            Menu.item(i18n.t("tag_delete_confirm", item.name, item.task_count), { value = true }),
            Menu.item(i18n.t("cancel"), { value = false }),
        },
        min_width = 34,
        on_submit = function(choice)
            owner.transient = nil
            if choice.value then
                owner.service:delete_tag(item.name)
                owner.selected[item.name:lower()] = nil
                notify_change(owner)
                refresh_tags(owner)
                owner.cursor = math.max(1, math.min(owner.cursor, #owner.tags))
                render(owner)
            end
        end,
        on_close = function()
            owner.transient = nil
        end,
    })
    owner.transient = menu
    menu:mount()
    local close_menu = function()
        menu:unmount()
        owner.transient = nil
        if owner.popup.winid and vim.api.nvim_win_is_valid(owner.popup.winid) then
            vim.api.nvim_set_current_win(owner.popup.winid)
        end
    end
    vim.keymap.set("n", "q", close_menu, { buffer = menu.bufnr, silent = true })
    vim.keymap.set("n", "<Esc>", close_menu, { buffer = menu.bufnr, silent = true })
    vim.keymap.set("n", "<C-q>", close_menu, { buffer = menu.bufnr, silent = true })
end

local function filter_tags(owner)
    input_dialog(owner, i18n.t("tag_filter"), owner.filter, function(value)
        owner.filter = vim.trim(value)
        owner.cursor = 1
        render(owner)
    end)
end

render = function(owner)
    if owner.closed or not owner.popup.winid or not vim.api.nvim_win_is_valid(owner.popup.winid) then
        return
    end
    owner.visible = visible_tags(owner)
    owner.cursor = math.max(1, math.min(owner.cursor, math.max(1, #owner.visible)))
    local width = vim.api.nvim_win_get_width(owner.popup.winid)
    local lines = {
        viewmodel.truncate(
            "  " .. i18n.t(owner.select_mode and "tag_panel_select_help" or "tag_panel_manage_help"),
            width
        ),
        owner.filter ~= "" and viewmodel.truncate("  / " .. owner.filter, width) or "",
        "",
    }
    owner.line_tags = {}
    for index, item in ipairs(owner.visible) do
        local checked = owner.select_mode and (owner.selected[item.name:lower()] and "●" or "○") or "•"
        local cursor = index == owner.cursor and "›" or " "
        local count = i18n.t("tag_task_count", item.task_count)
        local prefix = string.format(" %s %s  #", cursor, checked)
        local max_name_width = math.max(4, width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(count) - 2)
        local line = prefix .. viewmodel.truncate(item.name, max_name_width)
        local padding = math.max(1, width - vim.fn.strdisplaywidth(line) - vim.fn.strdisplaywidth(count))
        lines[#lines + 1] = line .. string.rep(" ", padding) .. count
        owner.line_tags[#lines] = item
    end
    if #owner.visible == 0 then
        lines[#lines + 1] = "  " .. i18n.t("no_tags")
    end
    lines[#lines + 1] = ""
    for _, items in ipairs({
        {
            { key = "a", label = i18n.t("action_add") },
            { key = "r", label = i18n.t("action_rename") },
            { key = "d", label = i18n.t("action_delete") },
        },
        {
            { key = "/", label = i18n.t("filter") },
            { key = "q", label = i18n.t("action_complete") },
        },
    }) do
        local footer = " "
        for _, item in ipairs(items) do
            local text = string.format("[%s %s] ", item.key, item.label)
            footer = footer .. text
        end
        lines[#lines + 1] = viewmodel.truncate(footer, width)
    end
    set_lines(owner.popup, lines)
    for line, item in pairs(owner.line_tags) do
        local text = lines[line]
        vim.api.nvim_buf_set_extmark(owner.popup.bufnr, ns, line - 1, 0, {
            end_col = #text,
            hl_group = item == owner.visible[owner.cursor] and "TodoSelected" or highlights.tag(item.name),
            hl_eol = item == owner.visible[owner.cursor],
        })
    end
    pcall(vim.api.nvim_win_set_cursor, owner.popup.winid, { 3 + owner.cursor, 0 })
end

function M.open(opts)
    opts = opts or {}
    if current then
        M.close()
    end
    highlights.setup()
    local owner = {
        service = opts.service or service(),
        select_mode = opts.on_change ~= nil,
        on_change = opts.on_change,
        on_close = opts.on_close,
        selected = {},
        filter = opts.filter or "",
        cursor = 1,
        tags = {},
        visible = {},
        line_tags = {},
        transient = nil,
        closed = false,
    }
    for _, name in ipairs(opts.selected or {}) do
        owner.selected[name:lower()] = name
    end
    refresh_tags(owner)
    owner.popup = Popup({
        relative = "editor",
        position = "50%",
        size = {
            width = math.max(30, math.min(54, vim.o.columns - 6)),
            height = math.max(10, math.min(20, vim.o.lines - 6)),
        },
        enter = true,
        border = {
            style = config.get().ui.float.border,
            text = { top = " " .. i18n.t(opts.title or "tag_manager") .. " ", top_align = "center" },
        },
        buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false, modifiable = false },
        win_options = {
            wrap = false,
            cursorline = false,
            winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder",
        },
        zindex = 100,
    })
    current = owner
    owner.popup:mount()
    render(owner)
    owner.toggle_current = function()
        toggle_current(owner)
    end
    local map = function(key, callback)
        vim.keymap.set("n", key, callback, { buffer = owner.popup.bufnr, silent = true })
    end
    map("j", function()
        select_delta(owner, 1)
    end)
    map("k", function()
        select_delta(owner, -1)
    end)
    map("<Down>", function()
        select_delta(owner, 1)
    end)
    map("<Up>", function()
        select_delta(owner, -1)
    end)
    if owner.select_mode then
        map("<CR>", function()
            owner.toggle_current()
        end)
        map("<Space>", function()
            owner.toggle_current()
        end)
    end
    map("a", function()
        create_tag(owner)
    end)
    map("r", function()
        rename_tag(owner)
    end)
    map("d", function()
        delete_tag(owner)
    end)
    map("/", function()
        filter_tags(owner)
    end)
    map("q", M.close)
    map("<Esc>", M.close)
    map("<C-q>", M.close)
    return owner
end

function M.close()
    local owner = current
    if not owner then
        return
    end
    owner.closed = true
    close_transient(owner)
    if owner.popup then
        pcall(function()
            owner.popup:unmount()
        end)
    end
    current = nil
    if owner.on_close then
        vim.schedule(function()
            owner.on_close(selected_names(owner))
        end)
    end
end

function M.is_open()
    return current ~= nil and not current.closed
end

function M.inspect_state()
    return current
end

return M
