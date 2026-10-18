# 用 Lua 配置插件

运行配置可以全部通过 `require('todo').setup({...})` 管理，不需要先进入设置 UI。
下面展示 AI、计划、同步和图片的常用配置；数据库、界面、快捷键、提醒音也属于 setup
配置。全部默认字段可在 [config.lua](../lua/todo/config.lua) 中查看。

```lua
require('todo').setup({
  db_path = vim.fn.stdpath('data') .. '/todo.nvim/todo.db',
  core = { bin = '' }, -- 必填的 Rust core；空值自动查找 core/target 或 $TODO_CORE_BIN
  language = 'zh-CN',
  ui = {
    default_mode = 'float',
    default_view = 'today',
    markdown = true,
    float = { width = 0.80, height = 0.75, border = 'rounded' },
    sidebar = { width = 42, side = 'right' },
  },
  planning = {
    capacity_minutes = 480,
    reserve_minutes = 60, -- false 时使用 reserve_ratio
    reserve_ratio = 0.125,
    timezone_offset_minutes = 480, -- UTC+8；false 使用已保存的规划时区／本机时区
  },
  ai = {
    enabled = true,
    provider = 'deepseek',
    base_url = 'https://api.deepseek.com',
    model = 'deepseek-flash',
    api_key_file = vim.fn.stdpath('data') .. '/todo.nvim/deepseek-key',
    preferences_source = 'config', -- Lua 中的 language/persona 优先于已同步的偏好
    language = 'zh-CN',
    persona = '帮助我形成可执行的清单，仅询问必要信息，收集足够信息后形成执行清单。',
    planning = {
      max_rounds_per_item = 10,
      questions_per_round = 4,
      max_requests_per_item = 16,
      max_requests_total = false, -- 默认参与任务数 × 16 + 2
      stream = true,
      image_paste_key = '<localleader>p',
    },
    max_rounds = 10, -- 单任务 clarify 会话限制
    max_questions_per_round = 8,
    context_tokens = 16000, -- 按 UTF-8 字节估算的输入预算
    memory = { enabled = true, context_tokens = 2000, recent_turns = 4, search_limit = 8 },
    max_requests = 20,
    max_output_tokens = 4096,
    max_input_bytes = 524288,
    timeout_ms = 90000,
    text_only = false, -- 新会话默认值
    extended = false,  -- 新会话是否允许提出截止日期／状态等扩展修改，仍需审批
    session_budget_usd = 0.05,
    daily_budget_usd = 1.00,
  },
  sync = {
    enabled = true,
    provider = 'server',
    url = 'https://YOUR_HOST/todo-sync',
    token_file = vim.fn.stdpath('data') .. '/todo.nvim/sync-token',
    auto = false, -- 默认手动 :Todo sync，不在空闲时请求网络
    interval_seconds = 0, -- 显式设置 >0 且 auto=true 才启用轮询
    debounce_ms = 2000,
    tls_verify = true,
    allow_http = false,
    ca_file = '', -- 仅自建 CA 时设置证书文件路径
  },
  attachments = {
    inline = true,
    directory = '', -- 默认 db_path .. '.assets'
    max_bytes = 10485760,
    clipboard_command = false,
    viewer = false,
  },
  reminders = { enabled = true },
})
```

示例中两个密钥文件都必须事先存在，内容是原始密钥，不是 JSON；建议权限 0600。
AI Key 和同步 Token 是两种独立凭据。开启自动同步后会同步当前数据库，首次切换前
先备份数据库；不要在本来属于不同账号的数据目录之间复用同步地址和密钥。

## 密钥来源与优先级

| 用途 | Lua 值或函数 | 原始文本文件 | 环境变量 |
|---|---|---|---|
| AI | `ai.api_key` | `ai.api_key_file` | `ai.api_key_env`，默认 `DEEPSEEK_API_KEY` |
| 同步 | `sync.token` | `sync.token_file` | `sync.token_env`，默认 `TODO_SYNC_TOKEN` |

优先级为表格从左到右。值默认 `false`，文件路径默认空字符串，表示没有指定该来源。
函数示例：`token = function() return vim.env.MY_TODO_TOKEN end`。
函数应快速返回字符串；不要在读取凭据的函数里执行网络请求或交互提示。

显式配置的函数报错、返回空值，或文件不存在／为空时会直接拒绝请求，不会偷偷使用
另一个环境变量或账号。错误信息不包含回调抛出的原始内容。UI 本地保存的 AI Key
和官方 DeepSeek 的 OpenCode／MCP 回退排在这些来源之后。

可以在私有 Lua 文件中写字符串，但不要将真实密钥提交到公开配置仓库。
密钥只进入认证请求头，不进入任务、会话、同步记录或命令行参数。
日志会脱敏当前配置的 AI Key 和同步 Token，设置页仅显示来源。

## Lua 与 UI 的关系

- `ai.preferences_source = 'config'`：Lua 的语言和人设在每次 setup 后生效，覆盖已同步的
  AI 偏好。UI 修改本次会话内也可生效；下次加载 setup 时仍以 Lua 为准。
- `ai.preferences_source = 'workspace'`（默认）：使用已保存／同步的人设和语言；没有保存
  偏好时才读取 Lua 默认值。适合希望在 UI 中维护跨设备偏好的用户。
- 计划容量、预留比例是**新日期计划的默认值**。已保存的每日安排不会被配置重载覆盖。
- 提问／请求额度、仅文字和扩展修改是**新会话的默认值**。已有会话保留自己的计数和设置，
  重载配置不会清零请求计数，也不会自动应用 AI 建议。
- 全局 Lua 配置不作为工作区记录上传。服务端监听地址、设备密钥签发／撤销、Nginx 限流
  在服务器配置和命令行管理，客户端不能借 setup 改动服务器权限。

这让配置文件掌管运行方式，同时保留实际任务、每日安排和会话的持久状态。

其他 Provider 配置见[规划指南](planning.md#其他-ai-provider)，图片后端见
[图片配置](images.zh-CN.md)，服务端认证与限流见[安全说明](security.md)。

## AI 执行权限

`ai.mode`、`ai.permissions.roots/domains/rules`、自动文档应用和执行限制全部由 Lua 配置。
见[完整字段与模式行为](ai-permissions.md)。只有 build/auto 且 `auto_apply_documents=true` 才会自动应用 Todo 描述/备注；日程与其他任务字段仍审批。

## 操作延迟排查

导航从内存快照读取数据；任务、备注、撤回或同步变更后刷新对应快照。
加载动画只更新标记，流式文本合并刷新，未变化的 Markdown 与图片不会重复重建。
提交 AI 请求和应用方案仍校验实时数据。

需要排查卡顿时，在现有 setup 的 `ui` 中加入 `performance = true`，
操作后执行 `:Todo diagnostics` 查看 `daily.render`、`panel.navigate` 的 P50/P95/最大耗时，
以及任务读取、工作区读取和 buffer 写入次数。计数从当前进程开始累计，
耗时每个阶段最多保存最近 200 次；默认关闭，仅存内存，不包含任务正文或密钥。
这些耗时测量插件回调；终端绘制、按键前缀等待及其他插件耗时需要另外测量。

开发回归包含 `spec/performance.lua`：导航禁止 SQL，覆盖备注、费用、任务编辑和撤回的缓存失效。
设置 `TODO_PERF_TASKS=1000` 可增加任务量，`TODO_PERF_P95_MS=16` 可启用本机延迟门槛；
时间门槛默认关闭，避免不同 CI 机器负载导致误报。

## AI 工作区本地键位

这些是缓冲区局部按键，不覆盖其它 Neovim 窗口。提示和绑定使用同一份配置；冲突会在 setup 时报告。

```lua
ui = {
  daily_keys = {
    focus_left = '<C-h>', focus_down = '<C-j>',
    focus_up = '<C-k>', focus_right = '<C-l>',
    read_half_up = '<C-M-u>', read_half_down = '<C-M-d>',
    read_page_up = '<C-M-b>', read_page_down = '<C-M-f>',
    read_latest = '<C-M-g>', maximize = '+',
    previous_question = { 'h', '<S-Tab>' },
    next_question = { 'l', '<Tab>' },
    select = '<CR>', toggle = '<Space>', preview = 'w',
    edit_note = 'e', input = 'i', return_to_choices = { '<CR>', '<Esc>' },
    -- 某个动作设 false 可关闭其局部绑定。
  },
}
```

主 Todo 面板保持 h/l 或 Enter 进入详情，屏蔽鼠标点击/拖动和 Ctrl-h/j/k/l 意外跳焦点；AI 工作区允许 Ctrl 方向切换。表单和详情使用 Normal `+` 最大化／恢复。任务编辑 `:w` 保存不关闭，`:wq` / `:x` 保存返回面板，`:q!` 放弃上次保存后的编辑。
