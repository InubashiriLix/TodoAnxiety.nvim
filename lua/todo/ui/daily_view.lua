-- Screen presentation only. All rows carry byte-based spans so CJK stays aligned.
local M = {}
local combined = {}
local theme_version = 0
local vm = require("todo.ui.viewmodel")
local keys = require("todo.ui.daily_keys")
local contrast = require("todo.ui.contrast")
local generated = {}
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
local function color(name, fallback)
    local h = vim.api.nvim_get_hl(0, { name = name, link = false })
    return h.fg or fallback
end
local function blend(a, b, t)
    local function c(n, s)
        return math.floor(n / 2 ^ s) % 256
    end
    local n = 0
    for _, s in ipairs({ 16, 8, 0 }) do
        n = n + math.floor(c(a, s) * (1 - t) + c(b, s) * t) * 2 ^ s
    end
    return n
end
function M.theme()
    combined = {}
    theme_version = theme_version + 1
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local bg = normal.bg or (vim.o.background == "light" and 0xffffff or 0x171a21)
    local fg = contrast.readable(normal.fg or 0xd7dce5, bg, 9)
    local accent = contrast.readable(color("DiagnosticInfo", 0x80aaff), bg, 4.5)
    local warm = contrast.readable(color("DiagnosticWarn", 0xe9b876), bg, 4.5)
    local panel = blend(bg, fg, 0.045)
    local groups = {
        Surface = { fg = fg, bg = bg },
        Panel = { fg = contrast.readable(fg, panel, 9), bg = panel },
        Text = { fg = fg, italic = false },
        Muted = { fg = contrast.readable(blend(fg, bg, 0.18), bg, 4.5), italic = false },
        Accent = { fg = accent, bold = true },
        Key = { fg = warm, bold = true, italic = false },
        Selected = { fg = fg, bg = blend(bg, accent, 0.22), bold = true },
        Included = { fg = contrast.readable(color("DiagnosticOk", 0xa6d9a2), bg, 4.5) },
        Excluded = { fg = contrast.readable(blend(fg, bg, 0.4), bg, 3) },
        Lock = { fg = warm },
        Tab = { fg = fg, bg = blend(bg, accent, 0.22), bold = true },
        Label = { fg = fg, bold = true },
        Error = { fg = contrast.readable(color("DiagnosticError", 0xf27e86), bg, 4.5) },
        User = { fg = warm, bold = true },
        Overdue = { fg = blend(color("DiagnosticError", 0xf27e86), fg, 0.2) },
        Rule = { fg = contrast.readable(blend(bg, fg, 0.3), bg, 3) },
    }
    for name, h in pairs(groups) do
        local full_name = "TodoDaily" .. name
        local current = vim.api.nvim_get_hl(0, { name = full_name, link = false })
        -- Recompute our defaults on theme changes, preserving explicit user overrides.
        if next(current) == nil or vim.deep_equal(current, generated[full_name]) then
            vim.api.nvim_set_hl(0, full_name, h)
            generated[full_name] = vim.api.nvim_get_hl(0, { name = full_name, link = false })
        end
    end
end
local function doc(width)
    local d = { lines = {}, spans = {}, rows = {}, width = math.max(1, width) }
    function d:line(parts, full)
        if type(parts) == "string" then
            parts = { { parts } }
        end
        local line = ""
        local row = #self.lines
        for _, p in ipairs(parts) do
            local text = vm.truncate(
                tostring(p[1] or ""):gsub("\n", " "),
                math.max(0, self.width - vim.fn.strdisplaywidth(line))
            )
            local start = #line
            line = line .. text
            if p[2] and #text > 0 then
                self.spans[#self.spans + 1] = { row = row, start = start, finish = #line, hl = p[2] }
            end
        end
        self.lines[#self.lines + 1] = line
        if full then
            self.spans[#self.spans + 1] = { row = row, start = 0, finish = -1, hl = full, whole = true }
        end
        return #self.lines
    end
    function d:text(text, hl, prefix)
        prefix = prefix or "  "
        hl = hl or "TodoDailyText"
        for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
            -- Let Neovim wrap full message content. Do not truncate user/AI prose.
            local row = #self.lines
            self.lines[#self.lines + 1] = prefix .. line
            if hl then
                self.spans[#self.spans + 1] = { row = row, start = 0, finish = -1, hl = hl }
            end
        end
    end
    function d:keys(items)
        local parts = { { "  " } }
        for _, p in ipairs(items) do
            if p[1] ~= "" then
                if #parts > 1 then
                    parts[#parts + 1] = { "   ", "TodoDailyMuted" }
                end
                parts[#parts + 1] = { "[" .. p[1] .. "]", "TodoDailyKey" }
                parts[#parts + 1] = { " " .. p[2], "TodoDailyMuted" }
            end
        end
        self:line(parts)
    end
    return d
end
local labels = {
    preparing = { "Prepare", "准备任务" },
    reviewing = { "Understand", "理解任务" },
    awaiting = { "Questions", "补充信息" },
    permission = { "Access request", "资料访问申请" },
    assembling = { "Arrange", "编排中" },
    paused = { "Paused", "已暂停" },
    review = { "Review", "审批方案" },
    applied = { "Applied", "已应用" },
}
local function label(status)
    local a = labels[status] or { status, status }
    return L(a[1], a[2])
end
local function duration(m)
    m = tonumber(m) or 0
    return m >= 60 and tostring(math.floor(m / 60)) .. "h" .. (m % 60 > 0 and " " .. tostring(m % 60) .. "m" or "")
        or m .. "m"
end
function M.header(ctl, width)
    local d = doc(width)
    local done, total = ctl:counts()
    local state = ctl.state
    d:line({
        { "  " .. L("TODAY", "今日编排"), "TodoDailyAccent" },
        { "  " .. ctl.date, "TodoDailyMuted" },
        { "   " .. label(ctl.permission and "permission" or state.status), "TodoDailyLabel" },
        { "   " .. (ctl.mode or "plan"):upper() .. " [M]", "TodoDailyKey" },
    })
    d:line({
        { "  " .. duration(state.capacity_minutes), "TodoDailyLabel" },
        { " " .. L("work", "工作"), "TodoDailyMuted" },
        { "   " .. duration(state.reserve_minutes), "TodoDailyLabel" },
        { " " .. L("reserve", "预留"), "TodoDailyMuted" },
        { "   " .. done .. "/" .. total .. " " .. L("reviewed", "已检查"), "TodoDailyAccent" },
        { state.text_only and "   " .. L("TEXT ONLY", "仅文字") or "", "TodoDailyLock" },
    })
    local step = state.status == "preparing" and 1
        or (state.status == "review" or state.status == "applied") and 4
        or state.status == "assembling" and 3
        or 2
    local parts = { { "  " } }
    for i, t in ipairs({
        L("Prepare", "准备"),
        L("Understand & clarify", "理解与澄清"),
        L("Arrange", "编排"),
        L("Approve", "审批"),
    }) do
        if i > 1 then
            parts[#parts + 1] = { "  ›  ", "TodoDailyMuted" }
        end
        parts[#parts + 1] = {
            (i < step and "✓ " or i == step and "● " or "○ ") .. t,
            i == step and "TodoDailyAccent" or "TodoDailyMuted",
        }
    end
    d:line(parts)
    return d
end
local function metadata(task)
    local urgency = require("todo.urgency").calculate(task)
    local due = task.due_date and (task.due_date .. (task.due_time and " " .. task.due_time or ""))
        or L("No deadline", "无截止时间")
    local state = task.status == "in_progress" and L("In progress", "进行中") or L("Todo", "待办")
    return state, due, urgency
end
function M.tasks(ctl, svc, selected, width, readonly)
    local cache = ctl.presentation
    local key =
        { tostring(width), tostring(ctl.task_version), tostring(math.floor(os.time() / 60)), tostring(readonly) }
    for _, e in ipairs(ctl.state.queue) do
        key[#key + 1] = e.uuid .. (e.missing and "m" or "") .. (e.selected and "s" or "") .. (e.locked and "l" or "")
    end
    key = table.concat(key, ":")
    if cache and cache.card_key == key then
        local d = cache.card_doc
        if cache.card_selected ~= selected then
            d.spans = {}
            for row, spans in ipairs(cache.card_base_spans or {}) do
                for _, s in ipairs(spans) do
                    d.spans[#d.spans + 1] = s
                end
            end
            local first = d.rows[selected]
            if first then
                for row = first, first + 2 do
                    d.spans[#d.spans + 1] =
                        { row = row - 1, start = 0, finish = -1, hl = "TodoDailySelected", whole = true }
                end
            end
            cache.card_selected = selected
        end
        return d
    end
    local d = doc(width)
    local _, total = ctl:counts()
    d:line({
        { "  " .. L("TASKS", "参与任务"), "TodoDailyLabel" },
        { "  " .. total .. " " .. L("selected", "项已选"), "TodoDailyMuted" },
    })
    d:keys(readonly and {
        { "Enter / b / Esc", L("Back to questions", "返回问题") },
        { "p", L("Adjust tasks", "调整任务") },
    } or {
        { keys.label("toggle"), L("Include", "参与") },
        { "L", L("Lock", "固定") },
        { keys.label("edit_note"), L("Edit", "编辑") },
    })
    d:line("")
    local function bar_parts(parts, left_group, right_group)
        local out = { { "▌ ", left_group } }
        local used = 2
        for _, part in ipairs(parts) do
            out[#out + 1] = part
            used = used + vim.fn.strdisplaywidth(tostring(part[1] or ""))
        end
        if right_group then
            local padding = math.max(1, width - used - 1)
            out[#out + 1] = { string.rep(" ", padding) .. "▐", right_group }
        end
        return out
    end
    for i, e in ipairs(ctl.state.queue) do
        if not e.missing then
            local task = svc.store:get(e.task_id)
            local included = e.selected == true
            local focused = i == selected
            local textgroup = included and "TodoDailyLabel" or "TodoDailyExcluded"
            local mark = require("todo.ui.task_mark")
            local priority_group = task and mark.priority_group(task)
                or (included and "TodoPriorityBadge3" or "TodoDailyExcluded")
            local due_group = task and mark.due_group(task) or "TodoDailyMuted"
            local top_left_group = included and "TodoBarAI" or "TodoBarActive"
            local rest_left_group = "TodoBarActive"
            local right_group = task and mark.right_group(task) or nil
            d.rows[i] = #d.lines + 1
            d:line(bar_parts({
                { e.locked and "◆ " or "  ", "TodoDailyLock" },
                { included and "[x] " or "[ ] ", included and "TodoDailyIncluded" or "TodoDailyExcluded" },
                {
                    "[P" .. (task and task.priority or e.priority or 3) .. "] ",
                    priority_group,
                },
                { task and task.title or e.title, textgroup },
            }, top_left_group, right_group), focused and "TodoDailySelected" or nil)
            if task then
                local state, due, urgency = metadata(task)
                d:line(bar_parts({
                    { "  " .. state .. "  ·  ", textgroup },
                    {
                        due,
                        not included and "TodoDailyExcluded"
                            or due_group,
                    },
                }, rest_left_group, right_group), focused and "TodoDailySelected" or nil)
                local tags = {}
                for _, t in ipairs(task.tags or {}) do
                    tags[#tags + 1] = "#" .. t
                end
                local summary = (task.description or ""):gsub("[#*_`>]", ""):gsub("%s+", " ")
                if summary == "" then
                    summary = L("No description · clarify the goal first", "暂无描述 · 先澄清任务目标")
                end
                d:line(bar_parts({
                    {
                        "  " .. table.concat(tags, " ") .. (#tags > 0 and "  ·  " or ""),
                        included and "TodoDailyAccent" or "TodoDailyExcluded",
                    },
                    { summary, included and "TodoDailyMuted" or "TodoDailyExcluded" },
                }, rest_left_group, right_group), focused and "TodoDailySelected" or nil)
            end
            d:line("")
        end
    end
    if cache then
        cache.card_key, cache.card_doc, cache.card_selected = key, d, selected
        cache.card_base_spans = {}
        for row = 1, #d.lines do
            cache.card_base_spans[row] = {}
        end
        for _, s in ipairs(d.spans) do
            if not (s.whole and s.hl == "TodoDailySelected") then
                table.insert(cache.card_base_spans[s.row + 1], s)
            end
        end
        return M.tasks(ctl, svc, selected, width, readonly)
    end
    return d
end
function M.questions(round, tab, option, width)
    local d = doc(width)
    if not round then
        d:line("")
        return d
    end
    local parts = { { "  " } }
    local used = 2
    for i = 1, #round.questions + 1 do
        local q = round.questions[i]
        local text = " " .. (q and q.header or L("Submit", "提交")) .. " "
        local a = q and round.answers[q.id]
        local answered = q and require("todo.ai.questions").answered(round, q)
        if answered then
            text = " ✓" .. text
        end
        used = used + vim.fn.strdisplaywidth(text) + 2
        parts[#parts + 1] = { text, i == tab and "TodoDailyTab" or "TodoDailyMuted" }
        parts[#parts + 1] = { "  " }
    end
    if used > width then
        parts = {
            { "  " .. tab .. "/" .. (#round.questions + 1) .. "  ", "TodoDailyMuted" },
            {
                " " .. (round.questions[tab] and round.questions[tab].header or L("Submit", "提交")) .. " ",
                "TodoDailyTab",
            },
            { "  [Tab] →", "TodoDailyKey" },
        }
    end
    d:line(parts)
    d:line("")
    local q = round.questions[tab]
    if not q then
        d:line({ { "  " .. L("Check your answers", "确认本轮回答"), "TodoDailyLabel" } })
        for _, question in ipairs(round.questions) do
            local a = round.answers[question.id] or {}
            local choices = {}
            for _, o in ipairs(question.options) do
                if (a.selected or {})[o.id] then
                    choices[#choices + 1] = o.label
                end
            end
            d:text(
                question.header
                    .. " · "
                    .. (#choices > 0 and table.concat(choices, "、") or L("Not selected", "未选择")),
                "TodoDailyLabel"
            )
            if a.custom and a.custom ~= "" then
                d:text("↳ " .. a.custom, "TodoDailyMuted")
            end
            for _, o in ipairs(question.options) do
                local n = (a.notes or {})[o.id]
                if n and n ~= "" then
                    d:text(o.label .. " · " .. n, "TodoDailyMuted", "    ")
                end
            end
        end
        d:keys({
            { keys.label("select"), L("Send round", "提交本轮") },
            { "Esc", L("Back to questions", "返回问题") },
        })
        return d
    end
    d:text(q.question, "TodoDailyLabel")
    d:line({
        {
            "  " .. (q.multiple and L("Multiple choices", "可多选") or L("Single choice", "单选"))
                .. " · "
                .. #q.options
                .. " "
                .. L("options", "个选项")
                .. " · "
                .. L("Choose, then add detail below", "选择后可在下方继续补充"),
            "TodoDailyMuted",
        },
    })
    if #q.options > 0 and (#q.options < 3 or #q.options > 5) then
        d:text(
            L(
                "Options should be 3-5. Press T to ask AI for alternatives.",
                "选项应为 3–5 个，可按 T 让 AI 重新整理。"
            ),
            "TodoDailyMuted",
            "  "
        )
    end
    d:line("")
    local a = round.answers[q.id] or { selected = {}, notes = {} }
    for i, o in ipairs(q.options) do
        local chosen = a.selected and a.selected[o.id]
        local focus = i == option
        d.rows[i] = #d.lines + 1
        d:line({
            { focus and "▎ " or "  ", "TodoDailyAccent" },
            { tostring(i) .. ". ", "TodoDailyMuted" },
            { chosen and "[x] " or "[ ] ", chosen and "TodoDailyIncluded" or "TodoDailyMuted" },
            { o.label, chosen and "TodoDailyIncluded" or "TodoDailyText" },
        }, focus and "TodoDailySelected" or nil)
        if o.description then
            d:text(o.description, "TodoDailyMuted", "         ")
        end
        if a.notes and a.notes[o.id] and a.notes[o.id] ~= "" then
            d:text("↳ " .. a.notes[o.id], "TodoDailyIncluded", "         ")
        end
    end
    d:line("")
    d.rows[#q.options + 1] = #d.lines + 1
    d:line({
        { option == #q.options + 1 and "▎ " or "  ", "TodoDailyAccent" },
        { "+ " .. L("Add detail / own answer", "补充说明 / 自定义回答"), "TodoDailyAccent" },
    })
    if a.custom and a.custom ~= "" then
        d:text(a.custom, "TodoDailyIncluded", "    ")
    end
    d:keys({
        { keys.label("select"), L("Select", "选择") },
        { keys.label("edit_note"), L("Option note", "选项说明") },
        {
            keys.label("input"),
            L("Add detail", "补充"),
        },
        { keys.label("preview"), L("Preview", "提交预览") },
    })
    return d
end
function M.permission(p, width)
    local d = doc(width)
    d:line({
        { "  ▎ " .. L("PERMISSION REQUEST", "权限申请"), "TodoDailyLock" },
        {
            "   " .. p.tool,
            "TodoDailyLabel",
        },
    })
    d:text(p.reason, "TodoDailyLabel")
    d:line("")
    d:text(p.target or "", "TodoDailyAccent")
    d:text(p.review_reason or p.explanation, "TodoDailyMuted")
    d:text(
        L(
            "Returned excerpts go to your configured AI provider. Session grants cover this exact request only.",
            "返回的资料片段将发送给配置的 AI 服务商。本会话授权仅适用于这个相同请求。"
        ),
        "TodoDailyMuted"
    )
    if p.tool == "run_command" then
        d:text(
            L(
                "Read-only text snapshot · network disabled · temporary scratch only",
                "只读文本副本 · 无网络 · 仅临时目录可写"
            ),
            "TodoDailyLock"
        )
    end
    d:line("")
    d:keys({
        { "y", L("Allow once", "允许一次") },
        { "Y", L("Exact request this session", "本会话允许相同请求") },
        { "n", L("Reject", "拒绝") },
    })
    return d
end
function M.modes(selected, width)
    local d = doc(width)
    d:line({ { "  " .. L("PERMISSION MODE", "权限模式"), "TodoDailyAccent" } })
    local modes = {
        { "PLAN", L("Read and investigate; review every Todo edit", "只读调查；Todo 修改交给你审批") },
        {
            "BUILD",
            L(
                "Investigate and edit Todo within your configured policy",
                "调查与 Todo 编辑；默认自动应用描述和备注，可撤销"
            ),
        },
        {
            "AUTO",
            L(
                "Independent AI review within configured scope; local rules still apply",
                "授权范围内独立 AI 审核；本地禁止规则始终有效"
            ),
        },
    }
    for i, m in ipairs(modes) do
        d.rows[i] = d:line(
            { { i == selected and "  ▎ " or "    ", "TodoDailyAccent" }, { m[1], "TodoDailyLabel" } },
            i == selected and "TodoDailySelected" or nil
        )
        d:text(m[2], "TodoDailyMuted")
        d:line("")
    end
    d:keys({
        { "j/k", L("Select", "选择") },
        { keys.label("select"), L("Apply", "切换") },
        { "Esc", L("Back", "返回") },
    })
    return d
end
function M.timeline(ctl, svc, selected, session, width, show_details, queue_open)
    local d = doc(width)
    local entry = (ctl.state.status == "preparing" or queue_open) and ctl.state.queue[selected] or ctl:current()
    if queue_open then
        session = nil
    end
    if entry then
        local task = svc.store:get(entry.task_id)
        d:line({
            { "  " .. L("TASK CONTEXT", "任务背景"), "TodoDailyMuted" },
            { "   " .. entry.ref, "TodoDailyMuted" },
        })
        d:text(task and task.title or entry.title, "TodoDailyLabel")
        if task then
            local state, due = metadata(task)
            d:line({
                { "  " .. state .. "  ·  ", "TodoDailyMuted" },
                { due, require("todo.ui.task_mark").due_group(task) },
            })
            if ctl.state.status == "preparing" or queue_open or show_details then
                d:line("")
                d:text(
                    task.description and task.description ~= "" and task.description
                        or L(
                            "The goal and deliverable still need clarification.",
                            "还缺少具体目标与交付物，AI 应先确认这些信息。"
                        ),
                    task.description ~= "" and nil or "TodoDailyMuted"
                )
                for _, n in ipairs(ctl.ws:list("note")) do
                    if n.value.task_uuid == entry.uuid then
                        d:line("")
                        d:text(n.value.text)
                    end
                end
            end
        end
        d:line("")
    end
    if ctl.state.status == "preparing" then
        d:line({ { "  " .. L("BEFORE STARTING", "开始前"), "TodoDailyAccent" } })
        d:text(
            L(
                "Review what belongs today, then confirm fixed tasks.",
                "检查参与范围与固定事项，确认后开始逐项理解。"
            ),
            "TodoDailyMuted"
        )
        d:keys({
            { "a", L("New", "新增") },
            { keys.label("edit_note"), L("Edit", "编辑") },
            { "C", L("Work time", "工作时间") },
            { "B", L("Reserve", "预留") },
        })
        d:keys(
            ctl.state.locks_confirmed and { { keys.label("preview"), L("Start review", "开始理解任务") } }
                or { { keys.label("select"), L("Confirm fixed items", "确认固定事项") } }
        )
    elseif session then
        if session.understanding then
            local u = session.understanding
            d:line({ { "  " .. L("UNDERSTANDING", "当前理解"), "TodoDailyAccent" } })
            d:text(u.goal or L("Goal not yet established", "目标尚未明确"), "TodoDailyLabel")
            if u.deliverable and u.deliverable ~= "" then
                d:text(L("Deliverable: ", "交付物：") .. u.deliverable, "TodoDailyMuted")
            end
            if u.unknowns and #u.unknowns > 0 then
                d:text(L("Still unclear: ", "待明确：") .. table.concat(u.unknowns, "；"), "TodoDailyLock")
            end
            d:line("")
        end
        for _, msg in ipairs(session.messages or {}) do
            local instruction = msg.origin == "workflow"
                or msg.content
                    == "Read this task completely and decide what information is still missing. Ask only useful unknowns; otherwise finish this item."
            if not instruction then
                d:line({
                    {
                        "  " .. (msg.role == "user" and L("YOU", "你") or "AI"),
                        msg.role == "user" and "TodoDailyUser" or "TodoDailyAccent",
                    },
                })
                d:text(msg.display or msg.content or "")
                d:line("")
            end
        end
    end
    if ctl.state.status == "review" then
        d:line({ { "  ✓ " .. L("Plan ready", "规划已就绪"), "TodoDailyIncluded" } })
        d:text(ctl.state.summary or "")
        d:keys({ { "v", L("Review changes", "审批修改") } })
    end
    if ctl.partial and ctl.partial ~= "" then
        d:line({
            {
                "  AI  " .. (ctl.busy and L("responding", "正在回复") or L(
                    "Unverified response",
                    "未通过校验的回复"
                )),
                ctl.busy and "TodoDailyAccent" or "TodoDailyLock",
            },
        })
        d:text(ctl.partial)
    elseif ctl.busy then
        d.spinner_row = #d.lines
        d:line({
            { "  ⠋ ", "TodoDailyAccent" },
            { ctl.stage or L("Reading context…", "正在了解任务…"), "TodoDailyMuted" },
        })
    elseif ctl.cache.partial then
        d:line({ { "  " .. L("Interrupted response", "中断的回复"), "TodoDailyLock" } })
        d:text(ctl.cache.partial.text or "")
    end
    if ctl.state.last_error then
        d:line("")
        local err = ctl.state.last_error
        if err:lower():find("understanding evidence", 1, true) then
            err = L(
                "AI evidence could not be verified. Your answers are saved. Retry with r, or edit and resubmit.",
                "AI 的依据引用未通过核对，答案已保留。按 r 重试，或修改答案后重新提交。"
            )
        else
            err = err:gsub("[^%s]+%.lua:%d+: ", "")
        end
        d:text("! " .. err, "TodoDailyError")
        d:keys({ { "r", L("Retry", "重试") }, { ":Todo diagnostics", L("Error details", "错误详情") } })
    end
    return d
end
function M.paint(pop, d, ns)
    if not pop or not vim.api.nvim_buf_is_valid(pop.bufnr) then
        return
    end
    local _, changed = require("todo.ui.surface").write(pop.bufnr, d.lines)
    local old = pop.todo_paint
    local reset = not changed or not old or old.theme ~= theme_version or old.ns ~= ns
    if reset then
        vim.api.nvim_buf_clear_namespace(pop.bufnr, ns, 0, -1)
    end
    local rows = {}
    local backgrounds = {}
    for _, span in ipairs(d.spans) do
        rows[span.row] = rows[span.row] or {}
        rows[span.row][#rows[span.row] + 1] = span
        if span.whole then
            backgrounds[span.row] = span.hl
        end
    end
    local dirty = {}
    for row = 0, #d.lines - 1 do
        if reset or changed[row] or not vim.deep_equal(rows[row], old.rows[row]) then
            dirty[row] = true
            if not reset then
                vim.api.nvim_buf_clear_namespace(pop.bufnr, ns, row, row + 1)
            end
        end
    end
    for _, s in ipairs(d.spans) do
        if dirty[s.row] then
            local group = s.hl
            if not s.whole and backgrounds[s.row] then
                group = backgrounds[s.row] .. "_" .. s.hl
                if not combined[group] then
                    local selected = vim.api.nvim_get_hl(0, { name = backgrounds[s.row], link = false })
                    local original = vim.api.nvim_get_hl(0, { name = s.hl, link = false })
                    if original.fg and selected.bg then
                        original.fg = contrast.readable(original.fg, selected.bg, 4.5)
                    end
                    vim.api.nvim_set_hl(0, group, vim.tbl_extend("force", original, { bg = selected.bg }))
                    combined[group] = true
                end
            end
            vim.api.nvim_buf_set_extmark(pop.bufnr, ns, s.row, s.start, {
                end_row = s.whole and s.row + 1 or s.row,
                end_col = s.whole and 0 or s.finish == -1 and #d.lines[s.row + 1] or s.finish,
                hl_group = group,
                hl_eol = s.whole or false,
                priority = s.whole and 90 or 120,
            })
        end
    end
    pop.todo_paint = { rows = rows, theme = theme_version, ns = ns }
end
M.doc = doc
return M
