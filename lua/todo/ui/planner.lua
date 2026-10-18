local M = {}
local Popup = require("nui.popup")
local Layout = require("nui.layout")
local hints = require("todo.ui.hints")
local current
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
local function dependencies()
    local todo = require("todo")
    local svc = todo._service()
    local ws = require("todo.workspace").new(svc.store)
    return ws, svc, require("todo.planning").new(ws, svc), todo._ai()
end
local function safe(fn)
    return function(...)
        local args = { ... }
        local count = select("#", ...)
        local ok, err = xpcall(function()
            return fn(unpack(args, 1, count))
        end, debug.traceback)
        if not ok then
            require("todo.diagnostics").record({
                operation = "TUI",
                stage = "action",
                status = "failed",
                error = tostring(err),
            })
            vim.notify(tostring(err):match("^[^\n]+") .. "\n:Todo diagnostics", vim.log.levels.ERROR)
        end
    end
end
local function surface(title, opts)
    opts = opts or {}
    vim.cmd("stopinsert")
    require("todo.ui.highlights").setup()
    if current then
        current.close()
    end
    local width = math.max(1, math.min(140, vim.o.columns - 6))
    local height = math.max(1, math.min(42, vim.o.lines - 6))
    local split = opts.split and width >= 100
    local pop = Popup({
        enter = true,
        border = { style = "rounded", text = { top = " " .. title .. " ", top_align = "left" } },
        win_options = {
            wrap = not split,
            cursorline = true,
            number = false,
            relativenumber = false,
            winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder,CursorLine:TodoSelected",
        },
    })
    local footer = Popup({
        focusable = false,
        border = { style = "none" },
        win_options = { wrap = false, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    })
    local composer = opts.composer
            and Popup({
                enter = false,
                border = { style = "rounded", text = { top = " " .. L("Message", "消息") .. " ", top_align = "left" } },
                buf_options = { buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = true },
                win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
            })
        or nil
    local detail = opts.split
            and Popup({
                border = {
                    style = "rounded",
                    text = { top = " " .. L("Details", "详情") .. " ", top_align = "left" },
                },
                win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
            })
        or nil
    local responsive = require("todo.ui.responsive")
    local function geometry()
        local size = responsive.size(140, 42, 6)
        local main = detail
                and size.width >= 100
                and Layout.Box(
                    { Layout.Box(pop, { size = "58%" }), Layout.Box(detail, { size = "42%" }) },
                    { dir = "row", grow = 1 }
                )
            or Layout.Box(pop, { grow = 1 })
        local boxes = { main }
        if composer and size.height >= 12 then
            boxes[#boxes + 1] = Layout.Box(composer, { size = 5 })
        end
        if size.height >= 9 then
            boxes[#boxes + 1] = Layout.Box(footer, { size = 2 })
        end
        return { relative = "editor", position = "50%", size = size }, Layout.Box(boxes, { dir = "col" })
    end
    local geometry_config, box = geometry()
    local layout = Layout(geometry_config, box)
    layout:mount()
    local owner = { popup = pop, detail = detail, footer = footer, composer = composer, layout = layout, closed = false }
    function owner.close()
        if owner.closed then
            return
        end
        owner.closed = true
        if owner.group then
            pcall(vim.api.nvim_del_augroup_by_id, owner.group)
        end
        hints.close(owner)
        layout:unmount()
        if detail then
            pcall(detail.unmount, detail)
        end
        if composer then
            pcall(composer.unmount, composer)
        end
        pcall(footer.unmount, footer)
        if current == owner then
            current = nil
        end
    end
    local function write(buf, lines)
        if owner.closed or not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
    end
    function owner.write(lines)
        write(pop.bufnr, lines)
    end
    function owner.write_detail(lines)
        if detail then
            write(detail.bufnr, lines)
            require("todo.ui.markdown").attach(detail.bufnr)
        end
    end
    function owner.map(key, fn)
        vim.keymap.set("n", key, safe(fn), { buffer = pop.bufnr, silent = true })
    end
    function owner.row()
        return vim.api.nvim_win_get_cursor(pop.winid)[1]
    end
    owner.map("q", owner.close)
    owner.map("<Esc>", owner.close)
    if detail then
        vim.keymap.set("n", "h", function()
            vim.api.nvim_set_current_win(pop.winid)
        end, { buffer = detail.bufnr })
        vim.keymap.set("n", "q", owner.close, { buffer = detail.bufnr })
        vim.keymap.set("n", "<Esc>", function()
            vim.api.nvim_set_current_win(pop.winid)
        end, { buffer = detail.bufnr })
    end
    owner.map("l", function()
        if detail and detail.winid and vim.api.nvim_win_is_valid(detail.winid) then
            vim.api.nvim_set_current_win(detail.winid)
        end
    end)
    owner.group = vim.api.nvim_create_augroup("TodoPlanner" .. pop.bufnr, { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = owner.group,
        pattern = "TodoWorkspaceChanged",
        callback = function()
            vim.schedule(function()
                if not owner.closed and owner.on_refresh then
                    owner.on_refresh()
                end
            end)
        end,
    })
    responsive.watch(owner, function()
        local next_config, next_box = geometry()
        layout:update(next_config, next_box)
        if owner.reflow_footer then
            owner.reflow_footer()
        end
    end)
    vim.api.nvim_create_autocmd("WinClosed", {
        group = owner.group,
        pattern = tostring(pop.winid),
        callback = function()
            vim.schedule(owner.close)
        end,
    })
    current = owner
    return owner
end
local function editor(title, text, on_save, store, on_asset)
    local previous_win = vim.api.nvim_get_current_win()
    local pop = Popup({
        relative = "editor",
        position = "50%",
        size = {
            width = math.max(1, math.min(95, vim.o.columns - 8)),
            height = math.max(1, math.min(15, vim.o.lines - 8)),
        },
        enter = true,
        border = {
            style = "rounded",
            text = {
                top = " " .. title .. " ",
                bottom = " NORMAL: Enter / Esc " .. L("save & return", "保存并返回") .. " · :w ",
                top_align = "left",
            },
        },
        win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoHeader" },
        zindex = 120,
    })
    pop:mount()
    require("todo.ui.responsive").popup(pop, 95, 15)
    vim.bo[pop.bufnr].filetype = "markdown"
    vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
    if store then
        require("todo.assets").attach(pop.bufnr, store, { on_asset = on_asset })
    end
    local commands
    local function close()
        vim.cmd("stopinsert")
        if commands then
            commands.dispose()
        end
        pop:unmount()
        if vim.api.nvim_win_is_valid(previous_win) then
            vim.api.nvim_set_current_win(previous_win)
        end
    end
    local saved_text
    local function persist()
        local value = table.concat(vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false), "\n")
        if value ~= saved_text then
            local result, err = on_save(value)
            if result == false then
                error(err or "Save failed")
            end
            saved_text = value
        end
        return true
    end
    local function save()
        persist()
        close()
    end
    commands = require("todo.ui.editor_commands").attach(pop, { save = persist, close = close })
    for _, key in ipairs({ "<CR>", "<Esc>" }) do
        vim.keymap.set("n", key, safe(save), { buffer = pop.bufnr, silent = true, nowait = true })
    end
    vim.keymap.set("n", "<Plug>(TodoEditorCancel)", close, { buffer = pop.bufnr, silent = true })
    vim.keymap.set("n", "<C-q>", close, { buffer = pop.bufnr, silent = true })
    vim.keymap.set("i", "<C-q>", "<Esc><Plug>(TodoEditorCancel)", { buffer = pop.bufnr, silent = true })
    vim.cmd("startinsert")
    return pop
end
M.editor = editor
local function help(owner, entries)
    entries = vim.list_extend(entries, {
        { key = "q / Esc", label = L("Close", "关闭") },
        { key = "? / F1", label = L("Complete help", "完整帮助") },
    })
    local provider = function()
        return { title = L("Planner", "工作编排"), actions = entries }
    end
    hints.attach(owner.popup.bufnr, provider, { owner = owner })
    owner.reflow_footer = function()
        if not owner.footer.winid or not vim.api.nvim_win_is_valid(owner.footer.winid) then
            return
        end
        local lines = hints.compact(entries, vim.api.nvim_win_get_width(owner.footer.winid))
        vim.bo[owner.footer.bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(owner.footer.bufnr, 0, -1, false, lines)
        vim.bo[owner.footer.bufnr].modifiable = false
        hints.highlight(owner.footer.bufnr)
    end
    owner.reflow_footer()
    if owner.detail then
        hints.attach(owner.detail.bufnr, function()
            return {
                title = L("Details", "详情"),
                actions = {
                    { key = "j/k, gg/G", label = L("Read details", "浏览详情") },
                    { key = "h / Esc", label = L("Back to list", "返回列表") },
                    { key = "q", label = L("Close", "关闭") },
                },
            }
        end, { owner = owner })
    end
end
function M.chat(opts)
    opts = opts or {}
    local ws, svc, planner, ai = dependencies()
    local s = opts.session_id and ai:resume(opts.session_id) or ai:start(opts)
    local owner = surface(L("AI conversation", "AI 对话"), { split = false, composer = true })
    local request
    local function render()
        s = ai:resume(s.id)
        local usage = ai:usage(s.id)
        local lines = {
            string.format(
                "%s · %s · %d/%d %s · %d/%d API · %s",
                s.scope,
                s.date,
                s.questions,
                s.max_questions,
                L("rounds", "轮"),
                s.requests,
                s.max_requests,
                usage.unknown > 0 and L("cost unknown", "费用未知") or string.format("~$%.5f", usage.usd)
            ),
            "",
        }
        for _, msg in ipairs(s.messages) do
            lines[#lines + 1] = msg.role == "user" and "## " .. L("You", "你") or "## AI"
            vim.list_extend(lines, vim.split(msg.content or "", "\n", { plain = true }))
            for _, hash in ipairs(msg.attachments or {}) do
                lines[#lines + 1] = "![image](todo-asset://" .. hash .. ")"
            end
            lines[#lines + 1] = ""
        end
        if s.last_error then
            lines[#lines + 1] = "Error: " .. s.last_error
        end
        owner.write(lines)
        if vim.api.nvim_win_is_valid(owner.popup.winid) then
            vim.api.nvim_win_set_cursor(owner.popup.winid, { vim.api.nvim_buf_line_count(owner.popup.bufnr), 0 })
        end
        owner.write_detail({
            "# " .. L("Conversation", "对话状态"),
            "",
            "**" .. L("Questions", "已提问") .. "** " .. s.questions .. " / " .. s.max_questions,
            "",
            "**API** " .. s.requests .. " / " .. s.max_requests,
            "",
            "**" .. L("Known cost estimate", "已知费用估算") .. "** $" .. string.format("%.6f", usage.usd),
            "",
            L("Unknown costs: ", "费用未知：") .. usage.unknown,
            "",
            L("Extended changes: ", "扩展修改：") .. tostring(s.extended),
            L("Text only: ", "仅文字：") .. tostring(s.text_only == true),
            "",
            "---",
            "",
            L("Enter / a: answer the current question.", "Enter / a：回答当前问题。"),
            "",
            L("g: generate a draft with what is known.", "g：根据已有信息生成草稿。"),
            "",
            L("v: review changes before applying.", "v：逐条审批后再修改任务。"),
            "",
            "---",
            "",
            L(
                "At the question limit, unknowns become explicit assumptions.",
                "达到问题上限后，未确定的信息会列为假设。"
            ),
        })
        require("todo.ui.markdown").attach(owner.popup.bufnr)
        require("todo.assets").attach(owner.popup.bufnr, svc.store, { readonly = true })
    end
    local function completed(err)
        if owner.closed then
            return
        end
        render()
    end
    local function composer_text()
        return table.concat(vim.api.nvim_buf_get_lines(owner.composer.bufnr, 0, -1, false), "\n")
    end
    local function focus_composer(initial)
        if initial then
            vim.api.nvim_buf_set_lines(owner.composer.bufnr, 0, -1, false, vim.split(initial, "\n", { plain = true }))
        end
        vim.api.nvim_set_current_win(owner.composer.winid)
        vim.cmd("startinsert")
    end
    local function send_composer()
        if ai.active[s.id] and ai.active[s.id].running then
            vim.notify(L("AI is replying", "AI 正在回复"), vim.log.levels.WARN)
            return
        end
        local text = composer_text()
        if vim.trim(text) == "" then
            return
        end
        vim.api.nvim_buf_set_lines(owner.composer.bufnr, 0, -1, false, { "" })
        request = ai:send(s.id, text, {
            on_delta = function(partial)
                s.partial = partial
                render()
            end,
        }, completed)
        s.partial = nil
        render()
    end
    local function answer(initial)
        s = ai:resume(s.id)
        if not initial and s.round and s.round.status == "pending" then
            return M.questions(s.id)
        end
        if ai.active[s.id] and ai.active[s.id].running then
            return
        end
        if owner.composer then
            focus_composer(initial)
        else
            local images = {}
            editor(
                L("Answer AI", "回答 AI"),
                initial or "",
                function(text)
                    request = ai:send(s.id, text, { attachments = images }, completed)
                    if not owner.closed then
                        render()
                    end
                end,
                svc.store,
                function(a)
                    images[#images + 1] = a.hash
                end
            )
        end
    end
    owner.map("a", function()
        answer()
    end)
    owner.map("i", function()
        if owner.composer then
            focus_composer()
        else
            answer()
        end
    end)
    owner.map("<CR>", function()
        answer()
    end)
    if owner.composer then
        for _, key in ipairs({ "<CR>" }) do
            vim.keymap.set("n", key, send_composer, { buffer = owner.composer.bufnr, silent = true })
            vim.keymap.set("i", key, function()
                vim.cmd("stopinsert")
                send_composer()
            end, { buffer = owner.composer.bufnr, silent = true })
        end
        vim.keymap.set({ "i" }, "<S-CR>", "<CR>", { buffer = owner.composer.bufnr, silent = true })
        vim.keymap.set({ "i" }, "<C-J>", "<CR>", { buffer = owner.composer.bufnr, silent = true })
        vim.keymap.set("n", "<Esc>", function()
            vim.api.nvim_set_current_win(owner.popup.winid)
        end, { buffer = owner.composer.bufnr, silent = true })
        vim.keymap.set("n", "q", owner.close, { buffer = owner.composer.bufnr, silent = true })
    end
    owner.map("s", function()
        request =
            ai:send(s.id, L("Skip this question; mark unknown.", "跳过这个问题，标为未知。"), {}, completed)
        render()
    end)
    owner.map("g", function()
        request = ai:generate(s.id, completed)
        render()
    end)
    owner.map("v", function()
        s = ai:resume(s.id)
        if s.draft_id then
            M.review(s.draft_id)
        else
            vim.notify(L("No draft yet", "尚无草稿"))
        end
    end)
    owner.map("c", function()
        if ai.active[s.id] and ai.active[s.id].running then
            ai.active[s.id].cancel()
        end
    end)
    owner.map("+", function()
        vim.ui.input({ prompt = L("Additional questions: ", "增加问题数量："), default = "3" }, function(n)
            if n then
                ai:increase_limit(s.id, assert(tonumber(n)))
                render()
            end
        end)
    end)
    owner.map("V", function()
        assert(not ai.active[s.id], "request running")
        s = ai:resume(s.id)
        s.text_only = not s.text_only
        ws:put("conversation", s.id, s)
        render()
    end)
    owner.map("E", function()
        assert(not ai.active[s.id], "request running")
        s = ai:resume(s.id)
        s.extended = not s.extended
        ws:put("conversation", s.id, s)
        render()
    end)
    if owner.composer then
        vim.keymap.set("n", "V", safe(function()
            assert(not ai.active[s.id], "request running")
            s = ai:resume(s.id)
            s.text_only = not s.text_only
            ws:put("conversation", s.id, s)
            render()
        end), { buffer = owner.composer.bufnr, silent = true })
        vim.keymap.set("n", "E", safe(function()
            assert(not ai.active[s.id], "request running")
            s = ai:resume(s.id)
            s.extended = not s.extended
            ws:put("conversation", s.id, s)
            render()
        end), { buffer = owner.composer.bufnr, silent = true })
    end
    help(owner, {
        { key = "a / i", label = L("Answer with text/images", "回答文字或图片") },
        { key = "g", label = L("Generate draft now", "立即生成草稿") },
        { key = "v", label = L("Review draft", "审批草稿") },
        { key = "s", label = L("Skip question", "跳过问题") },
        { key = "V", label = L("Toggle text only", "切换仅文字模式") },
        { key = "E", label = L("Toggle extended changes", "切换扩展修改") },
        { key = "+", label = L("Increase question allowance", "增加问题额度") },
        { key = "c", label = L("Cancel request", "取消请求") },
    })
    owner.on_refresh = render
    owner.on_resize = function()
        M.chat({ session_id = s.id })
    end
    render()
    if opts.initial then
        if opts.send_initial then
            request = ai:send(s.id, opts.initial, {
                on_delta = function(partial)
                    s.partial = partial
                    render()
                end,
            }, completed)
            s.partial = nil
            render()
        else
            answer(opts.initial)
        end
    end
    return owner
end
function M.review(id)
    local ws, svc, planner, ai = dependencies()
    local draft = assert(ws:get("draft", id), "draft not found")
    local owner = surface(L("Review AI draft", "审批 AI 草稿"), { split = true })
    local rows, selected = {}, {}
    for _, c in ipairs(draft.changes) do
        selected[c.id] = c.selected == true
    end
    local function save()
        for _, c in ipairs(draft.changes) do
            c.selected = selected[c.id]
        end
        ws:put("draft", id, draft)
    end
    local names = {
        plan_add = L("Add to plan", "加入计划"),
        plan_update = L("Adjust arrangement", "调整安排"),
        plan_remove = L("Remove from plan", "移出计划"),
        note = L("Add note", "添加备注"),
        description = L("Clarify description", "补充描述"),
        task_update = L("Update task", "修改任务"),
        task_create = L("Create task", "新建任务"),
    }
    local function readable(value)
        value = value or {}
        local out = {}
        for _, field in ipairs({
            { "title", "Title", "标题" },
            { "description", "Description", "描述" },
            { "text", "Note", "备注" },
            { "deadline", "Deadline", "截止时间" },
            { "due_date", "Due date", "截止日期" },
            { "due_time", "Due time", "截止时刻" },
            { "status", "Status", "状态" },
            { "priority", "Priority", "优先级" },
            { "minutes", "Minutes", "分钟" },
            { "group", "Group", "分组" },
            { "next_action", "Next action", "下一步" },
            { "completion", "Done when", "完成标准" },
            { "position", "Order", "顺序" },
            { "locked", "Locked", "已锁定" },
        }) do
            local v = value[field[1]]
            if v ~= nil and v ~= "" then
                out[#out + 1] = "**" .. L(field[2], field[3]) .. "**"
                vim.list_extend(out, vim.split(tostring(v), "\n", { plain = true }))
                out[#out + 1] = ""
            end
        end
        if #out == 0 then
            return { L("No existing content", "无已有内容") }
        end
        return out
    end
    local function preview(c)
        if not c then
            return {
                "# " .. L("Review changes", "逐条审批"),
                "",
                L("Select a suggestion to compare its contents.", "选择一条建议，查看修改前后。"),
            }
        end
        local before = c.before or (c.task_uuid and select(1, ws:get("task", c.task_uuid))) or {}
        if c.kind:match("^plan_") then
            for _, item in ipairs(planner:today(draft.date).items) do
                if item.task_uuid == c.task_uuid then
                    before = item
                end
            end
        end
        local lines =
            { "# " .. (names[c.kind] or c.kind), "", c.reason or "", "", "## " .. L("Before", "修改前"), "" }
        vim.list_extend(lines, readable(before))
        lines[#lines + 1] = "---"
        lines[#lines + 1] = "## " .. L("After", "修改后")
        lines[#lines + 1] = ""
        vim.list_extend(lines, readable(c.after))
        return lines
    end
    local function render()
        rows = {}
        local count = 0
        for _, v in pairs(selected) do
            if v then
                count = count + 1
            end
        end
        local lines = {
            L("READY FOR REVIEW", "等待审批") .. "  " .. count .. " / " .. #draft.changes .. " " .. L(
                "selected",
                "已选"
            ),
            draft.summary or "",
            "",
        }
        for _, c in ipairs(draft.changes) do
            local task = c.task_uuid and planner:task(c.task_uuid)
            lines[#lines + 1] = string.format(
                " %s  %s · %s",
                selected[c.id] and "✓" or "○",
                names[c.kind] or c.kind,
                task and task.title or (c.after and c.after.title) or L("New task", "新任务")
            )
            rows[#lines] = c
            lines[#lines + 1] = "      " .. (c.reason or L("Review details before accepting", "查看详情后接受"))
            rows[#lines] = c
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = L("Unresolved: ", "未确定事项：")
            .. table.concat(
                type(draft.unresolved) == "table" and draft.unresolved or { tostring(draft.unresolved) },
                " · "
            )
        owner.write(lines)
        owner.write_detail(preview(rows[owner.row()]))
    end
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = owner.popup.bufnr,
        callback = function()
            if not owner.closed then
                owner.write_detail(preview(rows[owner.row()]))
            end
        end,
    })
    owner.map("<Space>", function()
        local c = rows[owner.row()]
        if c then
            selected[c.id] = not selected[c.id]
            save()
            render()
        end
    end)
    owner.map("<CR>", function()
        local c = rows[owner.row()]
        if not c then
            return
        end
        if owner.detail then
            owner.write_detail(preview(c))
            vim.api.nvim_set_current_win(owner.detail.winid)
        else
            local view = surface(L("Change details", "修改详情"))
            view.write(preview(c))
            view.map("h", function()
                M.review(id)
            end)
            require("todo.ui.markdown").attach(view.popup.bufnr)
        end
    end)
    owner.map("e", function()
        local c = rows[owner.row()]
        if not c then
            return
        end
        local fields
        if c.kind == "note" then
            fields = { { "text", "Note", "备注" } }
        elseif c.kind == "description" then
            fields = { { "description", "Description", "描述" } }
        elseif c.kind == "plan_add" or c.kind == "plan_update" then
            fields = {
                { "next_action", "Next action", "下一步" },
                { "completion", "Done when", "完成标准" },
                { "minutes", "Minutes", "分钟" },
                { "group", "Group", "分组" },
                { "position", "Order", "顺序" },
            }
        elseif c.kind == "task_update" then
            fields = {
                { "deadline", "Deadline", "截止时间" },
                { "priority", "Priority", "优先级" },
                { "status", "Status", "状态" },
            }
        elseif c.kind == "task_create" then
            fields = {
                { "title", "Title", "标题" },
                { "description", "Description", "描述" },
                { "deadline", "Deadline", "截止时间" },
                { "reminder_interval", "Reminder interval", "提醒间隔" },
                { "priority", "Priority", "优先级" },
            }
        end
        if not fields then
            return
        end
        local function edit(field)
            local key = field[1]
            local old = c.after[key]
            local function changed(value)
                c.after[key] = value
                save()
                render()
            end
            if key == "group" or key == "status" or key == "priority" then
                local values = key == "group" and { "now", "next", "optional" }
                    or key == "status" and { "todo", "in_progress", "done", "cancelled" }
                    or { 0, 1, 2, 3 }
                vim.ui.select(values, { prompt = L(field[2], field[3]) }, function(v)
                    if v ~= nil then
                        changed(v)
                    end
                end)
            elseif key == "minutes" or key == "position" then
                vim.ui.input({ prompt = L(field[2], field[3]) .. ": ", default = tostring(old or 0) }, function(v)
                    local n = tonumber(v)
                    if n and n >= 0 and n % 1 == 0 then
                        changed(n)
                    end
                end)
            else
                editor(L(field[2], field[3]), old or "", changed, svc.store)
            end
        end
        if #fields == 1 then
            edit(fields[1])
        else
            vim.ui.select(fields, {
                prompt = L("Edit proposal", "编辑建议"),
                format_item = function(f)
                    return L(f[2], f[3])
                end,
            }, function(f)
                if f then
                    edit(f)
                end
            end)
        end
    end)
    owner.map("f", function()
        editor(L("Feedback / rejection reasons", "反馈／拒绝原因"), "", function(value)
            save()
            if draft.workflow_id then
                local daily = require("todo.ai.daily").new(ws, svc, ai, draft.date)
                daily:feedback(value .. "\nSelection: " .. vim.json.encode(selected))
                owner.close()
                require("todo.ui.daily").open({ date = draft.date })
            else
                M.chat({
                    session_id = draft.session_id,
                    initial = "Feedback on draft " .. id .. ":\n" .. value .. "\nSelection: " .. vim.json.encode(
                        selected
                    ),
                })
            end
        end, svc.store)
    end)
    owner.map("t", function()
        save()
        if draft.workflow_id then
            owner.close()
            require("todo.ui.daily").open({ date = draft.date })
        else
            M.chat({ session_id = draft.session_id })
        end
    end)
    owner.map("a", function()
        assert(draft.status ~= "applied", "draft already applied")
        assert(vim.tbl_contains(vim.tbl_values(selected), true), "select at least one change")
        planner:apply(draft, selected)
        owner.close()
        require("todo")._reconcile_reminders()
        require("todo.ui.panel").refresh()
        require("todo").today(draft.date)
    end)
    help(owner, {
        { key = "Space", label = L("Select or reject change", "勾选或拒绝修改") },
        { key = "Enter", label = L("Compare before and after", "查看修改前后") },
        { key = "e", label = L("Edit proposal", "编辑建议") },
        { key = "f", label = L("Send feedback to AI", "向 AI 反馈") },
        { key = "a", label = L("Apply selected changes", "提交选中的修改") },
        { key = "t", label = L("Continue conversation", "继续对话") },
    })
    owner.on_resize = function()
        M.review(id)
    end
    render()
    return owner
end
function M.settings()
    local ws = dependencies()
    local cfg = require("todo.config").get().ai
    local profile = (cfg.preferences_source == "workspace" and ws:get("profile", "ai"))
        or { language = cfg.language, persona = cfg.persona }
    local owner = surface(L("AI settings", "AI 设置"), { split = true })
    local function render()
        owner.write({
            "",
            "  " .. L("Response language", "回复语言") .. "   " .. profile.language,
            "",
            "  " .. L("Persona and guidance", "人设与指导"),
            "    " .. profile.persona,
            "",
            L("Provider: ", "提供商：") .. cfg.provider,
            L("Model: ", "模型：") .. cfg.model,
            L("Vision: ", "识图：") .. tostring(require("todo.providers").capabilities(cfg).vision),
            L("Balance lookup: ", "余额查询：") .. tostring(require("todo.providers").capabilities(cfg).balance),
            L("Cost estimates: ", "费用估算：")
                .. (cfg.pricing and L("configured", "已配置费率") or L("unknown", "未知")),
            L("AI enabled: ", "AI 已启用：") .. tostring(cfg.enabled),
            L("Preferences source: ", "偏好设置来源：") .. cfg.preferences_source,
            L("Default questions: ", "默认问题额度：") .. cfg.max_questions,
            L("Default API requests: ", "默认请求额度：") .. cfg.max_requests,
            "",
            L("API key source: ", "密钥来源：")
                .. (select(2, require("todo.credentials").get()) or L("not configured", "未配置")),
        })
        owner.write_detail({
            "# " .. L("AI preferences", "AI 偏好"),
            "",
            L("Language and persona sync between your devices.", "语言和人设会在设备之间同步。"),
            "",
            L(
                "Keys, endpoint and budget defaults remain in your local setup configuration.",
                "密钥、接口地址与默认预算保留在本机 setup 配置中。"
            ),
            "",
            L("Press Enter to edit language or persona.", "按 Enter 编辑语言或人设。"),
        })
    end
    owner.map("<CR>", function()
        vim.ui.select({
            L("Response language", "回复语言"),
            L("Persona and guidance", "人设与指导"),
            L("Paste API key (hidden)", "粘贴 API Key（隐藏输入）"),
            L("Remove local API key", "删除本地 API Key"),
            L("Toggle AI for this session", "本次会话启用／关闭 AI"),
        }, { prompt = L("AI settings", "AI 设置") }, function(choice, index)
            if index == 1 then
                vim.ui.select(
                    { "auto", "zh-CN", "en" },
                    { prompt = L("Response language", "回复语言") },
                    function(v)
                        if v then
                            profile.language = v
                            if cfg.preferences_source == "config" then
                                cfg.language = v
                            end
                            ws:put("profile", "ai", profile)
                            render()
                        end
                    end
                )
            elseif index == 2 then
                editor(L("Persona and guidance", "人设与指导"), profile.persona, function(value)
                    profile.persona = value
                    if cfg.preferences_source == "config" then
                        cfg.persona = value
                    end
                    ws:put("profile", "ai", profile)
                    render()
                end)
            elseif index == 3 then
                require("todo.credentials").prompt()
                render()
            elseif index == 4 then
                require("todo.credentials").clear()
                render()
            elseif index == 5 then
                cfg.enabled = not cfg.enabled
                render()
            end
        end)
    end)
    help(owner, { { key = "Enter", label = L("Edit settings", "编辑设置") } })
    owner.on_resize = function()
        M.settings()
    end
    render()
    return owner
end
function M.questions(id, completed)
    local _, _, _, ai = dependencies()
    local owner = require("todo.ui.questions").open(ai, id, surface, editor, completed or function() end)
    owner.on_submit = function()
        M.chat({ session_id = id })
    end
    return owner
end

function M.memory()
    local ws, svc = dependencies()
    local memory = require("todo.memory").new(ws, svc)
    local owner = surface(L("AI memory", "AI 记忆"))
    local records = {}
    local query = ""
    local function selected()
        return records[owner.row() - 3]
    end
    local function render()
        records = {}
        local lines = {
            L("Confirmed facts and pending inferences", "已确认事实与待确认推断"),
            L("Search: ", "搜索：") .. query,
            "",
        }
        for _, r in ipairs(memory:list(true)) do
            if query == "" or r.value.text:lower():find(query:lower(), 1, true) then
                records[#records + 1] = r
                lines[#lines + 1] = (r.value.pinned and "◆ " or "  ")
                    .. "["
                    .. r.value.status
                    .. " · "
                    .. r.value.scope
                    .. "] "
                    .. r.value.text:gsub("\n", " ")
            end
        end
        owner.write(lines)
    end
    local function update(change)
        local r = selected()
        if not r then
            return
        end
        local opts = vim.tbl_extend("force", r.value, { id = r.id, expected_revision = r.revision })
        change(opts, r)
        memory:save(opts.text, opts)
        render()
    end
    owner.map("c", function()
        update(function(o)
            o.status = "confirmed"
        end)
    end)
    owner.map("p", function()
        update(function(o)
            o.pinned = not o.pinned
        end)
    end)
    owner.map("d", function()
        local r = selected()
        if r then
            memory:remove(r.id)
            render()
        end
    end)
    owner.map("e", function()
        local r = selected()
        if r then
            editor(L("Edit memory", "编辑记忆"), r.value.text, function(v)
                memory:save(v, vim.tbl_extend("force", r.value, { id = r.id, expected_revision = r.revision }))
                render()
            end)
        end
    end)
    owner.map("a", function()
        editor(L("New lasting fact", "新增长期事实"), "", function(v)
            memory:save(v)
            render()
        end)
    end)
    owner.map("/", function()
        vim.ui.input({ prompt = L("Search memory: ", "搜索记忆：") }, function(v)
            if v then
                query = v
                render()
            end
        end)
    end)
    help(owner, {
        { key = "a", label = L("Add fact", "添加事实") },
        { key = "e", label = L("Edit", "编辑") },
        { key = "c", label = L("Confirm inference", "确认推断") },
        { key = "p", label = L("Pin/unpin", "固定／取消固定") },
        { key = "d", label = L("Forget and invalidate summaries", "遗忘并清除衍生摘要") },
        { key = "/", label = L("Search", "搜索") },
    })
    render()
    return owner
end
function M.close()
    if current then
        current.close()
    end
end
function M.balance()
    local _, _, _, ai = dependencies()
    local owner = surface(L("Account balance", "账户余额"))
    local handle
    local function query()
        if handle and handle.running then
            return
        end
        owner.write({
            "",
            L("Querying account balance…", "正在查询账户余额…"),
            "",
            L("You can keep editing. No model request is made.", "可继续编辑，不会调用模型。"),
        })
        handle = ai:balance(function(err, value)
            if owner.closed then
                return
            end
            if err then
                owner.write({
                    L("Balance unavailable", "余额查询失败"),
                    "",
                    tostring(err),
                    "",
                    ":Todo diagnostics",
                })
                return
            end
            local lines = {
                L("ACCOUNT BALANCE", "账户余额"),
                "",
                L("Account available: ", "账户可用：") .. tostring(value.is_available),
                "",
            }
            for _, info in ipairs(value.balance_infos) do
                lines[#lines + 1] = "  " .. tostring(info.currency or "—")
                lines[#lines + 1] = "    "
                    .. L("Total remaining", "剩余总额")
                    .. "    "
                    .. tostring(info.total_balance or "—")
                lines[#lines + 1] = "    "
                    .. L("Granted credit", "剩余赠金")
                    .. "    "
                    .. tostring(info.granted_balance or "—")
                lines[#lines + 1] = "    "
                    .. L("Topped-up credit", "充值余额")
                    .. "    "
                    .. tostring(info.topped_up_balance or "—")
                lines[#lines + 1] = ""
            end
            if #value.balance_infos == 0 then
                lines[#lines + 1] = L("No balance details returned", "接口未返回余额明细")
            end
            lines[#lines + 1] =
                L("Granted credit is spent first and may expire.", "赠金优先扣费，可能过期。")
            lines[#lines + 1] = L(
                "Token cost estimates are separate; currencies are not converted.",
                "余额与 token 费用估算分开显示，不自动换算币种。"
            )
            owner.write(lines)
        end)
    end
    owner.map("r", query)
    owner.map("c", function()
        if handle and handle.cancel then
            handle.cancel()
        end
    end)
    help(owner, {
        { key = "r", label = L("Refresh balance", "刷新余额") },
        {
            key = "c",
            label = L("Cancel request", "取消请求"),
        },
    })
    query()
    return owner
end
function M.clarify(id)
    local ws, svc = dependencies()
    local task = assert(svc.store:get(id), "task not found")
    local latest
    for _, record in ipairs(ws:list("conversation")) do
        local value = record.value
        if value.scope == "clarify" and value.task_uuid == task.sync_uuid then
            if not latest or (value.created_at or 0) > (latest.value.created_at or 0) then
                latest = record
            end
        end
    end
    if latest then
        return M.chat({ session_id = latest.key })
    end
    return M.chat({ task_id = id })
end

function M.sessions(opts)
    local ws, svc = dependencies()
    local target = opts.task_id and svc.store:get(opts.task_id)
    local rows = ws:list("conversation")
    table.sort(rows, function(a, b)
        return (a.value.created_at or 0) > (b.value.created_at or 0)
    end)
    local choices = { { new = true, label = L("New conversation", "新建对话") } }
    for _, r in ipairs(rows) do
        if (target and r.value.task_uuid == target.sync_uuid) or (not opts.task_id and r.value.scope == "plan") then
            choices[#choices + 1] = {
                id = r.key,
                label = r.value.date .. " · " .. r.value.scope .. " · " .. r.value.questions .. " questions",
            }
        end
    end
    if #choices == 1 then
        return M.chat(opts)
    end
    vim.ui.select(choices, {
        prompt = L("Resume or start", "继续或新建"),
        format_item = function(i)
            return i.label
        end,
    }, function(i)
        if i then
            if i.new then
                M.chat(opts)
            else
                M.chat({ session_id = i.id })
            end
        end
    end)
end
function M.conflicts()
    local ws = dependencies()
    local conflicts = ws:cloud_status().conflicts
    vim.ui.select(conflicts, {
        prompt = L("Sync conflicts", "同步冲突"),
        format_item = function(i)
            return i.kind .. "/" .. i.key
        end,
    }, function(c)
        if not c then
            return
        end
        vim.ui.select(
            { "local", "remote" },
            { prompt = L("Choose version to keep", "选择保留的版本") },
            function(choice)
                if choice then
                    ws:resolve(c.kind, c.key, choice)
                end
            end
        )
    end)
end
return M
