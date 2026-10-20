# 今日计划与 AI 编排

配置文件可以管理所有运行配置，密钥也支持文件、字符串、函数和环境变量；
见 [Lua 完整配置示例](configuration.md) 与 [同步安全说明](security.md)。

## 开始使用

本地「今日」页面不需要 AI 或服务器：`:Todo today`。

```lua
require('todo').setup({
  language = 'zh-CN',
  planning = { capacity_minutes = 480, reserve_minutes = 60 },
  ai = {
    enabled = true,
    model = 'deepseek-flash',
    language = 'auto', -- 也可以单独设置 zh-CN / en
    planning = {
      max_rounds_per_item = 10, -- 同一任务、同一日期的硬上限
      questions_per_round = 4, -- 每轮 3-4 个相关问题，最大 4
      max_requests_per_item = 16, -- 检索、修复、收尾均计数
      max_requests_total = false, -- 默认：参与任务数 × 16 + 2
      stream = true,
      image_paste_key = '<localleader>p',
    },
    max_rounds = 10, -- :Todo clarify 的独立会话额度
    max_questions_per_round = 8,
    context_tokens = 16000, -- 按 UTF-8 字节估算的输入预算
    memory = { enabled = true, context_tokens = 2000, recent_turns = 4, search_limit = 8 },
    max_requests = 20,
    session_budget_usd = 1.00, -- 可选，单次工作流预算；false 表示不设置
    daily_budget_usd = 10.00,  -- 可选，当日所有会话共享；已知用量的估算额度
  },
})
```

首次进入 AI 规划时，如果没有可用密钥，会自动弹出 `:Todo ai setup`：
选择 Provider、填写 Base URL / Model、隐藏输入 API Key。设置保存在本机
`stdpath('data')/todo.nvim/ai.json` 和 `credentials.json`，权限 0600，不进入同步。
`require('todo').setup({ ai = { ... } })` 的显式配置优先于本机设置。
也可以执行 `:Todo ai key` 只更新密钥。
显式配置的 `ai.api_key`、`ai.api_key_file` 优先；其余读取顺序为
`DEEPSEEK_API_KEY` 环境变量、本机凭据、OpenCode 的
`~/.local/share/opencode/auth.json`（`deepseek.key`）、已有
`~/.deepseek-mcp/config.json` 中的 `api_key`。界面只显示来源，不显示密钥。

`:Todo ai settings` 设置回复语言和人设；这两项通过服务器同步。
接口地址、密钥、计价和默认预算保留在各设备的 setup 配置中。

## 今日页面

今日事项引用正式任务。计划日期、顺序、估时和下一步动作，与原截止时间独立。

| 按键 | 操作 |
|---|---|
| `j/k`、`gg/G`、`Ctrl-u/d` | 浏览任务 |
| `Enter` / `l` | 查看或进入详情 |
| `a` | 新建正式任务并加入当前日期 |
| `t` | 加入／移出计划 |
| `T` | 范围标记：`Tj` / `T3j` / `Tgg` / `TG` 批量加入／移出今日 |
| `s` / `x` | 按任务状态开始／恢复待办、完成／重开 |
| `A` | 归档／恢复归档 |
| `T` / `u` / `R` | 旧操作的兼容按键；常用提示统一显示情景按键 |
| `J/K` | 调整执行顺序 |
| `L` | 锁定／解锁安排，AI 不改动锁定事项 |
| `m` | 编辑估时、下一步动作等计划字段 |
| `C` | 设置当日可用分钟数 |
| `b` | 选择计划日期 |
| `N` | 新建或编辑任务备注 |
| `P` | 开始或恢复 AI 编排 |
| `Q` | 让 AI 澄清当前任务 |
| `Enter`（选项） | 确认当前选项并进入下一题 |
| `Space`（选项） | 只勾选/取消，不跳题 |
| `Tab`（选项） | 进入补充说明 |
| `Tab` / `Enter`（补充说明） | 保存并返回选项 |
| `h/l` / `Shift-Tab` | 上一题／下一题 |
| `t` | 给 AI 发送自由指导（如“再追问我 3 个问题”） |
| `T` | 选择有用的指导提示词 |
| `D` | 打开当前任务原文、备注与今日计划 |
| `d` | 在对话区展开/收起任务详情 |
| `End` / `Ctrl-Alt-g` | 跳到最新回复 |
| `Home` / `Ctrl-g` | 跳到顶部 |
| `U` / `Ctrl-r` | 撤回／重做已保存的操作 |
| `?` / `F1` | 当前页面的完整帮助 |
| `X` | 放弃本次 AI 规划会话；删除问答、检查结果、未应用草稿和未发送文字，保留任务、日程、已应用修改和费用记录 |

新日期默认工作时间 480 分钟、预留 60 分钟，新加入事项默认不锁定。已有日期保持原设置，
可在准备页调整。`planning.reserve_minutes=false` 时使用 `reserve_ratio`；只显式配置旧版
`reserve_ratio` 也保持兼容。往日未完成事项显示在「往日待复核」中，不自动写入今天的计划。`:Todo today 2026-10-20` 也可打开指定日期。

## 界面预览

使用合成任务从真实 Neovim UI grid 捕获，非设计稿。

[准备页：任务卡片与上下文预览](screenshots/daily-preparation.png) ·
[问答页：选项、附加说明与 Vim 输入](screenshots/daily-questions.png)

## 每日逐项编排

`:Todo plan [YYYY-MM-DD]` 或今日页 `P` 打开每日规划工作区。

1. **准备**：全部未完成普通任务默认参与，包括今日事项和积压任务。`Space` 排除/纳入，
   `a/e` 新增/编辑正式任务，`C/B` 调整工作/预留分钟，`L` 固定/解锁。
   先按 `Enter` 确认旧锁定，再按 `w` 开始。固定事项占满容量时会在请求前阻止启动；
   `S` 可明确保留固定事项继续分析。
2. **逐项检查**：AI 每次读取当前任务的完整描述、备注、图片，并参考全局任务概览。
   先展示有原文依据的目标、交付物和未知项；目标不清时只能澄清目标/范围/交付物，不能先问进度。
   只询问必要信息；每项每天最多 10 轮，每轮最多 3 个相关问题。关闭、重开、重新规划或
   换设备均不增加同日额度。新一天重新计数，并参考最近的历史检查结果。
3. **汇总**：全部检查后生成 now/next/optional 清单、剩余估时、下一步、完成标准，
   并解释依赖、超载与未安排事项。描述/备注的改进也进入同一份审批草稿。
4. **审批**：`v` 打开差异，`Space` 选择、`Enter` 对比、`e` 编辑、`f` 反馈、`a` 应用。
   应用是一笔事务，可在任务页 `U` 整批撤回。默认 plan 模式不自动修改正式任务；
   build/auto 可按权限配置自动应用描述和备注，日程仍需审批。详见[AI 权限与模式](ai-permissions.md)。

审批页顶部显示已选/总数、分类计数和进度条；应用后提示修改数量和“任务页 U 撤回”。

界面顶部始终显示 4 步工作流、当前任务、已检查/已跳过/剩余数量和下一步按键。
按 `X` 会二次确认并放弃当前日期的本次规划会话，重新进入干净的准备页；正式任务、今日排期、已应用修改和费用记录不会删除。AI 请求进行中时需先按 `Ctrl-c` 停止。
任务完成、跳过、恢复、自动应用、草稿生成/应用都会写入时间线“最近操作”；
草稿生成、应用和批量自动修改会弹出一次通知。`:Todo status` 可随时查看当前阶段、
任务进度、问题进度、草稿状态、预算和最近一次操作。

### Vim 输入区

底部始终是独立的 Markdown buffer，默认 Normal 模式。`i/a` 进入 Insert，`Esc` 回到
Normal，Visual/寄存器/移动/原生 `u`、`Ctrl-r` 均保留；`Enter` 换行，`Tab` 缩进。
Normal 模式 `Enter` / `Esc` 保存草稿并回到原选项；`w` 在选项区打开提交预览，再按 `Enter` 发送。`Ctrl-c` 停止请求，`Ctrl-q` 保留草稿并关闭。
每个任务、问题和选项说明有各自 buffer 与撤销历史；发送后保留原文。

- 选项区：`j/k`、`gg/G` 移动，`Space` / `Enter` 单选/多选（不自动跳题），`w` 打开提交预览，
  `Tab/Shift-Tab` 或 `h/l` 切题，`e` 为当前选项写附加说明（无需勾选），`i` 补充说明或自定义回答；补充文字不会清空选项，切换选项也不会丢失补充。
- 输入区外：选项区 `g`／上下文区 `c` 根据已有信息完成当前项，`u` 这题不需要答案并自动下一题，`s` 稍后处理（准备页可再按 `s` 恢复），`b` 展开队列，`d` 展开当前详情，
  `p` 返回准备页调整任务/容量，`F1` 查看完整帮助。
- AI 区域 Normal 模式 `Ctrl-h/j/k/l` 按方向切换区域，不会跳出插件；极小窗口按上下文→选项→输入的顺序切换。Insert 模式保留 Vim 编辑，先 `Esc` 再切换。
- `Ctrl-Alt-u/d` 翻阅可见 AI 上下文半页，`Ctrl-Alt-b/f` 翻整页，不改变输入焦点和模式。`Ctrl-Alt-g` 回到最新回复并继续跟随输出；上翻时新回复不会抢走滚动位置。
- Normal `+` 最大化／还原当前区域；Insert 的 `+` 仍然输入文字。缩放窗口保留草稿、光标和滚动位置。
- 输入区 `:w` 显式保存草稿，`:wq` / `:x` 保存并返回，`:q` 拒绝丢失未保存修改，`:q!` 丢弃上次显式保存后的文字。自动草稿恢复和显式保存基线独立。
- 失败后 `r` 使用已保存的请求重试；`x` 打开统一的修复选项（重试、调整预算、按假设结束、跳过任务、打开诊断）。答案及补充说明会保留，也可修改后重新预览提交。引用错误最多自动修复一次，仍失败则按假设继续，不会无限请求；每次请求都计入额度和费用记录。
- 预算中断时按 `B` 修改本次规划或今日预算；修改后会自动继续。无预算错误时 `B` 只修改运行时额度，不发请求；准备阶段的 `B` 仍用于预留分钟。底部状态行显示已用金额、单次上限、剩余额度与今日用量。
- 只填写选项说明也属于有效补充，不会标成“未回答”，也不会自动勾选该选项。任务队列预览不会修改背后的问答。
- 图片：Insert `Ctrl-v` 或 Normal `<localleader>p` 粘贴。Normal `Ctrl-v` 保留块选择。
  `:Todo image {path}` 也可插图。预览使用可选的 image.nvim；不支持视觉的 provider 会说明
  原因，可在输入区外 `V` 切换仅文字模式，`ai.text_only=true` 设置新流程默认值。

回复使用真实 SSE 流式显示公开说明，不展示内部推理或原始 JSON；完整响应验证后才可审批。
界面刷新节流，缩放时保留 buffer、光标、草稿和正在进行的请求；极小窗口仅展示当前区域。
AI 正文与辅助文字会按背景调整对比度，兼容深浅主题；可用 `TodoDailyText`、`TodoDailyMuted` 等高亮组自行覆盖。未通过校验的流式文字会明确标注；详细错误路径保留在 `:Todo diagnostics`。
若 provider 不支持 SSE，设置 `ai.capabilities.streaming=false`，或 `ai.planning.stream=false`。

关闭会暂停并取消当前请求，保留部分回复和未发送输入，不在后台继续下一项。`q` / `Ctrl-q` 会优先返回打开规划前的任务面板，并恢复原来的范围、分组、筛选和选中任务；没有可返回面板时只关闭规划界面。
日流程和每项轮次保存在数据库；输入草稿、流式缓存保存在
`stdpath('state')/todo.nvim/daily-drafts/`（目录 0700、文件 0600，不同步）。
服务器模式只在开始、等待回答、暂停、汇总完成时同步检查点，并使用日期级租约防止并行编排；
每个 token 不触发同步。自动同步默认仍关闭。

每日工作流共享 `ai.session_budget_usd`，所有会话共享 `ai.daily_budget_usd`；检索/修复均计费。
请求上限与金额预算达到时暂停并保留结果。估价依据接口返回的 token 和配置费率；
缺少用量或计价显示「费用未知」，取消请求也可能产生费用。

证据引用（`understanding.evidence`）优先自动修复一次；模型仍无法给出可核对原文时，
会丢弃无效引用并把不确定项写入 `unknowns` 后继续，不再让已完成的结果因引用文案阻塞。

### 单任务澄清

`:Todo clarify [id]` 或 `Q` 保留独立对话，用于单任务的临时讨论。此入口使用旧版
`ai.max_rounds`、`ai.max_questions_per_round`、`ai.max_requests`；每日工作区使用
`ai.planning` 下的独立限制。旧对话历史会保留。

## AI 记忆与检索

`:Todo ai memory` 管理事实和待确认推断：`a` 添加、`e` 编辑、`c` 确认、`p` 固定、`d` 遗忘、`/` 搜索。也可通过 `require('todo.memory').new(workspace,service)` 的 `list/save/remove/search` 管理。

用户原话有可验证来源时自动保存原话，推断进入待确认列表；旧记录不会被新推断静默覆盖。日期事实只用于对应日期。删除会同步 tombstone 和来源遗忘标记，并使旧摘要失效；撤回 AI 审批同样使决策摘要失效。

本机使用 SQLite FTS5 和中文双字索引；缺少 FTS5 时回退本地匹配，不调用付费 embedding。任务概览始终提供；完整描述超出预算时，模型使用 `search_tasks` / `read_tasks` 读取原文，`search_memory` / `get_memory` 检索记忆。未读完的候选任务不能进入草稿。近期对话、滚动摘要和记忆分别限制输入预算；预算不足时停止并保留现场，不会暗中发送超限内容或丢弃任务。

记忆和会话随服务端协议 v2 同步，搜索索引留在本机。升级会先拉取旧操作确认，再用新操作 ID 重发未确认的 v1 操作，保留原 CAS 版本。旧客户端在版本检查时停止。

审批页左侧逐条列出建议，宽屏右侧实时展示修改前后。窄屏 `Enter` 打开详情。
`Space` 勾选／拒绝，`e` 编辑建议，`f` 将反馈和拒绝原因发回 AI，`t` 继续对话，
`a` 一次应用所有选中项。没有审批不会改动任务；重新生成的建议需要重新审批。
已应用的草稿再次打开是只读的：不显示 `a`，`Space`/`e` 不再修改勾选或建议；按 `a` 只提示已应用并关闭，不会重复提交。

AI 提交的描述和备注按 Markdown 正文处理。审批页会检查整段内容被代码围栏包住、
出现 `# description:` / `# note:` 这类元标签、代码围栏未闭合、标题或列表周围缺少空行、
描述中使用 H1、以及 HTML 和控制字符。这些检查只给出提示，不会自动改写 AI 原文；
`a` 应用时仍保留原文，避免静默改动内容。审批列表和详情页都会标出对应警告。

任务在 AI 上下文中同时提供稳定的 `task_ref`（如 `t1`）和 UUID；短编号在同一会话内不会改指其他任务。非法引用只允许一次带具体条目和合法编号表的修复；仍失败时保留拒绝的回复于会话记录，不写入任务。

默认允许今日安排、备注、描述补充。会话开启扩展修改后，才允许截止时间、
优先级、状态及创建拆分任务。AI 不支持永久删除任务。

一次审批形成一个事务和一个撤回条目。任务或日程已发生其他修改时，整批拒绝，
不会部分写入。`U` 撤回整批，费用记录和对话仍保留。

## 图片

任务描述与 AI 回答编辑器支持 `Ctrl-v` 粘贴剪贴板图片；也可执行
`:Todo image /path/to/image.png` 导入文件。支持 PNG、JPEG、GIF、WebP，单张最多
10 MiB。文件会复制到 `db_path .. '.assets'`，按 SHA-256 去重；原文件删除不影响附件。
通过 `attachments.directory` 可指定其他持久目录。

Markdown 使用 `todo-asset://...` 引用，在不同设备上解析到各自的附件副本。
缩略图／渲染缓存可清理，原件不会被自动清理。`gx` 打开图片，缺失副本会按需下载。
安装可选 [3rd/image.nvim](https://github.com/3rd/image.nvim) 及 ImageMagick 后，
任务描述、备注与 AI 对话等 Markdown 页面会使用其公共图片 API 内嵌显示。
image.nvim 支持 `kitty`、`sixel`、`ueberzug` 后端；按终端环境在 image.nvim 中配置，
本插件不会覆盖已有配置。浮窗绑定图片并预留高度，离开窗口时清理显示。
未安装、后端报错或关闭 `attachments.inline` 时保留 Markdown 和 `gx` 外部打开。
备注编辑器同样支持 `Ctrl-v` 粘贴，使用持久附件引用。
推荐配置参考 [图片配置说明](images.zh-CN.md)。

全局编排默认读取任务文字，避免不必要地发送所有图片；澄清任务时会发送该任务
描述中的图片。回答中新粘贴或导入的图片也会发送给当前配置的 AI Provider（仅文字模式除外）。

## 费用、进度与排查

`:Todo ai usage` 查看本插件记录的累计和今日估算；对话页显示当前会话估算。
缓存命中、未命中和输出分开计价，默认使用 2026-10-15 的官方高峰费率作为保守估算：
每百万 token 分别为 USD 0.006、0.30、1.20，可通过 `ai.pricing` 覆盖。

取消或失败且没有收到 usage 的请求标为「费用未知」，不会记成免费。
预算阻止后续请求，不能拦住已发出请求的最终费用，也不统计其他程序的消费。
`:Todo ai balance` 主动查询账户余额。

网络 IO 为异步请求，不阻塞编辑。同步、图片传输和 AI 请求显示非抢焦点的
转动指示、阶段、耗时和可用的数量进度；错误保留 15 秒。

- `:Todo sync status`：本地队列与同步状态，不发网络请求。
- `:Todo sync conflicts`：选择并处理冲突，保留本地或远端内容。
- `:Todo diagnostics`：查看轮转网络诊断日志，包含操作、阶段、耗时、HTTP 状态和错误。
- `:checkhealth todo`：本地配置、密钥是否存在、curl、剪贴板和图片能力检查。

日志不记录请求正文、任务内容或密钥。日志位于
`stdpath('state')/todo.nvim/network.log`。报告问题前仍建议查看日志内容，避免附上
个人服务器名称或其他无关信息。网络失败保留本地数据，AI 请求不会静默重试计费。

## 服务器同步

Rust 服务部署见 [server/README.md](../server/README.md)。无需 Docker。

```lua
require('todo').setup({
  language = 'zh-CN',
  ai = { enabled = true },
  sync = {
    enabled = true,
    provider = 'server',
    url = 'https://sync.example.com',
    token_env = 'TODO_SYNC_TOKEN',
    auto = false, -- 默认手动 :Todo sync，不在空闲时请求网络
    interval_seconds = 0, -- 显式设置 >0 且 auto=true 才启用轮询
    debounce_ms = 2000,
    -- ca_file = '/path/to/private-ca.pem',
    -- allow_http = true, -- 仅在明确使用 http:// 时开启
    -- tls_verify = false, -- 单独选择，优先配置私有 CA
  },
})
```

每台设备使用独立服务端令牌。默认保存后合并推送，启动、恢复焦点和前台每分钟
拉取；离线变更保留，失败退避，`:Todo sync` 可手动触发。对话、草稿、图片、计划、
备注和用量记录随任务同步；API Key 不同步。

首次启用服务器模式会上传当前本地数据并保留任务 UUID。切换前请备份旧数据库。
原 Git 模式继续支持原有任务同步，但不传输新增的计划、对话和图片，两个模式不能
同时启用。HTTP 会明文传输任务和令牌；自签证书优先使用 `ca_file`。

## 其他 AI Provider

原生支持 DeepSeek、OpenAI Responses API、Anthropic Messages API，以及 Chat
Completions 协议兼容服务。OpenAI/Anthropic 需要显式填写 `model`。

```lua
-- OpenAI 原生 Responses API
require('todo').setup({
  ai = {
    enabled = true,
    provider = 'openai',
    base_url = 'https://api.openai.com/v1',
    model = 'YOUR_MODEL',
    api_key_env = 'OPENAI_API_KEY',
  },
})
```

```lua
-- Anthropic 原生 Messages API
require('todo').setup({
  ai = {
    enabled = true,
    provider = 'anthropic',
    base_url = 'https://api.anthropic.com',
    model = 'YOUR_MODEL',
    api_key_env = 'ANTHROPIC_API_KEY',
  },
})
```

`base_url` 填写包含版本前缀但不含 `/chat/completions`、`/responses` 或
`/v1/messages` 的 HTTPS 地址。

```lua
require('todo').setup({
  ai = {
    enabled = true,
    provider = 'openai_compatible',
    base_url = 'https://YOUR_PROVIDER/v1',
    model = 'YOUR_MODEL',
    api_key_env = 'AI_API_KEY',
    capabilities = { vision = false, json_mode = false, thinking_control = false, balance = false },
    max_tokens_field = 'max_tokens', -- 可改为 max_completion_tokens
    pricing = false, -- 未配置费率时保留 token 统计，费用标为未知
  },
})
```

仅开启接口和模型实际支持的能力。`thinking_control` 专指 DeepSeek 的
`thinking={type='disabled'}` 参数；`balance` 专指本手册的 `/user/balance` 契约，
不是通用余额适配器。不支持的余额查询不会发送请求。
没有结构化输出参数支持时，仍要求模型按 JSON 契约输出，并执行同样的校验和一次修复上限。

其他 Provider 不读取 DeepSeek 环境变量、MCP 或 OpenCode 凭据，不继承 DeepSeek 费率。
本地保存的密钥按 Provider 和接口地址隔离；删除当前密钥不影响其他接口。
官方 DeepSeek 回退来源依次为环境变量、本插件本地文件、OpenCode、DeepSeek MCP。
没有费率时费用预算不可启用；提供每百万 token 的 USD `cache_hit`、`cache_miss`、`output`
费率后才能使用预算。余额保持接口原币种，不与 USD 估算混合。
不支持识图的模型在发送前拒绝图片；对话页 `V` 明确切换仅文字模式，
模式状态在侧栏显示，并告诉模型图片没有发送。请求失败不会自动换 Provider 或模型。

## 资料调查与记忆质量

输入区外 `M` 切换 plan/build/auto；申请卡 `y/Y/n` 允许一次／本会话允许相同请求／拒绝。
读取范围、域名、审批、沙盒和费用限制均可用 Lua 管理，见[AI 权限与模式](ai-permissions.md)。

记忆使用用户原文及来源，不自动确认模型推测。明确的长期偏好/项目事实可长期保存；
任务进展关联任务 UUID 与版本，最长 7 天，到期或任务版本变化后不再作为当前事实注入。
同一事实跨消息去重，同一 fact_key 的矛盾事实进入待确认，不覆盖旧事实。
每次只注入固定偏好、当前任务和文本相关的记忆，受数量与字节预算双重限制；
本地中英文检索不调用付费 embedding。精确事实去重不等同于完整语义去重，
可用记忆管理界面确认、置顶、编辑或删除。忘记的原文不会因换一条来源消息重新自动生成。

## 循环任务

`:Todo routines` 管理循环任务模板。模板按规则在当天生成一条普通任务实例，实例完成后不会结束整个系列：

- 每天 / 工作日 / 每周几（多选）/ 每 N 天 / 每 N 周 / 每月某日 / 每月最后一天
- 执行时间、开始日期、结束日期
- 自动加入 Today
- 同一天不会重复生成
- 生成的任务保留 `due_time` 和提醒，完成只影响当天的实例

当前模板编辑复用通知表单的重复规则控件；后续会换成带下五次预览的独立 Routine 编辑器。
