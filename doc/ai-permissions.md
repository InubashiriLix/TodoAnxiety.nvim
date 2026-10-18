# AI 权限、调查与模式

每日规划界面顶部始终显示当前模式。输入区外按 `M`，用 `j/k` 选择、`Enter` 切换、
`Esc` 返回。正在生成或等待审批时先 `Ctrl-c` 停止。模式切换只影响本机当前流程；
下一次启动 Neovim 使用 Lua 配置的 `ai.mode`，服务器同步不能替其他设备授权。

| 模式 | 资料与命令 | Todo 文档 |
|---|---|---|
| `plan`（默认） | 已配置范围内的只读文件与搜索可直接执行；命令按规则审批 | 描述、备注进入审批草稿 |
| `build` | 同样遵循目录、域名、命令和沙盒规则 | 默认自动应用当前任务的描述、备注，可 `U` 撤销 |
| `auto` | 已配置范围内交给独立 AI 请求审核，必要时仍询问用户 | 与 build 相同 |

计划安排始终提交最终审批。`auto_apply_documents=false` 可让 build/auto 的文档修改也保留
为草稿。系统不提供外部项目文件写入工具；命令运行在只读副本里，三个模式均不能通过命令
修改原项目。`extended` 的任务状态/截止日期修改仍使用原有独立审批流程。

## Lua 配置

```lua
require('todo').setup({
  ai = {
    mode = 'plan',
    permissions = {
      -- 填入目录表示允许读取其中的普通文本，并将相关片段发送到配置的 AI 服务商。
      -- 默认为空，每次跨范围请求在 UI 中申请。不要默认放开整个 HOME。
      roots = { vim.fn.expand('~/projects/my-project/docs') },
      domains = { 'neovim.io' }, -- 精确 HTTPS 主机名，不支持通配符
      rules = {
        read_file = 'allow',
        search_files = 'allow',
        fetch_url = 'ask',
        run_command = 'ask',
      },
      auto_apply_documents = true,
      max_calls_per_item = 6, -- 同一任务会话累计，拒绝/失败也计数
      max_output_bytes = 12000,
      timeout_ms = 15000,
      snapshot_max_files = 500,
      snapshot_max_bytes = 2097152,
      max_processes = 64,
      memory_mb = 256,
      cpu_seconds = 5,
      scratch_mb = 16,
    },
  },
})
```

规则为 `allow / ask / deny`。`deny` 无法被 AI 或 UI 单次批准覆盖。
`allow` 仍受目录、域名与沙盒限制；未配置的范围需要用户授权。
`run_command='allow'` 仅让无参数 `pwd` / `ls` 这类严格识别的低风险命令直接执行；
其他命令仍需审批。`auto` 的独立审核只能处理已配置的范围，无法授权新目录/域名。

## 审批交互

申请卡展示目的、完整路径或 argv、数据将发送至 AI 的说明，以及独立审核的理由。

- `y`：允许这一次。
- `Y`：当前界面会话内，允许相同工具、相同参数、相同模式的请求；不扩大到整个目录。
- `n`：拒绝，把拒绝结果返回给 AI，使其继续利用已有信息。
- `Ctrl-c`：取消请求及当前生成；`Ctrl-q` 保存输入并关闭。

审批没有超时自动允许。关闭界面清除临时授权。审批记录保存在本机
`stdpath('state')/todo.nvim/permissions.json`，仅保留最近 200 条，权限 0600；
记录决策、目标和理由，不记录原始文件输出。失败与决策也进入 `:Todo diagnostics`。
授权不会存入或从同步数据库加载。

## 调查能力与沙盒

工具支持按字节分页读取本地文本、固定字符串搜索项目文本、抓取指定 HTTPS 页面、
异步执行 argv 命令。没有内置通用搜索引擎；AI 需要已知 URL 或任务提供的线索。
所有结果都是不可信资料，不能作为改变权限的指令。

命令依赖本机 Linux **bubblewrap (`bwrap`)** 和 util-linux 的 **`prlimit`**。系统不可用、用户命名空间被禁用或执行失败时，
显示具体原因，保留已完成工作，**不会退回宿主机直接执行**。界面不会自动安装依赖。
非 Linux 系统仍可使用文件读取、文本搜索和 HTTPS 工具；命令在缺少沙盒时不可用。

命令看到 `/workspace` 下的只读文本副本及系统运行库，环境变量清空，网络命名空间隔离，
只允许限额临时目录写入，并限制进程数、单进程地址空间、CPU、文件大小、输出和总执行时间。
这些资源限制适合轻量检查，不等同于虚拟机或完整 cgroup 总量配额。使用相对路径。副本排除符号链接、二进制文件、
`.git`、常见凭据文件、依赖目录。超限会要求缩小目录，不静默复制半个项目。
因此它适合查看资料和轻量检查，不适合完整依赖构建、git 历史分析或安装软件。
文件名筛选不能识别所有写在普通文档内的秘密，配置 roots 时请选择可发送给 AI 的资料目录。

网页抓取只支持公开 IPv4 对应的 HTTPS 域名，DNS 结果固定到本次连接，拒绝私网、回环、
非 HTTPS、带凭据 URL，不跟随重定向。IPv6-only 或 DNS 返回代理 fake-IP/私网地址时会拒绝连接，并在界面解释原因。
需要登录或重定向的站点可能只能取得错误/跳转页，工具不会带上浏览器凭据。
原始研究结果仅存在于当前请求上下文及短暂本机缓存；AI 的简短理解、用户批准的描述/备注
会按既有 Todo 同步规则保存。相同网页/搜索可使用 60 秒缓存。

## 自动审核与费用

`auto` 的审核使用同一配置 provider/model 的**独立请求**，仅接收待审核操作、理由与限制，
不继承执行者对话，也没有工具。返回 `allow / ask / deny` 后仍由本地规则裁决。
不确定、解析失败、预算不足时转人工审批。审核结果不是操作安全的证明；只读沙盒与
固定范围是实际执行边界。

审核、查询后的继续生成、JSON 修复全部计入任务请求额度与当天费用。每次发请求前检查预算；
接口未返回用量时显示费用未知。`ai.session_budget_usd` / `ai.daily_budget_usd` 不是供应商侧的
硬扣款上限，已发出的请求可能产生额外费用。

## 界面参考

布局参考 OpenCode 的分区、选项标签、左侧强调线和申请卡；操作在 Neovim buffer 中实现。
参考 [OpenCode TUI](https://docs.opencode.ai/docs/tui/)、
[权限文档](https://docs.opencode.ai/docs/permissions/) 与
[输入组件源码](https://github.com/anomalyco/opencode/blob/dev/packages/tui/src/component/prompt/index.tsx)。
