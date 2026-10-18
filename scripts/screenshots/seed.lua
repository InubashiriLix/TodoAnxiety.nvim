-- Deterministic demo data for the README screenshots.
-- Run through scripts/screenshots/render.sh; never point this at a real DB.
local M = {}

local function L(zh, en)
    return require("todo.config").get().language == "zh-CN" and zh or en
end

local function at(days, time)
    return os.date("%Y-%m-%d " .. (time or "18:00"), os.time() + days * 86400)
end

local function create(svc, input)
    local task, errors = svc:create(input)
    assert(task, vim.inspect(errors))
    return task
end

function M.seed(todo)
    local svc = todo._service()
    local ws = require("todo.workspace").new(svc.store)
    local tasks = {}

    tasks.release = create(svc, {
        title = L("发布 v1.0.0", "Ship v1.0.0"),
        description = L(
            "把 README、截图和 release notes 收尾。\n\n- [x] 功能清单\n- [ ] 截图\n- [ ] GitHub Release",
            "Finish README, screenshots, and release notes.\n\n- [x] Feature inventory\n- [ ] Screenshots\n- [ ] GitHub Release"
        ),
        priority = "P0",
        deadline = at(0, "18:00"),
        reminder_interval = "1h",
        tags = { L("发布", "release"), L("文档", "docs") },
    })
    svc:set_status(tasks.release.id, "in_progress")

    tasks.ai = create(svc, {
        title = L("整理 AI 规划反馈", "Review AI planning feedback"),
        description = L(
            "把最近一周的反馈整理成可执行的改进项。\n\n**交付物**\n1. 反馈摘要\n2. 优先级列表\n3. 下一步行动",
            "Turn the last week of feedback into actionable improvements.\n\n**Deliverable**\n1. Feedback summary\n2. Priority list\n3. Next actions"
        ),
        priority = "P1",
        deadline = at(1, "10:00"),
        reminder_interval = "1h",
        tags = { "ai", L("产品", "product") },
    })

    tasks.sync = create(svc, {
        title = L("修复同步冲突提示", "Fix sync conflict feedback"),
        description = L(
            "并发推送被拒绝时，界面需要保留可读的错误原因，而不是只显示“同步失败”。",
            "When a concurrent push is rejected, keep the readable reason instead of only showing “sync failed”."
        ),
        priority = "P1",
        deadline = at(-1, "18:00"),
        reminder_interval = "1h",
        tags = { L("同步", "sync"), L("修复", "bug") },
    })

    tasks.readme = create(svc, {
        title = L("写 README 功能巡览", "Write the README feature tour"),
        description = L(
            "把 AI 工作台、循环任务、Notice、同步和 Rust core 放到第一屏。",
            "Put the AI workspace, routines, notices, sync, and Rust core on the first screen."
        ),
        priority = "P2",
        deadline = at(3, "12:00"),
        reminder_interval = "1h",
        tags = { L("文档", "docs"), L("发布", "release") },
    })

    tasks.retro = create(svc, {
        title = L("准备冲刺回顾", "Prepare sprint retro"),
        description = L(
            "收集本周完成项、阻塞项和一条流程改进。",
            "Collect this week's wins, blockers, and one process improvement."
        ),
        priority = "P3",
        tags = { L("团队", "team") },
    })

    tasks.rust = create(svc, {
        title = L("读 Rust 异步编程", "Read the Rust async book"),
        description = L("整理 Tokio 运行时和取消安全的笔记。", "Take notes on the Tokio runtime and cancellation safety."),
        priority = "P2",
        deadline = at(7, "20:00"),
        reminder_interval = "1h",
        tags = { "rust", L("学习", "learning") },
    })

    tasks.done = create(svc, {
        title = L("合并 notice 与任务视图", "Merge notices into task views"),
        description = L("已完成并通过全量测试。", "Completed and verified with the full test suite."),
        priority = "P1",
        deadline = at(-2, "18:00"),
        reminder_interval = "1h",
        tags = { L("发布", "release") },
    })
    svc:set_status(tasks.done.id, "done")

    tasks.cancelled = create(svc, {
        title = L("重构旧的任务列表", "Refactor the old task list"),
        description = L("已经由新的三行卡片布局替代。", "Superseded by the new three-row card layout."),
        priority = "P3",
        tags = { L("整理", "cleanup") },
    })
    svc:set_status(tasks.cancelled.id, "cancelled")

    tasks.archived = create(svc, {
        title = L("迁移旧数据库", "Migrate the old database"),
        description = L("保留备份并验证 schema 升级。", "Keep the backup and verify the schema upgrade."),
        priority = "P2",
        deadline = at(-9, "18:00"),
        reminder_interval = "1h",
        tags = { L("维护", "maintenance") },
    })
    svc:archive(tasks.archived.id)

    tasks.notice = create(svc, {
        kind = "notice",
        title = L("喝水", "Drink water"),
        trigger = "2h",
        reminder_interval = "1h",
        recurrence = { kind = "daily", every = 1 },
        tags = { L("生活", "life") },
    })
    tasks.notice2 = create(svc, {
        kind = "notice",
        title = L("站起来活动一下", "Stand up and stretch"),
        trigger = "4h",
        reminder_interval = "2h",
        recurrence = { kind = "weekdays" },
        tags = { L("健康", "health") },
    })

    -- Keep a realistic Today queue, independent of deadlines.
    local planner = require("todo.planning").new(ws, svc)
    local date = planner:date()
    for _, item in ipairs({
        { tasks.ai, "now", 45, L("先列出三条最重要的反馈", "List the three most important feedback items") },
        { tasks.readme, "next", 60, L("写完功能总览和命令表", "Finish the feature overview and command table") },
        { tasks.retro, "later", 30, L("收集团队阻塞项", "Collect team blockers") },
    }) do
        planner:add(item[1].sync_uuid, date)
        planner:change(date, item[1].sync_uuid, {
            group = item[2],
            minutes = item[3],
            next_action = item[4],
            locked = item[2] == "now",
        })
    end

    -- Recurring routines are templates; start tomorrow so they do not add
    -- duplicate tasks to today's queue.
    local routines = require("todo.routines")
    local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)
    routines.create(ws, svc, {
        title = L("每日回顾", "Daily review"),
        description = L("检查今天完成的事，并标出明天的第一步。", "Review today's work and mark tomorrow's first step."),
        start_date = tomorrow,
        time = "20:30",
        priority = 2,
        tags = { L("习惯", "habit") },
        recurrence = { kind = "daily", every = 1 },
    })
    routines.create(ws, svc, {
        title = L("每周计划", "Weekly planning"),
        description = L("清理收件箱，安排下周的重点。", "Clear the inbox and choose next week's focus."),
        start_date = tomorrow,
        time = "09:00",
        priority = 1,
        tags = { L("计划", "planning") },
        recurrence = { kind = "weekly", weekdays = { 2 }, every = 1 },
    })
    routines.create(ws, svc, {
        title = L("清理归档", "Archive cleanup"),
        description = L("归档已完成任务，检查同步状态。", "Archive finished tasks and check sync status."),
        start_date = tomorrow,
        time = "18:00",
        priority = 3,
        tags = { L("维护", "maintenance") },
        recurrence = { kind = "interval", every = 2, unit = "days" },
    })

    local first_routine = routines.list(ws)[1]

    -- A seeded clarification conversation makes the AI chat screenshot stable
    -- and avoids any network request.
    local ai = require("todo.ai").new(ws, svc)
    local session = ai:start({ task_id = tasks.ai.id, scope = "clarify", extended = true })
    session.messages = {
        {
            role = "user",
            content = L(
                "帮我澄清“整理 AI 规划反馈”这个任务，我还没想清楚交付物。",
                "Help me clarify “Review AI planning feedback”; I have not decided on the deliverable."
            ),
        },
        {
            role = "assistant",
            content = L(
                "可以先拆成三个交付物：\n\n1. 一页反馈摘要\n2. 按影响/成本排序的改进项\n3. 本周能完成的三步行动\n\n这份整理主要给谁看？",
                "Start with three deliverables:\n\n1. A one-page feedback summary\n2. Improvements ranked by impact and cost\n3. Three actions finishable this week\n\nWho is the main audience?"
            ),
        },
        {
            role = "user",
            content = L(
                "给产品团队看。请顺便列出本周能完成的三步。",
                "For the product team. Also list three steps we can finish this week."
            ),
        },
        {
            role = "assistant",
            content = L(
                "### 建议的三步\n\n1. 今天：把反馈按主题聚类，选出影响最大的三条。\n2. 明天：为每条写一个可验证的验收标准。\n3. 周五：和产品团队过一遍优先级，确认下周排期。\n\n确认后，我可以把它们生成任务草稿；审批前不会修改任何任务。",
                "### Suggested next steps\n\n1. Today: cluster feedback by theme and pick the top three by impact.\n2. Tomorrow: write a verifiable acceptance criterion for each.\n3. Friday: review priorities with product and confirm next week's schedule.\n\nI can turn these into task drafts after you confirm; nothing changes before approval."
            ),
        },
    }
    session.questions = 1
    session.requests = 2
    session.status = "ready"
    ws:put("conversation", session.id, session)

    return { tasks = tasks, session = session, date = date, routine = first_routine }
end

return M
