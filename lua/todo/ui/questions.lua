local M = {}
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
function M.open(ai, id, surface, editor, completed)
    local session = ai:resume(id)
    local round = assert(session.round, "No pending question round")
    assert(round.status == "pending", "Round already submitted")
    local owner = surface(L("Questions", "问题"))
    owner.round = round
    local rows = {}
    local ns = vim.api.nvim_create_namespace("TodoQuestions")
    -- Per-question option cursor lives in memory only: navigation never writes the database.
    local cursor = {}
    local preview = false
    local submitted = false
    local function save()
        local latest = ai:resume(id)
        assert(
            latest.round and latest.round.id == round.id and latest.round.status == "pending",
            "Question round changed"
        )
        latest.round = round
        ai.ws:put("conversation", id, latest)
    end
    local function answer(q)
        round.answers[q.id] = round.answers[q.id] or { selected = {}, notes = {} }
        return round.answers[q.id]
    end
    local function qcurrent()
        return round.questions[round.tab]
    end
    local function selected()
        local value = cursor[round.tab] or 1
        local q = qcurrent()
        if not q then
            return 1
        end
        return math.max(1, math.min(#q.options + 1, value))
    end
    local function set_selected(value)
        local q = qcurrent()
        if not q then
            return
        end
        cursor[round.tab] = math.max(1, math.min(#q.options + 1, value))
    end
    local function guarded(fn)
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
    local function nmap(key, fn, nowait)
        vim.keymap.set("n", key, guarded(fn), {
            buffer = owner.popup.bufnr,
            silent = true,
            nowait = nowait == true,
        })
    end
    local function transcript()
        local lines = {}
        for _, question in ipairs(round.questions) do
            lines[#lines + 1] = "## " .. question.question
            local copy = { id = round.id, questions = { question }, answers = round.answers }
            local text = require("todo.ai.questions").transcript(copy)
            vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
        end
        return lines
    end
    local function render()
        local question = qcurrent()
        local lines = { L("Questions", "问题") .. "  " .. round.tab .. " / " .. (#round.questions + 1), "" }
        -- Wrap tab labels explicitly using display cells, retaining every question.
        local width = vim.api.nvim_win_get_width(owner.popup.winid)
        local tabs = ""
        for i = 1, #round.questions + 1 do
            local q = round.questions[i]
            local token = (i == round.tab and "▸ " or "  ") .. (q and q.header or L("Submit", "提交")) .. "  "
            if vim.fn.strdisplaywidth(tabs .. token) > width and tabs ~= "" then
                lines[#lines + 1] = tabs
                tabs = ""
            end
            tabs = tabs .. token
        end
        lines[#lines + 1] = tabs
        lines[#lines + 1] = ""
        rows = {}
        local heading
        if question and not preview then
            heading = #lines
            lines[#lines + 1] = (question.multiple and L("[Multiple] ", "[多选] ") or L("[Single] ", "[单选] "))
                .. question.question
            lines[#lines + 1] = ""
            local a = answer(question)
            local current = selected()
            for i, o in ipairs(question.options) do
                rows[i] = #lines + 1
                lines[#lines + 1] = string.format(
                    "%s %d. [%s] %s",
                    current == i and "›" or " ",
                    i,
                    a.selected[o.id] and "✓" or " ",
                    o.label
                )
                if o.description then
                    lines[#lines + 1] = "       " .. o.description
                end
                if a.notes[o.id] and a.notes[o.id] ~= "" then
                    lines[#lines + 1] = "       ↳ " .. a.notes[o.id]
                end
            end
            rows[#question.options + 1] = #lines + 1
            lines[#lines + 1] = (current == #question.options + 1 and "› " or "  ")
                .. L("Your answer: ", "自定义回答：")
                .. (a.custom or "")
        else
            if preview then
                lines[#lines + 1] = L("Submit preview, sent once.", "提交预览，仅发送一次。")
                lines[#lines + 1] = ""
            end
            vim.list_extend(lines, transcript())
            lines[#lines + 1] = L(
                "Enter submits once. Unanswered questions remain unknown.",
                "Enter 一次性提交；未回答的问题将标为未知。"
            )
        end
        owner.write(lines)
        vim.api.nvim_buf_clear_namespace(owner.popup.bufnr, ns, 0, -1)
        vim.api.nvim_buf_add_highlight(owner.popup.bufnr, ns, "TodoHeader", 0, 0, -1)
        if question and not preview then
            vim.api.nvim_buf_add_highlight(owner.popup.bufnr, ns, "TodoHeader", heading, 0, -1)
            local a = answer(question)
            for i, o in ipairs(question.options) do
                local row = rows[i]
                if row then
                    vim.api.nvim_buf_add_highlight(
                        owner.popup.bufnr,
                        ns,
                        a.selected[o.id] and "TodoTabActive" or "NormalFloat",
                        row - 1,
                        0,
                        -1
                    )
                    for detail = row + 1, (rows[i + 1] or #lines) - 1 do
                        if lines[detail] and lines[detail]:sub(1, 1) == " " then
                            vim.api.nvim_buf_add_highlight(owner.popup.bufnr, ns, "TodoMuted", detail - 1, 0, -1)
                        end
                    end
                end
            end
        end
        if vim.api.nvim_win_is_valid(owner.popup.winid) then
            local target = (question and not preview) and rows[selected()] or 1
            pcall(vim.api.nvim_win_set_cursor, owner.popup.winid, { target or 1, 0 })
        end
        local entries
        if preview then
            entries = {
                { key = "Enter", label = L("Submit once", "提交一次") },
                { key = "Esc", label = L("Back to question", "返回问题") },
            }
        elseif question then
            entries = {
                { key = "j/k", label = L("Select", "选择") },
                { key = "Space/Enter", label = L("Toggle, stay here", "勾选，不跳题") },
                { key = "h/l Tab", label = L("Switch question", "切换问题") },
                { key = "e", label = L("Note", "说明") },
                { key = "i", label = L("Answer", "回答") },
                { key = "w", label = L("Preview", "预览") },
                { key = "q/Esc", label = L("Hide", "保留并关闭") },
            }
        else
            entries = {
                { key = "Enter", label = L("Submit", "提交") },
                { key = "h/l Tab", label = L("Switch question", "切换问题") },
                { key = "q/Esc", label = L("Hide", "保留并关闭") },
            }
        end
        local footer_width = owner.footer.winid
                and vim.api.nvim_win_is_valid(owner.footer.winid)
                and vim.api.nvim_win_get_width(owner.footer.winid)
            or 20
        local footer = require("todo.ui.hints").lines(entries, footer_width, 2)
        vim.bo[owner.footer.bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(owner.footer.bufnr, 0, -1, false, footer)
        vim.bo[owner.footer.bufnr].modifiable = false
        require("todo.ui.hints").highlight(owner.footer.bufnr)
    end
    local function edit(custom)
        if preview then
            return
        end
        local q = qcurrent()
        if not q then
            return
        end
        local a = answer(q)
        local o = q.options[selected()]
        if custom or not o then
            editor(L("Custom answer", "自定义回答"), a.custom, function(v)
                a.custom = v
                save()
                render()
            end, ai.service.store)
        else
            -- Annotate any option, whether selected or not.
            editor(L("Option note", "选项附加说明") .. ": " .. o.label, a.notes[o.id], function(v)
                a.notes[o.id] = v
                save()
                render()
            end, ai.service.store)
        end
    end
    local function move(delta, absolute)
        local q = qcurrent()
        if not q or preview then
            return
        end
        set_selected(absolute or selected() + delta)
        render()
    end
    local function switch(delta, absolute)
        if preview then
            return
        end
        cursor[round.tab] = selected()
        round.tab = absolute or (round.tab - 1 + delta) % (#round.questions + 1) + 1
        render()
    end
    local function pick()
        if preview then
            return
        end
        local q = qcurrent()
        if not q then
            return
        end
        local o = q.options[selected()]
        if not o then
            edit(true)
            return
        end
        local a = answer(q)
        local was = a.selected[o.id]
        if not q.multiple then
            a.selected = {}
        end
        a.selected[o.id] = not was or nil
        round.selected = selected()
        save()
        render()
    end
    local function submit()
        if submitted then
            return
        end
        assert(not ai.active[id], "Request running")
        local latest = ai:resume(id)
        assert(
            latest.round and latest.round.id == round.id and latest.round.status == "pending",
            "Round already submitted"
        )
        submitted = true
        save()
        owner.close()
        if owner.on_submit then
            owner.on_submit()
        end
        ai:send(id, require("todo.ai.questions").transcript(round), { round_id = round.id }, completed)
    end
    nmap("j", function()
        move(1)
    end)
    nmap("<Down>", function()
        move(1)
    end)
    nmap("k", function()
        move(-1)
    end)
    nmap("<Up>", function()
        move(-1)
    end)
    nmap("gg", function()
        move(0, 1)
    end)
    nmap("G", function()
        local q = qcurrent()
        if q then
            move(0, #q.options + 1)
        end
    end)
    nmap("<C-d>", function()
        move(math.max(1, math.floor(vim.api.nvim_win_get_height(owner.popup.winid) / 4)))
    end)
    nmap("<C-u>", function()
        move(-math.max(1, math.floor(vim.api.nvim_win_get_height(owner.popup.winid) / 4)))
    end)
    for _, key in ipairs({ "l", "<Tab>", "<Right>" }) do
        nmap(key, function()
            switch(1)
        end, true)
    end
    for _, key in ipairs({ "h", "<S-Tab>", "<Left>" }) do
        nmap(key, function()
            switch(-1)
        end, true)
    end
    nmap("<Space>", pick, true)
    nmap("e", function()
        edit(false)
    end, true)
    nmap("i", function()
        edit(true)
    end, true)
    nmap("w", function()
        preview = not preview
        render()
    end, true)
    nmap("<Esc>", function()
        if preview then
            preview = false
            render()
            return
        end
        owner.close()
    end, true)
    nmap("<CR>", function()
        local q = qcurrent()
        if preview or not q then
            submit()
            return
        end
        if q.options[selected()] then
            pick()
            return
        end
        edit(true)
    end, true)
    for n = 1, 9 do
        nmap(tostring(n), function()
            local q = qcurrent()
            if q and not preview and n <= #q.options + 1 then
                set_selected(n)
                pick()
            end
        end)
    end
    require("todo.ui.hints").attach(owner.popup.bufnr, function()
        return {
            title = L("Questions", "问题"),
            actions = {
                { key = "j/k / ↑↓", label = L("Select option", "选择选项") },
                { key = "gg/G / Ctrl-u/d", label = L("First/last or half page", "首尾选项／半页") },
                { key = "Space / Enter", label = L("Toggle option, stay on question", "勾选选项，不跳题") },
                { key = "Tab / h/l", label = L("Switch questions, cursor remembered", "切换问题，记住光标") },
                {
                    key = "e",
                    label = L("Annotate any option, selected or not", "为任意选项附加说明，无需勾选"),
                },
                { key = "i", label = L("Custom answer (Markdown)", "自定义回答（Markdown）") },
                {
                    key = "w",
                    label = L("Submit preview; Enter submits, Esc returns", "提交预览；Enter 提交，Esc 返回"),
                },
                { key = "q / Esc", label = L("Hide and keep draft", "关闭并保留草稿") },
            },
        }
    end, { owner = owner })
    owner.reflow_footer = render
    render()
    return owner
end
return M
