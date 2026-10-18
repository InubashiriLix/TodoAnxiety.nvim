local M = {}
local Popup = require("nui.popup")
local Layout = require("nui.layout")
local view = require("todo.ui.daily_view")
local keys = require("todo.ui.daily_keys")
local current
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
local function write(pop, lines, width)
    if not pop or not vim.api.nvim_buf_is_valid(pop.bufnr) then
        return
    end
    if width then
        lines = vim.tbl_map(function(line)
            return require("todo.ui.viewmodel").truncate(line, width)
        end, lines)
    end
    return require("todo.ui.surface").write(pop.bufnr, lines)
end
local function valid(pop)
    return pop and pop.winid and vim.api.nvim_win_is_valid(pop.winid)
end
local function popup(editable, focusable)
    return Popup({
        enter = false,
        focusable = focusable ~= false,
        border = { style = focusable == false and "none" or "rounded" },
        buf_options = { buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = editable == true },
        win_options = {
            wrap = true,
            number = false,
            relativenumber = false,
            signcolumn = "no",
            cursorline = false,
            scrolloff = 0,
            winhighlight = "Normal:"
                .. (editable and "TodoDailyPanel" or "TodoDailySurface")
                .. ",FloatBorder:TodoDailyRule,FloatTitle:TodoDailyMuted,CursorLine:TodoDailySelected",
        },
    })
end
function M.open(opts)
    opts = opts or {}
    if current then
        current.close()
    end
    require("todo.ui.planner").close()
    require("todo.ui.panel").close()
    vim.cmd("stopinsert")
    require("todo.ui.highlights").setup()
    view.theme()
    local todo = require("todo")
    local svc = todo._service()
    local ws = require("todo.workspace").new(svc.store)
    local ctl = require("todo.ai.daily").new(ws, svc, todo._ai(), opts.date, opts)
    local snapshot = require("todo.ui.snapshot").new(svc)
    local owner = {
        controller = ctl,
        origin = opts.view or ctl.origin,
        closed = false,
        composers = {},
        sent_text = {},
        contexts = {},
        selection = 1,
        option = 1,
        tab = 1,
        composing_key = nil,
        queue_open = false,
        option_positions = {},
        follow_reply = true,
        awaiting = false,
        chat_mode = false,
        show_composer = false,
    }
    current = owner
    owner.header = popup(false, false)
    owner.timeline = popup()
    owner.questions = popup()
    owner.footer = popup(false, false)
    owner.popup = owner.timeline
    require("todo.ui.markdown").attach(owner.timeline.bufnr)
    local ns = vim.api.nvim_create_namespace("TodoDaily")
    local spinner_ns = vim.api.nvim_create_namespace("TodoDailySpinner")
    local rendering = false
    local pending = false
    local requested, rendered = 0, 0
    local cache_pending = false
    local layout_signature
    local render, reflow, submit, focus_input, edit_task, help, focus_pane, return_to_choices, bind_panes
    local function safe(fn)
        return function(...)
            local args = { ... }
            local ok, err = xpcall(function()
                fn(unpack(args))
            end, debug.traceback)
            if not ok then
                ctl.state.last_error = tostring(err):match("^[^\n]+")
                ctl:emit()
                require("todo.diagnostics").record({
                    operation = "Daily planning",
                    stage = "action",
                    error = tostring(err),
                })
            end
        end
    end
    local function map(pop, key, fn)
        vim.keymap.set("n", key, safe(fn), { buffer = pop.bufnr, silent = true, nowait = key ~= "g" })
    end
    local function action(pop, name, fn, modes)
        keys.bind(pop.bufnr, name, safe(fn), modes)
    end
    local function buffer_text(pop)
        return table.concat(vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false), "\n")
    end
    local function is_editing()
        if not owner.composer then
            return false
        end
        local mode = vim.api.nvim_get_mode().mode
        return buffer_text(owner.composer) ~= (owner.sent_text[owner.composing_key] or "")
            or vim.api.nvim_get_current_buf() == owner.composer.bufnr
                and (mode:sub(1, 1) == "i" or mode:match("^[vV\22]"))
    end
    ctl.can_advance = function()
        return not is_editing()
    end
    local function cache_later()
        if cache_pending then
            return
        end
        cache_pending = true
        vim.defer_fn(function()
            cache_pending = false
            if not owner.closed then
                ctl:save_cache()
            end
        end, 500)
    end
    local function round_for(entry)
        local s = entry and snapshot.ws:get("conversation", ctl:item_id(entry))
        if
            not s
            or not s.round
            or (s.round.status ~= "pending" and not (s.status == "error" and s.round.status == "submitted"))
        then
            return nil, s
        end
        ctl.cache.rounds = ctl.cache.rounds or {}
        local round = ctl.cache.rounds[s.id]
        if not round or round.id ~= s.round.id then
            round = vim.deepcopy(s.round)
            round.status = "pending"
            ctl.cache.rounds[s.id] = round
        end
        return round, s
    end
    local function answer(round, q)
        round.answers[q.id] = round.answers[q.id] or { selected = {}, notes = {} }
        return round.answers[q.id]
    end
    local function save_draft(pop, ctx)
        local value = buffer_text(pop)
        ctl.cache.drafts = ctl.cache.drafts or {}
        ctl.cache.drafts[ctx.key] = value
        if ctx.round and ctx.question then
            local a = answer(ctx.round, ctx.question)
            if ctx.option then
                a.notes[ctx.option.id] = value
            else
                a.custom = value
            end
        elseif ctx.key == "intent" then
            ctl.state.intent = value
        end
        cache_later()
    end
    local function create_composer(ctx)
        if owner.composers[ctx.key] then
            return owner.composers[ctx.key]
        end
        local pop = popup(true)
        owner.composers[ctx.key] = pop
        owner.contexts[ctx.key] = ctx
        local value = ctl.cache.drafts and ctl.cache.drafts[ctx.key] or (ctx.key == "intent" and ctl.state.intent) or ""
        if ctx.round and ctx.question then
            local a = answer(ctx.round, ctx.question)
            value = ctx.option and a.notes[ctx.option.id] or a.custom or ""
        end
        vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, vim.split(value, "\n", { plain = true }))
        vim.bo[pop.bufnr].filetype = "markdown"
        vim.b[pop.bufnr].todo_daily_editor = true
        vim.api.nvim_buf_attach(pop.bufnr, false, {
            on_lines = function()
                if not owner.closed then
                    save_draft(pop, ctx)
                end
            end,
        })
        require("todo.assets").attach(pop.bufnr, svc.store, { paste_modes = { "i" } })
        require("todo.ui.markdown").attach(pop.bufnr)
        local function close()
            owner.close()
        end
        for key, fn in pairs({
            ["<C-q>"] = close,
            ["<C-c>"] = function()
                ctl:pause()
            end,
        }) do
            local plug = key == "<C-c>" and "<Plug>(TodoDailyStop)" or "<Plug>(TodoDailyClose)"
            map(pop, plug, fn)
            map(pop, key, fn)
            vim.keymap.set({ "i", "x" }, key, "<Esc>" .. plug, { buffer = pop.bufnr, silent = true })
        end
        action(pop, "return_to_choices", function()
            return_to_choices()
        end)
        -- OpenCode-style composer: Enter submits/saves and returns to choices;
        -- Shift-Enter / Ctrl-J inserts a newline.
        vim.keymap.set("i", "<CR>", function()
            vim.cmd("stopinsert")
            return_to_choices()
        end, { buffer = pop.bufnr, silent = true })
        vim.keymap.set("i", "<Tab>", function()
            vim.cmd("stopinsert")
            return_to_choices()
        end, { buffer = pop.bufnr, silent = true })
        vim.keymap.set({ "i" }, "<C-J>", "<CR>", { buffer = pop.bufnr, silent = true })
        vim.keymap.set({ "i" }, "<S-CR>", "<CR>", { buffer = pop.bufnr, silent = true })
        map(pop, "<localleader>q", function()
            return_to_choices()
        end)
        map(pop, "<F1>", function()
            help()
        end)
        vim.keymap.set("i", "<F1>", "<Esc><F1>", { buffer = pop.bufnr, silent = true })
        local image_key = require("todo.config").get().ai.planning.image_paste_key or "<localleader>p"
        map(pop, image_key, function()
            require("todo.assets").paste({ store = svc.store }, function(err, asset)
                if owner.closed or not vim.api.nvim_buf_is_valid(pop.bufnr) then
                    return
                end
                if err then
                    ctl.state.last_error = err
                    ctl:emit()
                    return
                end
                local pos = valid(pop) and vim.api.nvim_win_get_cursor(pop.winid) or { 1, 0 }
                vim.api.nvim_buf_set_text(pop.bufnr, pos[1] - 1, pos[2], pos[1] - 1, pos[2], { asset.markdown })
            end)
        end)
        pop.editor = require("todo.ui.editor_commands").attach(pop, {
            persistent = true,
            layout = function()
                return owner.layout
            end,
            save = function()
                save_draft(pop, ctx)
                ctl:save_cache()
                return true
            end,
            close = function()
                return_to_choices()
            end,
            rollback = function(value)
                -- Autosaved crash-recovery drafts are distinct from the explicit :w baseline.
                vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, vim.split(value, "\n", { plain = true }))
                save_draft(pop, ctx)
                ctl:save_cache()
            end,
        })
        if bind_panes then
            bind_panes(pop)
        end
        return pop
    end
    local function context()
        if ctl.state.status == "preparing" then
            return { key = "intent", label = L("Today’s intentions", "今日补充说明") }
        end
        local entry = ctl:current()
        if not entry then
            return { key = "general", label = L("Planning feedback", "规划说明") }
        end
        if owner.chat_mode then
            return { key = "chat:" .. entry.uuid, label = L("Message AI", "给 AI 发消息"), entry = entry }
        end
        local round = round_for(entry)
        if round then
            owner.tab = math.max(1, math.min(owner.tab, #round.questions + 1))
            local q = round.questions[owner.tab]
            if q then
                local option = owner.note_option and q.options[owner.note_option]
                return {
                    key = entry.uuid .. ":" .. round.id .. ":" .. q.id .. ":" .. (option and option.id or "custom"),
                    label = q.header
                        .. " · "
                        .. (
                            option and L("Option note: ", "选项说明：") .. option.label
                            or L("Add detail · keeps your selection", "补充说明 · 保留已选项")
                        ),
                    entry = entry,
                    round = round,
                    question = q,
                    option = option,
                }
            end
        end
        return { key = "task:" .. entry.uuid, label = entry.title, entry = entry, round = round }
    end
    local function select_context(force)
        local ctx = context()
        -- Tab navigation must never create editors or invoke Markdown/FileType plugins.
        if owner.composer and not force then
            return
        end
        owner.composing_key = ctx.key
        owner.composer = create_composer(ctx)
    end
    select_context(true)
    local function geometry()
        local size = require("todo.ui.responsive").size(
            owner.maximized and vim.o.columns or 136,
            owner.maximized and vim.o.lines or 54
        )
        -- Keep one content row plus its frame on very short terminals.
        size.height = math.max(math.min(3, vim.o.lines - 2), size.height)
        local small = size.width < 40 or size.height < 10
        local entry = ctl:current()
        local round = round_for(entry)
        local has_questions = ctl.permission ~= nil
            or owner.mode_picker
            or ctl.state.status == "preparing"
            or owner.queue_open
            or (round ~= nil and not ctl.busy and not owner.awaiting)
        local boxes = {}
        owner.small = small
        if small or owner.maximized then
            local name = owner.maximized or owner.tiny_view or (has_questions and "questions" or "timeline")
            local main = owner[name] or owner.timeline
            boxes = { Layout.Box(main, { grow = 1 }) }
            if size.height >= 6 then
                boxes[#boxes + 1] = Layout.Box(owner.footer, { size = 2 })
            end
        else
            boxes = { Layout.Box(owner.header, { size = 3 }) }
            if ctl.state.status == "preparing" and size.width >= 104 and size.height >= 26 then
                boxes[#boxes + 1] = Layout.Box(
                    { Layout.Box(owner.questions, { size = "55%" }), Layout.Box(owner.timeline, { grow = 1 }) },
                    { dir = "row", grow = 1 }
                )
            elseif ctl.state.status == "preparing" then
                boxes[#boxes + 1] = Layout.Box(owner.questions, { grow = 1 })
                if size.height >= 22 then
                    boxes[#boxes + 1] = Layout.Box(owner.timeline, { size = 6 })
                end
            else
                boxes[#boxes + 1] = Layout.Box(owner.timeline, { grow = 1 })
                if has_questions then
                    boxes[#boxes + 1] =
                        Layout.Box(owner.questions, { size = math.max(4, math.floor(size.height * 0.48)) })
                end
            end
            if owner.show_composer then
                boxes[#boxes + 1] = Layout.Box(owner.composer, { size = size.height >= 30 and 5 or 3 })
            end
            boxes[#boxes + 1] = Layout.Box(owner.footer, { size = 3 })
        end
        local signature = size.width
            .. ":"
            .. size.height
            .. ":"
            .. tostring(has_questions)
            .. ":"
            .. ctl.state.status
            .. ":"
            .. tostring(ctl.busy)
            .. ":"
            .. tostring(owner.awaiting)
            .. ":"
            .. tostring(owner.show_composer)
            .. ":"
            .. tostring(owner.tiny_view)
            .. ":"
            .. tostring(owner.maximized)
        return { relative = "editor", position = "50%", size = size }, Layout.Box(boxes, { dir = "col" }), signature
    end
    local placement, tree, initial_signature = geometry()
    owner.layout = Layout(placement, tree)
    require("todo.ui.editor_commands").protect_layout(owner.layout)
    owner.layout:mount()
    layout_signature = initial_signature
    reflow = function()
        if owner.closed or owner.suspended then
            return
        end
        local focused_composer = valid(owner.composer) and vim.api.nvim_get_current_win() == owner.composer.winid
        local focused_questions = valid(owner.questions) and vim.api.nvim_get_current_win() == owner.questions.winid
        select_context()
        local next_placement, next_tree, signature = geometry()
        if signature ~= layout_signature then
            owner.pane_views = owner.pane_views or {}
            for _, pop in ipairs({ owner.timeline, owner.questions, owner.composer }) do
                if valid(pop) then
                    owner.pane_views[pop.bufnr] = vim.api.nvim_win_call(pop.winid, vim.fn.winsaveview)
                end
            end
            owner.layout:update(next_placement, next_tree)
            for _, pop in ipairs({ owner.timeline, owner.questions, owner.composer }) do
                if valid(pop) and owner.pane_views[pop.bufnr] then
                    vim.api.nvim_win_call(pop.winid, function()
                        vim.fn.winrestview(owner.pane_views[pop.bufnr])
                    end)
                end
            end
            layout_signature = signature
            if focused_composer and valid(owner.composer) then
                vim.api.nvim_set_current_win(owner.composer.winid)
            elseif focused_questions and valid(owner.questions) then
                vim.api.nvim_set_current_win(owner.questions.winid)
            elseif (focused_questions or focused_composer) and valid(owner.timeline) then
                vim.api.nvim_set_current_win(owner.timeline.winid)
            end
        end
    end
    function owner.close()
        if owner.closed then
            return
        end
        if owner.composer then
            save_draft(owner.composer, owner.contexts[owner.composing_key])
        end
        ctl:save_cache()
        ctl:pause()
        require("todo.ai.research").clear(ctl.id)
        owner.closed = true
        if owner.spinner then
            owner.spinner:stop()
            owner.spinner:close()
        end
        if owner.unsubscribe then
            owner.unsubscribe()
        end
        if owner.group then
            pcall(vim.api.nvim_del_augroup_by_id, owner.group)
        end
        require("todo.ui.hints").close(owner)
        if owner.context_popup and vim.api.nvim_buf_is_valid(owner.context_popup.bufnr) then
            pcall(owner.context_popup.unmount, owner.context_popup)
            owner.context_popup = nil
        end
        owner.layout:unmount()
        for _, pop in pairs(owner.composers) do
            if pop.editor then
                pop.editor.dispose()
            end
            pcall(pop.unmount, pop)
        end
        for _, pop in ipairs({ owner.header, owner.questions, owner.timeline, owner.footer }) do
            pcall(pop.unmount, pop)
        end
        if current == owner then
            current = nil
        end
    end
    local pane_names = { "timeline", "questions", "composer" }
    local function current_pane()
        local win = vim.api.nvim_get_current_win()
        for _, name in ipairs(pane_names) do
            if valid(owner[name]) and owner[name].winid == win then
                return name
            end
        end
        return owner.focused_pane or "questions"
    end
    focus_pane = function(name)
        owner.tiny_view, owner.focused_pane = name, name
        if owner.maximized then
            owner.maximized = name
        end
        reflow()
        if valid(owner[name]) then
            vim.api.nvim_set_current_win(owner[name].winid)
        end
        if render then
            render()
        end
    end
    return_to_choices = function()
        local pop = owner.composer
        if pop then
            save_draft(pop, owner.contexts[owner.composing_key])
            ctl:save_cache()
            pop.editor.mark_saved()
            if vim.trim(buffer_text(pop)) == "" then
                owner.show_composer = false
            end
        end
        owner.chat_mode = false
        focus_pane("questions")
    end
    focus_input = function(insert)
        owner.show_composer = true
        select_context(true)
        focus_pane("composer")
        if valid(owner.composer) and insert then
            vim.cmd("startinsert")
        end
    end
    local function move_focus(direction)
        local name = current_pane()
        local current = owner[name]
        if owner.small or owner.maximized then
            local index = 1
            for i, n in ipairs(pane_names) do
                if n == name then
                    index = i
                end
            end
            local delta = (direction == "h" or direction == "k") and -1 or 1
            local target = pane_names[index + delta]
            if target then
                if target == "composer" then
                    select_context(true)
                end
                focus_pane(target)
            end
            return
        end
        if not valid(current) then
            return
        end
        local p = vim.api.nvim_win_get_position(current.winid)
        local x = p[2] + vim.api.nvim_win_get_width(current.winid) / 2
        local y = p[1] + vim.api.nvim_win_get_height(current.winid) / 2
        local best, distance
        for _, target in ipairs(pane_names) do
            local pop = owner[target]
            if target ~= name and valid(pop) then
                local pos = vim.api.nvim_win_get_position(pop.winid)
                local dx = pos[2] + vim.api.nvim_win_get_width(pop.winid) / 2 - x
                local dy = pos[1] + vim.api.nvim_win_get_height(pop.winid) / 2 - y
                local along = direction == "h" and -dx or direction == "l" and dx or direction == "k" and -dy or dy
                local across = (direction == "h" or direction == "l") and math.abs(dy) or math.abs(dx)
                if along > 0.5 and (not distance or along + across * 3 < distance) then
                    best, distance = target, along + across * 3
                end
            end
        end
        if best then
            if best == "composer" then
                select_context(true)
            end
            focus_pane(best)
        end
    end
    local function scroll_reply(direction, fraction)
        if not valid(owner.timeline) then
            return
        end
        owner.follow_reply = direction == 0
        if direction == 0 then
            owner.unread_reply = false
        end
        vim.api.nvim_win_call(owner.timeline.winid, function()
            if direction == 0 then
                vim.cmd("normal! Gzb")
            else
                local count = math.max(1, math.floor(vim.api.nvim_win_get_height(0) * fraction))
                -- Scroll display lines; win_call preserves the input buffer, mode and cursor.
                vim.cmd("normal! " .. count .. (direction < 0 and "\25" or "\5"))
            end
        end)
        if render then
            render()
        end
    end
    bind_panes = function(pop)
        for name, direction in pairs({ focus_left = "h", focus_down = "j", focus_up = "k", focus_right = "l" }) do
            action(pop, name, function()
                move_focus(direction)
            end)
        end
        for name, spec in pairs({
            read_half_up = { -1, 0.5 },
            read_half_down = { 1, 0.5 },
            read_page_up = { -1, 1 },
            read_page_down = { 1, 1 },
            read_latest = { 0, 1 },
        }) do
            action(pop, name, function()
                scroll_reply(spec[1], spec[2])
            end, { "n", "i" })
        end
        action(pop, "maximize", function()
            local name = current_pane()
            owner.maximized = not owner.maximized and name or nil
            focus_pane(name)
        end)
        action(pop, "read_top", function()
            if not valid(owner.timeline) then
                return
            end
            owner.follow_reply = false
            vim.api.nvim_win_call(owner.timeline.winid, function()
                vim.cmd("normal! gg")
            end)
            render()
        end, { "n", "i" })
    end
    for _, pop in ipairs({ owner.timeline, owner.questions, owner.composer }) do
        bind_panes(pop)
    end
    local question_rows = {}
    render = function()
        if owner.closed or owner.suspended or rendering then
            return
        end
        rendering = true
        local started = require("todo.performance").start()
        local ok, err = pcall(function()
            if owner.refresh_queue and not ctl.busy then
                ctl:refresh()
                owner.refresh_queue = false
            end
            local ctl = snapshot:daily(ctl)
            local svc = snapshot.service
            if valid(owner.composer) and vim.trim(buffer_text(owner.composer)) ~= "" then
                owner.show_composer = true
            end
            reflow()
            local done, total = ctl:counts()
            local usage = ctl.ai:usage(ctl.id)
            local entry = ctl:current()
            local session = entry and ctl:item(entry)
            local mode = vim.api.nvim_get_mode().mode
            local vim_mode = mode:sub(1, 1) == "i" and "INSERT" or mode:match("^[vV\22]") and "VISUAL" or "NORMAL"
            local function width(pop)
                return valid(pop) and vim.api.nvim_win_get_width(pop.winid) or math.max(1, vim.o.columns - 4)
            end
            view.paint(owner.header, view.header(ctl, width(owner.header)), ns)
            local timeline = view.timeline(
                ctl,
                svc,
                owner.selection,
                session,
                width(owner.timeline),
                owner.show_details,
                owner.queue_open
            )
            local old_view
            if valid(owner.timeline) then
                old_view = vim.api.nvim_win_call(owner.timeline.winid, vim.fn.winsaveview)
            end
            local reply_version = (session and session.id or "") .. ":" .. (ctl.partial or "") .. ":" .. #timeline.lines
            if owner.reply_version and owner.reply_version ~= reply_version and not owner.follow_reply then
                owner.unread_reply = true
            end
            owner.reply_version = reply_version
            view.paint(owner.timeline, timeline, ns)
            if owner.spinner_row ~= timeline.spinner_row then
                vim.api.nvim_buf_clear_namespace(owner.timeline.bufnr, spinner_ns, 0, -1)
            end
            owner.spinner_row = timeline.spinner_row
            if valid(owner.timeline) then
                if ctl.state.status == "preparing" then
                    if owner.preview_uuid ~= (ctl.state.queue[owner.selection] or {}).uuid then
                        pcall(vim.api.nvim_win_set_cursor, owner.timeline.winid, { 1, 0 })
                        owner.preview_uuid = (ctl.state.queue[owner.selection] or {}).uuid
                    end
                elseif owner.follow_reply or ctl.busy then
                    pcall(
                        vim.api.nvim_win_set_cursor,
                        owner.timeline.winid,
                        { vim.api.nvim_buf_line_count(owner.timeline.bufnr), 0 }
                    )
                elseif old_view then
                    vim.api.nvim_win_call(owner.timeline.winid, function()
                        vim.fn.winrestview(old_view)
                    end)
                end
            end
            local question_doc
            if ctl.permission then
                question_doc = view.permission(ctl.permission, width(owner.questions))
            elseif owner.mode_picker then
                question_doc = view.modes(owner.mode_option or 1, width(owner.questions))
            elseif ctl.state.status == "preparing" or owner.queue_open then
                question_doc =
                    view.tasks(ctl, svc, owner.selection, width(owner.questions), ctl.state.status ~= "preparing")
            else
                question_doc = view.questions(round_for(entry), owner.tab, owner.option, width(owner.questions))
            end
            local round = round_for(entry)
            if round and not ctl.busy then
                if owner.awaiting then
                    owner.awaiting = false
                    owner.composing_key = nil
                    select_context(true)
                end
            end
            local screen_key = ctl.permission and ("permission:" .. (ctl.permission.id or ctl.permission.target or ""))
                or owner.mode_picker and "modes"
                or (ctl.state.status == "preparing" or owner.queue_open) and "tasks"
                or (round and round.id or "empty") .. ":" .. owner.tab
            local changed = owner.question_screen ~= screen_key
            owner.question_screen = screen_key
            question_rows = question_doc.rows
            view.paint(owner.questions, question_doc, ns)
            if changed and valid(owner.questions) then
                vim.api.nvim_win_call(owner.questions.winid, function()
                    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
                end)
            end
            if valid(owner.questions) then
                local row =
                    question_rows[owner.mode_picker and owner.mode_option or (ctl.state.status == "preparing" or owner.queue_open) and owner.selection or owner.option]
                if row then
                    pcall(vim.api.nvim_win_set_cursor, owner.questions.winid, { row, 0 })
                end
                if changed then
                    vim.api.nvim_win_call(owner.questions.winid, function()
                        local v = vim.fn.winsaveview()
                        v.topline = 1
                        vim.fn.winrestview(v)
                    end)
                end
            end
            local width = valid(owner.footer) and vim.api.nvim_win_get_width(owner.footer.winid) or vim.o.columns - 4
            local cost = usage.unknown > 0 and L("cost partially unknown", "部分费用未知")
                or string.format("~$%.5f", usage.usd)
            local editing = vim.api.nvim_get_current_buf() == owner.composer.bufnr
            if valid(owner.composer) then
                pcall(function()
                    vim.bo[owner.composer.bufnr].modifiable = not ctl.busy
                    vim.bo[owner.composer.bufnr].readonly = ctl.busy
                end)
            end
            local choosing = vim.api.nvim_get_current_buf() == owner.questions.bufnr
            local preview = round and owner.tab > #round.questions
            local actions = {}
            local function hint(key, label)
                if key and key ~= "" then
                    actions[#actions + 1] = { key = key, label = label }
                end
            end
            if editing then
                hint(
                    vim_mode == "INSERT" and "Esc" or keys.label("return_to_choices"),
                    vim_mode == "INSERT" and L("Normal mode", "普通模式")
                        or L("Save & return", "保存并返回选项")
                )
                hint(":w", L("Save draft", "保存草稿"))
            elseif ctl.permission then
                hint("y/Y/n", L("Allow once / session / reject", "允许一次／本会话／拒绝"))
            elseif owner.mode_picker then
                if choosing then
                    hint(keys.label("select"), L("Apply mode", "切换模式"))
                end
                hint("Esc", L("Back", "返回"))
            elseif ctl.busy then
                hint("Ctrl-c", L("Stop", "停止"))
            elseif ctl.state.last_error then
                hint("r", L("Retry saved request", "重试已保存的请求"))
                if choosing and round then
                    hint(keys.label("edit_note"), L("Edit answer", "修改答案"))
                    hint(keys.label("preview"), L("Preview answers", "提交预览"))
                end
            elseif ctl.state.status == "review" or ctl.state.status == "applied" then
                hint("v", L("Review plan", "查看规划"))
            elseif ctl.state.status == "preparing" then
                if choosing and not ctl.state.locks_confirmed then
                    hint(keys.label("select"), L("Confirm fixed items", "确认固定事项"))
                else
                    hint(keys.label("preview"), L("Start", "开始"))
                end
                if choosing then
                    hint(keys.label("toggle"), L("Include / exclude", "参与／排除"))
                end
                hint(keys.label("edit_note"), L("Edit task", "编辑任务"))
                hint("A", L("Add existing", "添加已有"))
            elseif owner.queue_open then
                hint("b", L("Back to questions", "返回问题"))
            elseif preview then
                if choosing then
                    hint(keys.label("select"), L("Send answers", "提交答案"))
                end
                hint("Esc", L("Back to questions", "返回问题"))
            else
                if choosing and round then
                    hint(keys.label("select"), L("Select", "选择"))
                    hint(keys.label("supplement"), L("Supplement", "补充"))
                    hint(keys.label("edit_note"), L("Add note", "附加说明"))
                    hint(keys.label("chat"), L("Message AI", "给 AI 发消息"))
                    hint("T", L("Prompt presets", "提示词"))
                    hint("D", L("Task context", "任务原文"))
                    hint("d", L("Details", "详情"))
                end
                hint(keys.label("preview"), round and L("Preview answers", "提交预览") or L("Continue", "继续"))
                hint("D", L("Task context", "任务原文"))
                if round then
                    hint(keys.label("chat"), L("Message AI", "给 AI 发消息"))
                end
            end
            if vim_mode == "NORMAL" then
                hint(keys.label("maximize"), owner.maximized and L("Restore", "还原") or L("Maximize", "最大化"))
            end
            hint("F1", L("Help", "帮助"))
            if owner.unread_reply and keys.label("read_latest") ~= "" then
                table.insert(
                    actions,
                    1,
                    { key = keys.label("read_latest"), label = L("New reply ↓", "有新回复 ↓") }
                )
            end
            local footer = require("todo.ui.hints").lines(actions, math.max(1, width), 2)
            table.insert(
                footer,
                1,
                require("todo.ui.viewmodel").truncate(
                    (ctl.mode or "plan"):upper()
                        .. " · "
                        .. vim_mode
                        .. " · "
                        .. cost
                        .. " · "
                        .. (owner.contexts[owner.composing_key].label or ""),
                    width
                )
            )
            if width < 36 then
                footer =
                    { (ctl.mode or "plan"):upper() .. " " .. done .. "/" .. total .. " " .. (ctl.busy and "⠋" or "") }
            end
            if write(owner.footer, footer) then
                require("todo.ui.hints").highlight(
                    owner.footer.bufnr,
                    nil,
                    nil,
                    { text = "TodoDailyText", key = "TodoDailyKey" }
                )
            end
            local composer_label = owner.contexts[owner.composing_key].label or ""
            local choice_title = ctl.permission and L("Access request", "权限申请")
                or owner.mode_picker and L("Permission mode", "权限模式")
                or (ctl.state.status == "preparing" or owner.queue_open) and L("Tasks", "参与任务")
                or preview and L("Answer preview", "答案预览")
                or L("Choices", "回答选项")
            for _, name in ipairs(pane_names) do
                local pop = owner[name]
                if valid(pop) then
                    local active = vim.api.nvim_get_current_win() == pop.winid
                    pop.border:set_highlight(active and "TodoDailyAccent" or "TodoDailyRule")
                    local title = name == "composer"
                            and composer_label .. " · " .. vim_mode .. (vim.bo[pop.bufnr].modified and " [+]" or "")
                        or name == "timeline" and L("AI · Context", "AI · 上下文")
                        or choice_title
                    local pane_width = vim.api.nvim_win_get_width(pop.winid)
                    local stamp = title .. ":" .. tostring(active) .. ":" .. pop.winid .. ":" .. pane_width
                    if pop.title_stamp ~= stamp then
                        -- NUI's simple borders ignore set_text. Native titles retain
                        -- the single-window layout and survive geometry updates.
                        local title_text = " "
                            .. require("todo.ui.viewmodel").truncate(title, math.max(1, pane_width - 4))
                            .. " "
                        pop._.win_config.title = { { title_text, active and "TodoDailyAccent" or "TodoDailyMuted" } }
                        pop._.win_config.title_pos = "left"
                        vim.api.nvim_win_set_config(pop.winid, {
                            title = pop._.win_config.title,
                            title_pos = "left",
                        })
                        pop.title_stamp = stamp
                    end
                end
            end
            vim.api.nvim_buf_clear_namespace(owner.composer.bufnr, ns, 0, -1)
            if buffer_text(owner.composer) == "" then
                vim.api.nvim_buf_set_extmark(owner.composer.bufnr, ns, 0, 0, {
                    virt_text = { { "  " .. composer_label .. " · i " .. L("type", "输入"), "TodoDailyMuted" } },
                    virt_text_pos = "overlay",
                })
            end
        end)
        rendering = false
        rendered = requested
        require("todo.performance").finish("daily.render", started)
        if not ok then
            require("todo.diagnostics").record({ operation = "Daily UI", stage = "render", error = tostring(err) })
        end
    end
    local function schedule_render()
        requested = requested + 1
        if pending or owner.closed then
            return
        end
        pending = true
        vim.defer_fn(function()
            pending = false
            if rendered < requested then
                render()
            end
        end, 33)
    end
    owner.unsubscribe = ctl:on_change(function()
        if ctl.permission then
            owner.tiny_view = "questions"
        end
        schedule_render()
    end)
    owner.spinner = (vim.uv or vim.loop).new_timer()
    owner.spinner:start(
        150,
        150,
        vim.schedule_wrap(function()
            if not owner.closed and ctl.busy and owner.spinner_row and valid(owner.timeline) then
                local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
                local f = frames[math.floor((vim.uv or vim.loop).hrtime() / 1.5e8) % #frames + 1]
                local row = tonumber(owner.spinner_row)
                if row and row >= 0 and row < vim.api.nvim_buf_line_count(owner.timeline.bufnr) then
                    vim.api.nvim_buf_set_extmark(owner.timeline.bufnr, spinner_ns, row, 0, {
                        id = 1,
                        virt_text = { { "  " .. f, "TodoDailyAccent" } },
                        virt_text_pos = "overlay",
                    })
                end
            end
        end)
    )
    local function open_task_context()
        local entry = ctl:current()
        if not entry then
            return
        end
        local task = svc.store:get(entry.task_id)
        if not task then
            return
        end
        if owner.context_popup and valid(owner.context_popup) then
            pcall(owner.context_popup.unmount, owner.context_popup)
            owner.context_popup = nil
        end
        local lines = require("todo.ui.markdown").task_lines(task, {
            notes = snapshot:list("note"),
        })
        local plan_item
        for _, item in ipairs(ctl.planner:today(ctl.date).items) do
            if item.task_uuid == entry.uuid then
                plan_item = item
                break
            end
        end
        if plan_item then
            vim.list_extend(lines, {
                "",
                "## " .. L("Today plan", "今日计划"),
                "",
                "- " .. L("Group", "分组") .. ": " .. tostring(plan_item.group or "next"),
                "- " .. L("Minutes", "预计分钟") .. ": " .. tostring(plan_item.minutes or 0),
                "- " .. L("Next action", "下一步") .. ": " .. tostring(plan_item.next_action or ""),
                "- " .. L("Done when", "完成标准") .. ": " .. tostring(plan_item.completion or ""),
                "- " .. L("Locked", "已锁定") .. ": " .. tostring(plan_item.locked == true),
            })
        end
        local pop = Popup({
            relative = "editor",
            position = "50%",
            enter = true,
            size = {
                width = math.max(30, math.min(100, math.floor(vim.o.columns * 0.72))),
                height = math.max(8, math.min(40, math.floor(vim.o.lines * 0.72))),
            },
            border = { style = "rounded", text = { top = " " .. L("Task context", "任务原文与计划") .. " " } },
            buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false },
            win_options = { wrap = true, winhighlight = "Normal:TodoDailySurface,FloatBorder:TodoDailyRule" },
        })
        pop:mount()
        vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, lines)
        vim.bo[pop.bufnr].modifiable = false
        require("todo.ui.markdown").attach(pop.bufnr)
        local function close()
            pcall(pop.unmount, pop)
            if owner.context_popup == pop then
                owner.context_popup = nil
            end
        end
        vim.keymap.set("n", "q", close, { buffer = pop.bufnr, silent = true })
        vim.keymap.set("n", "<Esc>", close, { buffer = pop.bufnr, silent = true })
        owner.context_popup = pop
    end

    submit = function()
        if ctl.busy then
            vim.notify(L("AI is replying; Ctrl-c stops it.", "AI 正在回复；Ctrl-c 可停止。"), vim.log.levels.WARN)
            return
        end
        if ctl.state.status == "review" or ctl.state.status == "applied" then
            assert(ctl.state.draft_id, "No draft yet")
            local id = ctl.state.draft_id
            owner.close()
            require("todo.ui.planner").review(id)
            return
        end
        local ctx = owner.contexts[owner.composing_key]
        local text = buffer_text(owner.composer)
        save_draft(owner.composer, ctx)
        ctl:save_cache()
        if ctl.state.status == "preparing" then
            -- The lazily retained composer may still contain an option note.
            local intention = owner.composers.intent
            if intention then
                save_draft(intention, owner.contexts.intent)
            end
            local ok, err = ctl:prepare(false)
            if not ok then
                ctl.state.last_error = err
                ctl:emit()
                return
            end
            owner.sent_text[owner.composing_key] = text
            ctl:start()
            return
        end
        if owner.chat_mode then
            if vim.trim(text) == "" then
                ctl.state.last_error = L("Message is empty", "消息为空")
                ctl:emit()
                return
            end
            owner.chat_mode = false
            owner.awaiting = true
            owner.show_composer = false
            vim.api.nvim_buf_set_lines(owner.composer.bufnr, 0, -1, false, { "" })
            owner.sent_text[owner.composing_key] = ""
            ctl:message(text)
            owner.follow_reply = true
            select_context(true)
            render()
            focus_pane("timeline")
            return
        end
        local entry = ctl:current()
        local round = round_for(entry)
        -- A lazily retained editor may belong to the previous question/task.
        -- Its draft is already saved, but must never be sent as this task's answer.
        local same_task = entry and ctx.entry and ctx.entry.uuid == entry.uuid
        local extra = same_task and not ctx.round and text or ""
        -- Continue resumes the workflow, including a failed final assembly with
        -- no current task. Retained notes are not a new answer for this request.
        if ctl.state.status == "paused" and not round and extra:match("^%s*$") then
            ctl:start()
            return
        end
        assert(entry, "No current task")
        if round then
            local valid, missing = require("todo.ai.questions").validate(round)
            if not valid then
                ctl.state.last_error = missing
                ctl:emit()
                owner.tab = 1
                for index, question in ipairs(round.questions) do
                    if not require("todo.ai.questions").answered(round, question) then
                        owner.tab = index
                        break
                    end
                end
                render()
                return
            end
            -- Collapse the choices immediately; the next round is a fresh UI.
            ctl.cache.rounds = ctl.cache.rounds or {}
            ctl.cache.rounds[ctl:item_id(entry)] = nil
        end
        owner.sent_text[owner.composing_key] = text
        owner.awaiting = true
        owner.tab = 1
        owner.option = 1
        owner.note_option = nil
        owner.chat_mode = false
        owner.show_composer = false
        if valid(owner.composer) then
            vim.api.nvim_buf_set_lines(owner.composer.bufnr, 0, -1, false, { "" })
            owner.sent_text[owner.composing_key] = ""
        end
        local transcript = (round and require("todo.ai.questions").transcript(round) or "") .. "\n" .. extra
        ctl:submit(extra, round, require("todo.assets").refs(transcript))
        owner.follow_reply = true
        render()
        focus_pane("timeline")
    end
    edit_task = function(add)
        assert(not ctl.busy, "Stop the request before editing")
        local selected = ctl.state.queue[owner.selection]
        local task = not add and selected and svc.store:get(selected.task_id) or nil
        if not add then
            assert(task, "Select a task")
        end
        owner.suspended = true
        owner.layout:hide()
        require("todo.ui.form").open(task, function(input)
            local result, err
            if task then
                result, err = svc:update(task.id, input, task.sync_revision)
            else
                result, err = svc:create(input)
            end
            if result then
                task = result
            end
            return result, err
        end, {
            on_close = function()
                if owner.closed then
                    return
                end
                owner.suspended = false
                ctl:refresh()
                ctl.state.status = "preparing"
                ctl.state.locks_confirmed = false
                ctl:save()
                select_context(true)
                owner.layout:show()
                layout_signature = nil
                render()
                if valid(owner.questions) then
                    vim.api.nvim_set_current_win(owner.questions.winid)
                end
            end,
        })
    end
    help = function()
        require("todo.ui.hints").show(function()
            return {
                title = L("Daily planning", "每日规划"),
                actions = {
                    { key = "i/a", label = L("Focus Vim composer", "进入 Vim 输入区") },
                    {
                        key = keys.label("preview"),
                        label = L("Start / preview answers", "开始／预览整轮答案"),
                    },
                    { key = "Ctrl-c", label = L("Stop request; retain draft", "停止请求并保留草稿") },
                    {
                        key = "r",
                        label = L(
                            "Retry failed request with saved answers",
                            "使用已保存的答案重试失败请求"
                        ),
                    },
                    { key = "Ctrl-q", label = L("Pause and close", "暂停并关闭") },
                    { key = "Tab (options)", label = L("Supplement current option", "补充当前选项") },
                    { key = "Tab / Enter (input)", label = L("Save and return to options", "保存并返回选项") },
                    { key = "Enter (options)", label = L("Confirm and next question", "确认并进入下一题") },
                    { key = "Space (options)", label = L("Toggle without advancing", "勾选但不跳题") },
                    { key = "Shift-Enter / Ctrl-J", label = L("Newline in composer", "输入框内换行") },
                    { key = "t", label = L("Message AI with free-form guidance", "给 AI 发自由指导") },
                    { key = "T", label = L("Useful steering prompt presets", "有用的指导提示词") },
                    { key = "D", label = L("Open full task context and plan", "查看任务原文与今日计划") },
                    { key = "d", label = L("Toggle details in timeline", "在对话区展开任务详情") },
                    { key = "End / Ctrl-Alt-g", label = L("Jump to latest reply", "跳到最新回复") },
                    { key = "Home / Ctrl-g", label = L("Jump to top", "跳到顶部") },
                    {
                        key = keys.label("read_half_up") .. " / " .. keys.label("read_half_down"),
                        label = L("Scroll AI reply half page", "上下翻阅 AI 回复半页"),
                    },
                    {
                        key = keys.label("read_page_up") .. " / " .. keys.label("read_page_down"),
                        label = L("Scroll AI reply full page", "上下翻阅 AI 回复整页"),
                    },
                    {
                        key = keys.label("read_latest"),
                        label = L("Latest reply / follow stream", "最新回复／跟随输出"),
                    },
                    {
                        key = keys.label("select") .. " / " .. keys.label("toggle"),
                        label = L("Select without advancing", "勾选当前项，不跳题"),
                    },
                    { key = "j/k", label = L("Move option cursor / read reply", "移动选项光标／浏览回复") },
                    {
                        key = keys.label("previous_question") .. " / " .. keys.label("next_question"),
                        label = L("Question tabs (outside input)", "切换问题（输入区外）"),
                    },
                    {
                        key = keys.label("edit_note") .. " (options)",
                        label = L("Annotate even unselected options", "给选项附加说明，无需勾选"),
                    },
                    {
                        key = keys.label("focus_left")
                            .. " / "
                            .. keys.label("focus_down")
                            .. " / "
                            .. keys.label("focus_up")
                            .. " / "
                            .. keys.label("focus_right"),
                        label = L("Focus pane (Normal)", "切换区域（Normal）"),
                    },
                    {
                        key = keys.label("maximize"),
                        label = L("Maximize / restore focused pane", "最大化／还原当前区域"),
                    },
                    { key = "Ctrl-v (Insert)", label = L("Paste image", "粘贴图片") },
                    { key = "<localleader>p", label = L("Paste image in Normal mode", "Normal 模式粘贴图片") },
                    { key = "Ctrl-r (input)", label = L("Native text redo", "原生文本重做") },
                    { key = "M", label = L("Choose plan / build / auto", "选择 plan／build／auto 权限模式") },
                    {
                        key = "y / Y / n",
                        label = L(
                            "Permission: once / session / reject",
                            "权限申请：允许一次／本会话允许相同请求／拒绝"
                        ),
                    },
                    { key = "C / B", label = L("Work / reserve minutes", "工作／预留分钟") },
                    { key = "L", label = L("Lock selected task", "固定／解锁所选任务") },
                    { key = "a/e (preparation)", label = L("Create/edit task", "新增／编辑任务") },
                    { key = "A (preparation)", label = L("Add existing task", "添加已有任务") },
                    { key = "s", label = L("Defer current task", "稍后处理当前任务") },
                    {
                        key = "g (choices) / c (context)",
                        label = L("Continue / finish using known facts", "继续／根据已有信息完成当前项"),
                    },
                    { key = "v", label = L("Review plan and details changes", "审批清单与 details 修改") },
                    { key = "b / d", label = L("Toggle task queue / details", "展开任务队列／当前详情") },
                    { key = "V", label = L("Toggle text only", "切换仅文字模式（不发送图片）") },
                    { key = "p", label = L("Return to preparation", "暂停后返回准备页调整任务与容量") },
                    {
                        key = "S (preparation)",
                        label = L("Explicitly continue with full fixed capacity", "明确保持固定并继续分析"),
                    },
                },
            }
        end, { owner = owner })
    end
    local function choice(delta)
        if ctl.permission then
            if valid(owner.questions) then
                vim.api.nvim_win_call(owner.questions.winid, function()
                    vim.cmd("normal! " .. math.abs(delta) .. (delta > 0 and "j" or "k"))
                end)
            end
            return
        elseif owner.mode_picker then
            owner.mode_option = math.max(1, math.min(3, (owner.mode_option or 1) + delta))
        elseif ctl.state.status == "preparing" or owner.queue_open then
            owner.selection = math.max(1, math.min(#ctl.state.queue, owner.selection + delta))
        else
            local round = round_for(ctl:current())
            local q = round and round.questions[owner.tab]
            if q then
                owner.option = math.max(1, math.min(#q.options + 1, owner.option + delta))
            end
        end
        render()
    end
    local function toggle()
        if owner.mode_picker or ctl.permission or (owner.queue_open and ctl.state.status ~= "preparing") then
            return
        end
        assert(not ctl.busy, "AI is busy")
        if ctl.state.status == "preparing" then
            local e = ctl.state.queue[owner.selection]
            if e and not e.missing then
                e.selected = not e.selected
                ctl:save()
            end
            return
        end
        local round = round_for(ctl:current())
        local q = round and round.questions[owner.tab]
        if not q then
            return
        end
        local o = q.options[owner.option]
        if not o then
            owner.note_option = nil
            focus_input(true)
            return
        end
        local a = answer(round, q)
        local picked = a.selected[o.id]
        if not q.multiple then
            a.selected = {}
        end
        a.selected[o.id] = not picked or nil
        cache_later()
        render()
    end
    local function supplement()
        if ctl.busy or ctl.permission or owner.mode_picker or owner.queue_open then
            return
        end
        if ctl.state.status == "preparing" then
            return
        end
        local round = round_for(ctl:current())
        local q = round and round.questions[owner.tab]
        if not q then
            return
        end
        owner.chat_mode = false
        owner.note_option = owner.option <= #q.options and owner.option or nil
        focus_input(true)
    end
    for _, pop in ipairs({ owner.timeline, owner.questions }) do
        action(pop, "input", function()
            owner.note_option = nil
            owner.chat_mode = false
            focus_input(true)
        end)
        action(pop, "chat", function()
            if ctl.busy or ctl.permission or owner.mode_picker then
                return
            end
            owner.note_option = nil
            owner.chat_mode = true
            focus_input(true)
        end)
        action(pop, "supplement", supplement)
        map(pop, "T", function()
            if ctl.busy or ctl.permission or owner.mode_picker then
                return
            end
            local presets = {
                L("Ask me 3 more questions about scope and acceptance.", "再追问我 3 个问题，重点确认范围和验收标准。"),
                L("The current question needs 3-5 options; cover alternatives, tradeoffs and edge cases.", "当前问题的选项数量不符合 3–5 个，请补充可选方案、取舍和边界情况。"),
                L("Do not estimate time yet; clarify the goal first.", "先别估算时间，先确认目标。"),
                L("Merge my previous answers and ask only what is still missing.", "合并我之前的回答，只问仍然缺失的信息。"),
                L("I only have two hours; re-plan within that limit.", "我只有两小时，按这个限制重新规划。"),
                L("If it is clear enough, produce the plan with assumptions.", "如果已经足够清楚，直接给计划并列出假设。"),
            }
            vim.ui.select(presets, { prompt = L("Message AI", "给 AI 发消息") }, function(choice)
                if not choice then
                    return
                end
                owner.chat_mode = true
                select_context(true)
                vim.api.nvim_buf_set_lines(owner.composer.bufnr, 0, -1, false, { choice })
                focus_input(true)
            end)
        end)
        map(pop, "a", function()
            if ctl.state.status == "preparing" then
                edit_task(true)
            else
                focus_input(true)
            end
        end)
        map(pop, "A", function()
            if ctl.state.status ~= "preparing" then
                return
            end
            local known = {}
            for _, entry in ipairs(ctl.state.queue) do
                known[entry.uuid] = true
            end
            local choices = {}
            for _, task in ipairs(svc.store:list({ archived = false })) do
                if
                    task.kind ~= "notice"
                    and not task.archived_at
                    and (task.status == "todo" or task.status == "in_progress")
                    and not known[task.sync_uuid]
                then
                    choices[#choices + 1] = task
                end
            end
            vim.ui.select(choices, {
                prompt = L("Add existing task to this planning session", "添加已有任务到本次规划"),
                format_item = function(task)
                    return string.format("[P%d] %s", task.priority or 3, task.title)
                end,
            }, function(task)
                if not task then
                    return
                end
                ctl:add_task(task.sync_uuid)
                ctl:save()
                select_context(true)
                render()
            end)
        end)
        map(pop, "M", function()
            assert(not ctl.busy, "Stop the active request before changing mode")
            owner.mode_picker = not owner.mode_picker
            owner.mode_option = ({ plan = 1, build = 2, auto = 3 })[ctl.mode] or 1
            render()
            if valid(owner.questions) then
                vim.api.nvim_set_current_win(owner.questions.winid)
            end
        end)
        for key, decision in pairs({ y = "allow", Y = "allow_session", n = "deny" }) do
            map(pop, key, function()
                if ctl.permission then
                    ctl:decide_permission(decision)
                end
            end)
        end
        map(pop, "<Esc>", function()
            if owner.mode_picker then
                owner.mode_picker = false
                render()
            elseif owner.queue_open then
                owner.queue_open = false
                render()
            elseif owner.preview_from then
                owner.tab, owner.option = owner.preview_from.tab, owner.preview_from.option
                owner.preview_from = nil
                render()
            end
        end)
        map(pop, "q", owner.close)
        map(pop, "<C-q>", owner.close)
        map(pop, "<C-c>", function()
            ctl:pause()
        end)
        action(pop, "preview", function()
            if ctl.permission or owner.mode_picker then
                return
            end
            owner.queue_open = false
            local round = round_for(ctl:current())
            if round and ctl.state.status ~= "preparing" then
                if not owner.preview_from and owner.tab <= #round.questions then
                    owner.preview_from = { tab = owner.tab, option = owner.option }
                end
                owner.tab = #round.questions + 1
                focus_pane("questions")
            else
                submit()
            end
        end)
        map(pop, "?", help)
        map(pop, "<F1>", help)
        map(pop, "<C-p>", help)
        map(pop, "r", function()
            assert(not ctl.busy, "AI is still replying")
            if ctl.state.last_error then
                if ctl.state.status == "preparing" then
                    submit()
                else
                    local entry = ctl:current()
                    local session = entry and ctl:item(entry)
                    local ctx = owner.contexts[owner.composing_key]
                    if
                        session
                        and session.round
                        and ctx.round
                        and session.round.id == ctx.round.id
                        and ctx.question
                    then
                        local saved = session.round.answers[ctx.question.id] or {}
                        local sent = ctx.option and (saved.notes or {})[ctx.option.id] or saved.custom
                        if buffer_text(owner.composer) == (sent or "") then
                            owner.sent_text[owner.composing_key] = sent or ""
                        end
                    end
                    ctl:start()
                end
            end
        end)
        map(pop, "v", function()
            assert(ctl.state.draft_id, "No draft yet")
            ctl:save_cache()
            owner.close()
            require("todo.ui.planner").review(ctl.state.draft_id)
        end)
        map(pop, "V", function()
            assert(not ctl.busy, "Stop the current request first")
            local text_only = ctl.state.text_only
            if text_only == nil then
                text_only = require("todo.config").get().ai.text_only
            end
            ctl.state.text_only = not text_only
            ctl.state.last_error = nil
            ctl:save()
        end)
        map(pop, "p", function()
            assert(not ctl.busy, "Stop the request before changing preparation")
            ctl.state.status = "preparing"
            ctl.state.locks_confirmed = false
            owner.queue_open = false
            owner.tiny_view = nil
            ctl:refresh()
            ctl:save()
            select_context(true)
            render()
            if valid(owner.questions) then
                vim.api.nvim_set_current_win(owner.questions.winid)
            end
        end)
        map(pop, "d", function()
            owner.show_details = not owner.show_details
            render()
        end)
        map(pop, "D", open_task_context)
        map(pop, "b", function()
            owner.queue_open = not owner.queue_open
            owner.tiny_view = nil
            render()
        end)
        map(pop, pop == owner.timeline and "c" or "g", function()
            if owner.queue_open or owner.mode_picker or ctl.permission then
                return
            end
            assert(not ctl.busy, "Stop current request first")
            if ctl.state.status == "preparing" then
                local ok, err = ctl:prepare(false)
                assert(ok, err)
            end
            local e = ctl:current()
            local round = round_for(e)
            if round then
                local ctx = owner.contexts[owner.composing_key]
                if ctx.round and ctx.round.id == round.id then
                    owner.sent_text[owner.composing_key] = buffer_text(owner.composer)
                end
                ctl:submit(
                    L(
                        "Finish this item with known information; list assumptions.",
                        "根据已知信息完成当前项，列明假设。"
                    ),
                    round,
                    nil,
                    true
                )
            else
                ctl:start()
            end
        end)
        map(pop, "s", function()
            if owner.queue_open or owner.mode_picker or ctl.permission or ctl.state.status == "preparing" then
                return
            end
            ctl:skip()
        end)
        action(pop, "edit_note", function()
            if ctl.permission or owner.mode_picker or (owner.queue_open and ctl.state.status ~= "preparing") then
                return
            end
            if ctl.state.status == "preparing" then
                edit_task(false)
                return
            end
            local round = round_for(ctl:current())
            local q = round and round.questions[owner.tab]
            if q then
                owner.note_option = owner.option
                focus_input(true)
            end
        end)
        for key, field in pairs({ C = "capacity_minutes", B = "reserve_minutes" }) do
            map(pop, key, function()
                assert(not ctl.busy, "Stop current request first")
                assert(ctl.state.status == "preparing", "Change time during preparation")
                vim.ui.input({ prompt = field .. ": ", default = tostring(ctl.state[field]) }, function(v)
                    if v then
                        local n = tonumber(v)
                        if n then
                            ctl.state[field] = n
                            ctl:save()
                        end
                    end
                end)
            end)
        end
        map(pop, "L", function()
            assert(not ctl.busy, "Stop first")
            assert(ctl.state.status == "preparing", "Change locks during preparation")
            local e = ctl.state.queue[owner.selection]
            if e then
                e.locked = not e.locked
                ctl.state.locks_confirmed = false
                ctl:save()
            end
        end)
        map(pop, "S", function()
            ctl.state.locks_confirmed = true
            local ok, err = ctl:prepare(true)
            assert(ok, err)
            ctl:start()
        end)
    end
    for _, key in ipairs({ "j", "<Down>" }) do
        map(owner.questions, key, function()
            choice(1)
        end)
    end
    for _, key in ipairs({ "k", "<Up>" }) do
        map(owner.questions, key, function()
            choice(-1)
        end)
    end
    map(owner.questions, "gg", function()
        owner.selection = 1
        owner.option = 1
        render()
    end)
    map(owner.questions, "G", function()
        choice(100000)
    end)
    for key, direction in pairs({ ["<C-d>"] = 1, ["<C-u>"] = -1 }) do
        map(owner.questions, key, function()
            local height = valid(owner.questions) and vim.api.nvim_win_get_height(owner.questions.winid) or 10
            choice(direction * math.max(1, math.floor(height / (ctl.state.status == "preparing" and 8 or 4))))
        end)
    end
    action(owner.questions, "toggle", toggle)
    for name, delta in pairs({ previous_question = -1, next_question = 1 }) do
        action(owner.questions, name, function()
            if ctl.permission or owner.mode_picker or owner.queue_open or ctl.state.status == "preparing" then
                return
            end
            local round = round_for(ctl:current())
            if round then
                local previous = { tab = owner.tab, option = owner.option }
                owner.option_positions[round.id .. ":" .. owner.tab] = owner.option
                owner.tab = (owner.tab - 1 + delta) % (#round.questions + 1) + 1
                owner.option = owner.option_positions[round.id .. ":" .. owner.tab] or 1
                owner.note_option = nil
                owner.preview_from = owner.tab > #round.questions and previous or nil
                render()
            end
        end)
    end
    action(owner.questions, "select", function()
        if ctl.permission then
            return
        end
        if owner.mode_picker then
            ctl:set_mode(({ "plan", "build", "auto" })[owner.mode_option or 1])
            owner.mode_picker = false
            render()
            return
        end
        if owner.queue_open and ctl.state.status ~= "preparing" then
            owner.queue_open = false
            render()
            return
        end
        if ctl.state.status == "preparing" then
            ctl.state.locks_confirmed = true
            ctl:save()
            return
        end
        local round = round_for(ctl:current())
        if not round then
            return
        end
        local q = round.questions[owner.tab]
        if not q then
            submit()
            return
        end
        local option = q.options[owner.option]
        if not option then
            owner.note_option = nil
            focus_input(true)
            return
        end
        local a = answer(round, q)
        if q.multiple then
            toggle()
        else
            a.selected = { [option.id] = true }
            cache_later()
        end
        owner.option_positions[round.id .. ":" .. owner.tab] = owner.option
        if owner.tab < #round.questions then
            owner.tab = owner.tab + 1
            owner.option = owner.option_positions[round.id .. ":" .. owner.tab] or 1
            owner.note_option = nil
            select_context(true)
            render()
            if valid(owner.questions) then
                vim.api.nvim_set_current_win(owner.questions.winid)
            end
        else
            owner.preview_from = { tab = owner.tab, option = owner.option }
            owner.tab = #round.questions + 1
            owner.note_option = nil
            render()
            if valid(owner.questions) then
                vim.api.nvim_set_current_win(owner.questions.winid)
            end
        end
    end)
    owner.group = vim.api.nvim_create_augroup("TodoDaily" .. owner.timeline.bufnr, { clear = true })
    vim.api.nvim_create_autocmd("ModeChanged", { group = owner.group, callback = schedule_render })
    vim.api.nvim_create_autocmd("WinEnter", { group = owner.group, callback = schedule_render })
    for _, key in ipairs({ "j", "k", "<C-u>", "<C-d>", "gg", "G" }) do
        map(owner.timeline, key, function()
            owner.follow_reply = key == "G"
            if owner.follow_reply then
                owner.unread_reply = false
            end
            local raw = vim.api.nvim_replace_termcodes(key, true, false, true)
            vim.cmd("normal! " .. (vim.v.count > 0 and tostring(vim.v.count) or "") .. raw)
        end)
    end
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = owner.group,
        callback = function()
            view.theme()
            schedule_render()
        end,
    })
    local task_version = snapshot:version("task")
    vim.api.nvim_create_autocmd("User", {
        group = owner.group,
        pattern = "TodoWorkspaceChanged",
        callback = function(event)
            local legacy = not event.data or not event.data.changes
            if legacy then
                snapshot:invalidate()
            end
            if legacy or task_version ~= snapshot:version("task") then
                owner.refresh_queue = true
                task_version = snapshot:version("task")
            end
            schedule_render()
        end,
    })
    require("todo.ui.responsive").watch(owner, function()
        layout_signature = nil
        reflow()
        render()
    end)
    owner.render = render
    owner.submit = submit
    owner.focus_input = focus_input
    render()
    if valid(owner.questions) then
        vim.api.nvim_set_current_win(owner.questions.winid)
    elseif valid(owner.timeline) then
        vim.api.nvim_set_current_win(owner.timeline.winid)
    end
    return owner
end
function M.close()
    if current then
        current.close()
    end
end
function M.inspect_state()
    return current
end
return M
