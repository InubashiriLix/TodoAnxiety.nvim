# todo.nvim

[English](README.md) | [简体中文](README.zh-CN.md)

![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-blue?logo=neovim)
![License](https://img.shields.io/badge/license-WTFPL-blue)

一个专注、本地优先的 Neovim 任务管理插件，提供响应式 dashboard、结构化
任务表单和 SQLite 持久化。插件根据截止时间和优先级透明地计算任务紧急程度，
让紧急视图直接回答“接下来应该做什么？”

<https://github.com/user-attachments/assets/2d69b477-6317-413d-8381-6ce3469251cc>

## 目录

- [环境要求](#环境要求)
- [使用方法](#使用方法)
- [Dashboard 与任务表单](#dashboard-与任务表单)
- [配置](#配置)
- [多设备同步](#多设备同步)
- [紧急度排序](#紧急度排序)
- [任务数据与生命周期](#任务数据与生命周期)
- [开发与测试](#开发与测试)

## 环境要求

- Neovim 0.10+
- [`kkharji/sqlite.lua`](https://github.com/kkharji/sqlite.lua)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)
- [`folke/which-key.nvim`](https://github.com/folke/which-key.nvim) v3（可选，
  用于独立的快捷键图标列）
- 系统 SQLite 动态库：`libsqlite3.so`、`libsqlite3.dylib` 或 `sqlite3.dll`
- Neovim 内置的 `markdown`/`markdown_inline` treesitter parser，用于详情面板
  和描述编辑器的 markdown 渲染（官方 Neovim 自带；缺失时会静默退回纯文本）

> **已知兼容性问题：** 详情面板和描述编辑器会把 `filetype` 设为 `markdown`，
> 所以任何靠 `FileType markdown` 自动挂载的 markdown 渲染插件也会尝试接管它们。
> 大多数情况没问题，但如果某个插件用定时器延迟初始化、且定时器触发时不重新
> 校验 buffer 是否还有效，就可能在你很快关闭详情窗口时报错（例如
> `mdmath.nvim`，它大约延迟 100ms 才启用）。todo.nvim 让详情面板和详情浮窗
> 共用一个长期存在的 buffer 来缩小这个竞态窗口，但无法保证对所有第三方插件
> 都彻底消除。如果遇到类似报错，建议向那个插件反馈，或者把
> `ui.markdown` 设为 `false`，让详情面板不再使用 `filetype = markdown`。

lazy.nvim 安装示例：

```lua
{
  "InubashiriLix/TodoAnxiety.nvim",
  dependencies = {
    "kkharji/sqlite.lua",
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("todo").setup({
      language = "zh-CN",
    })
  end,
}
```

安装完成后运行 `:checkhealth todo` 检查运行环境。

## 使用方法

```vim
:Todo                         " 打开活动任务浮窗
:Todo open sidebar emergency " 在侧栏打开紧急任务视图
:Todo add 编写发布说明        " 预填标题并打开新任务表单
:Todo notice 五分钟后洗澡    " 打开新 Notice 表单
:Todo open notices           " 查看所有未归档 Notice
:Todo tags                    " 打开标签管理面板
:Todo done 42                " 完成 ID 为 42 的任务
:Todo archive 42             " 归档任务，仍可恢复
:Todo restore 42             " 恢复已归档任务
:Todo delete 42              " 永久删除已归档任务
```

所有命令都通过统一的 `:Todo` 入口调用：

```text
open [float|sidebar] [active|emergency|by_urgency|by_time|by_tag|notices|archived]
toggle [float|sidebar]
add [title]
notice [title]
tags
sync [status]
edit [id]
start|done|cancel|reopen [id]
archive|restore|delete [id]
close
```

在 todo.nvim 面板内省略 ID 时，命令会操作光标所在的任务。

默认全局快捷键：

| 快捷键       | 操作             |
| ------------ | ---------------- |
| `<leader>Tt` | 切换默认任务面板 |
| `<leader>Ta` | 新增任务         |
| `<leader>Tf` | 打开浮动面板     |
| `<leader>Ts` | 打开侧栏         |
| `<leader>Te` | 打开紧急任务视图 |
| `<leader>Tg` | 管理标签         |
| `<leader>Tn` | 新增 Notice      |

dashboard 底部会显示当前上下文的常用操作，按 `?` 可以查看完整帮助。插件不会
覆盖已有的全局快捷键。

`/` 搜索框失去焦点时会立即收起。只要焦点进入普通编辑窗口，浮动 Dashboard
也会关闭；Dashboard 自己的详情、菜单、搜索和标签管理窗口仍被视作 todo.nvim
的一部分。侧栏在焦点返回编辑器后会继续保留。插件不会覆盖或禁用 `Ctrl-j/k`
等用户自己的窗口导航快捷键。

在“已归档”视图选中任务后按 `D`，确认后即可永久删除；确认菜单默认停在“取消”，
避免误按 Enter。也可以使用 `:Todo delete [id]`。永久删除仅允许作用于已归档任务，
活动任务会被数据库服务层拒绝。此操作不可恢复。

## Dashboard 与任务表单

浮动 dashboard 在可用宽度达到 100 列时使用左侧任务列表、右侧固定详情的布局。
窄浮窗和侧栏使用清晰的两行任务卡，按 Enter 为选中任务打开详情浮窗。

详情面板和详情浮窗都按 markdown 渲染：标题、状态、优先级、截止时间、紧急度
和标签组成字段列表，后面紧跟描述原文。窗口的 `filetype` 会设为 `markdown`，
如果装了 `MeanderingProgrammer/render-markdown.nvim` 之类的渲染插件会自动接管；
没装的话，Neovim 内置的 treesitter 高亮依然生效。将 `ui.markdown` 设为 `false`
可以关闭渲染，直接看未加工的 markdown 源文本。新建/编辑表单里的描述输入框
也是同一个 filetype，边写列表、复选框或代码块边高亮，保存后详情面板里会
呈现同样的渲染效果。

### 视图

共有七个标签页：`[` 和 `]` 循环切换，`v` 打开选择菜单，当前标签在标题栏高亮。
窗口宽度不足时，标签会自动折行到标题栏的下一行。

| 标签页 | 分组方式 |
| --- | --- |
| 活动任务 | 全部任务按状态分组 |
| 紧急任务 | 仅紧急候选任务，按紧急度排序的平铺列表 |
| 按紧急程度 | 全部未完成任务按紧急档位分组：已逾期、紧急、较急、需关注、仅优先级 |
| 按剩余时间 | 全部未完成任务按剩余时间排序，分为已逾期、今日到期、本周到期、更晚到期、无截止时间；卡片显示 `剩余 3d 4h` 这类相对标签 |
| 按标签 | 树形视图，每个标签一个根节点，另有“未分类”；带多个标签的任务会出现在每个标签下 |
| 提醒事项 | 按下次触发时间排序 |
| 已归档 | 已归档任务，最新在前 |

所有分组标题都可折叠：`<Tab>` 或 `za` 折叠光标所在分组，`zR` 全部展开，
`zM` 全部折叠。折叠状态按视图分别记录，面板保持打开期间一直有效。`j` 和 `k`
会同时经过分组标题和任务，因此标签视图可以像树一样浏览。搜索以及状态、
优先级、标签筛选在任意视图上都继续生效。

Escape 每次只回退一层：在搜索框中（Normal 或 Insert 模式均可）清除搜索词、
关闭输入框并把光标交还列表；在菜单、帮助浮窗或详情浮窗中关闭该窗口；在列表中
先清除当前筛选，没有筛选时才关闭面板。

Notice 用于“5 分钟后洗澡”这类需要持续催促的日常事项。使用 `:Todo notice [标题]`
创建，在触发时间中直接输入 `30s`、`5m`、`2h` 或准确日期；Normal 模式按 `c`
也可使用月历和任意时间编辑器。周期支持一次、每天、工作日、指定星期，以及每隔
N 分钟、小时或天。重复提醒间隔会预填上一次使用的值；在该字段按 `t` 可打开
`[天] [小时] [分钟] [秒]` 四段式时长选择器，同时仍可直接输入 `5m` 等简写。

到点后插件播放声音并强制聚焦提醒窗口：`d` 完成本轮，`s` 输入相对时间稍后提醒，
`a` 归档并永久停止，`q` 只关闭本次弹窗。未处理的事项会按照自己的间隔持续提醒；
周期 Notice 完成本轮后计算下一个未来触发时间。Neovim 关闭期间无法播放声音，
但下次启动或系统恢复时会立即补提醒。

新增/编辑表单使用独立控件，不再解析整块纯文本：

- 带行内校验的标题输入框
- 始终可见的 P0–P3 优先级选择器（`0`–`3`、方向键或 Enter 菜单）和四段式
  状态选择器（`1`–`4`、方向键或 Enter 菜单）
- 纯键盘月历和不受预设限制的时间编辑器：可直接输入 `HHMM`，也可以按 1 或 5
  小时/分钟调整，或者保留为仅日期；时间选择器会同时显示日期、小时和分钟，越过
  24:00 或 00:00 时日期会自动前进或后退；不再提供固定时间或隐藏的鼠标日期按钮
- 独立标签面板，支持选择、新建、重命名、删除、筛选和查看使用量；在空标签
  输入框按 Enter 打开，再用 `j`/`k` 和 Enter/空格切换选中；也可以使用
  `:Todo tags` 或 `<leader>Tg` 全局管理。删除
  标签前会确认；删除只会解除所有任务上的该标签，不会删除任务
- 可正常换行的独立多行描述编辑器

使用 Tab 和 Shift-Tab 在字段间移动，`<C-s>` 保存；Normal 模式按 `q` 或 Esc，
或在任意模式按 `<C-q>` 关闭。Insert 模式下 Esc 仍然只退出 Insert，不会关闭正在
输入的字段。有未保存内容时，
表单会询问保存、放弃或继续编辑。todo.nvim 不再注册任何鼠标映射，所有操作只有
一套明确可见的键盘路径。从 dashboard 打开
表单时，原面板会暂时收起，并在表单关闭后恢复，不会出现两个界面互相重叠。

## 配置

```lua
require("todo").setup({
  db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
  language = "zh-CN", -- "en" 或 "zh-CN"
  -- 可选的手动同步：先新建专用私有空 Git 仓库，并配置各设备的 Git 认证。
  -- 填好配置后执行 :Todo sync；:Todo sync status 只查看本地状态。
  sync = {
    enabled = false, -- 填好 remote 后改为 true。
    remote = "", -- 例如 "git@github.com:YOUR_NAME/private-todos.git"
    branch = "main", -- 所有设备使用相同的远端和分支。
  },
  ui = {
    default_mode = "float", -- "float" 或 "sidebar"
    -- "active"、"emergency"、"by_urgency"、"by_time"、"by_tag"、"notices"
    -- 或 "archived"
    default_view = "active",
    -- 详情面板和描述编辑器是否按 markdown 渲染
    markdown = true,
    float = { width = 0.80, height = 0.75, border = "rounded" },
    sidebar = { width = 42, side = "right" },
  },
  -- 每个值是一个完整的按键串，设为 false 则禁用
  keymaps = {
    toggle = "<leader>Tt",
    add = "<leader>Ta",
    open_float = "<leader>Tf",
    open_sidebar = "<leader>Ts",
    open_emergency = "<leader>Te",
    manage_tags = "<leader>Tg",
    add_notice = "<leader>Tn",
  },
  -- 可选的 which-key v3 原生图标元数据；
  -- 也可直接填写字符串；使用 false 或 "" 禁用某一个图标
  icons = {
    toggle = { icon = "\u{f204}", color = "yellow" },
    add = { icon = "\u{f067}", color = "green" },
    open_float = { icon = "\u{eb7f}", color = "blue" },
    open_sidebar = { icon = "\u{f03c7}", color = "cyan" },
    open_emergency = { icon = "\u{f071}", color = "orange" },
    manage_tags = { icon = "\u{f02c}", color = "purple" },
    add_notice = { icon = "\u{f0f3}", color = "orange" },
  },
  reminders = {
    enabled = true,
    sound = {
      path = "/path/to/reminder.ogg",
      command = { "mpv", "--no-video", "--really-quiet" },
    },
  },
})
```

检测到 which-key v3 时，todo.nvim 会通过 `which-key.add()` 把以上配置作为原生
`icon` 元数据注册。which-key 会将它们渲染在独立、对齐且带颜色的图标列中。
没有安装 which-key 时，快捷键仍然正常工作，`desc` 也会保持为不含图标的纯文本。

声音命令按 argv 列表执行，不经过 shell。将 `command` 设为 `false` 时会依次检测
`mpv`、`ffplay`、`paplay` 和 `afplay`；路径为空、文件不可读或播放器不可用时，
回退到终端响铃。普通任务设置 DDL 后，重复提醒间隔是必填项；没有 DDL 时不会
创建提醒。

插件使用单个全局数据库，不会为不同代码项目分别创建数据库。备份数据库时，
可以先关闭 Neovim 再复制配置中的 `.db` 文件；数据库正在使用时则应使用
SQLite 提供的备份工具。

## 多设备同步

可选的 Git 同步支持 macOS 和 Linux，每台设备保留独立的本地 SQLite 数据库。
需要 Git 2.28+，各设备使用相同的新版插件。**只有执行 `:Todo sync` 才联网**，
启动、重新聚焦、编辑和退出都不会自动同步；离线时照常使用。

1. 新建一个专用的**私有空 Git 仓库**，不要初始化 README、许可证或 `.gitignore`，
   也不要使用插件源码仓库。
2. 在每台设备配置 Git 认证。SSH 用户先在终端完成主机密钥验证，并将密钥加载到
   SSH agent；HTTPS 用户使用 Git 凭据管理器。同步过程不会弹出密码输入提示。
3. 在目前已有待办的设备上添加以下配置，执行 `:Todo sync` 首次上传：

   ```lua
   require("todo").setup({
     sync = {
       enabled = true, -- 默认关闭
       remote = "git@github.com:YOUR_NAME/private-todos.git",
       branch = "main",
     },
   })
   ```

4. 在 Mac 等其他设备安装插件与依赖，使用相同的同步配置和空的本地数据库，执行
   `:Todo sync` 下载。无需复制 `.db`，也无需手动克隆同步仓库。
5. 切换设备前在原设备执行 `:Todo sync`，切换后在新设备执行一次。也可以先在
   两端离线编辑，稍后再同步。

`:Todo sync status` 显示上次成功时间、待上传数量、最近错误和本地同步目录，
**不会检查远端**。`:checkhealth todo` 检查 Git 与本地目录，也不联网。
Lua 接口为 `require("todo").sync()` 和 `require("todo").sync_status()`。

同步内容包括任务、Notice、标签、归档、删除、提醒规则、完成当前周期以及稍后提醒。
声音路径、界面配置、上次输入偏好和已响铃进度留在本机；断网期间两台设备可能都会响铃。
截止日期文本沿用原有本地时间语义，提醒触发时刻使用 Unix 时间戳共享；日/周循环的下一次
时刻按执行“完成本轮”操作的设备时区计算。

冲突时采用较新的**整条任务记录**，包括标签和提醒配置，不按字段合并。
毫秒时间、逻辑序号和设备身份保证结果确定；设备时钟不准确仍会影响离线并发修改的排序。
任务通过 UUID 跨设备对应，`:Todo done 42` 中的数字 ID 属于本机，两端可能不同。
如果任务在表单打开后已改变，保存会被拒绝；请先复制未保存的文本，再重新打开任务。

Git 中保存不可变的 JSON 事务记录；SQLite 始终留在本机。插件管理的 Git 目录为
`<db_path>.sync`，不要手动编辑或提交其中的文件，也不要把实时数据库放进云同步目录。
删除标签会屏蔽旧关联，重新创建同名标签不会恢复旧关联。
删除任务会将它从当前列表移除，但**旧内容仍保留在 SQLite 同步日志和 Git 历史中**。
第一版不提供历史清理，也不额外提供超出 Git 传输/托管服务的加密功能。

断网或认证失败时，本地修改和待上传记录都会保留。修复后再次执行 `:Todo sync` 即可。
每条 Git 命令最多等待 30 秒；并发推送被拒绝时最多尝试三轮，不执行强制推送。
同步期间新增的修改可能留到下次手动同步。遇到非法数据或未知格式时，该批导入整体回滚；
保留数据库并检查错误信息，不要用一端数据库直接覆盖另一端。

数据库升级到 schema v3，即使未启用同步也会记录 UUID 和持久变更日志。
旧数据库升级前会生成一致性备份 `<db_path>.pre-sync-<uuid>.db`；如需退回旧版插件，
请保留这份备份。关闭同步后，本地功能仍可继续使用。
需要重建缓存时，先关闭 Neovim，仅将 `<db_path>.sync` 移走，重新启动后执行同步；
数据库中的日志会重建缓存。同一数据库绑定同一个远端与分支；切换到另一同步仓库时
使用独立 `db_path`。其他设备应从空数据库接入，分别升级旧数据库的复制品会生成不同 UUID。

## 紧急度排序

紧急视图只考虑未归档且状态为 `todo` 或 `in_progress` 的任务。所有设置了
截止时间的任务都会进入此视图；没有截止时间的 P0 和 P1 任务也会进入。

截止时间基础分：

| 截止情况   | 分数 |
| ---------- | ---: |
| 已逾期     |  120 |
| 24 小时内  |   80 |
| 3 天内     |   60 |
| 7 天内     |   40 |
| 7 天以后   |   20 |
| 无截止时间 |    0 |

优先级修正：

| 优先级 | 加分 |
| ------ | ---: |
| P0     |  +30 |
| P1     |  +20 |
| P2     |  +10 |
| P3     |   +0 |

界面只显示紧急等级和排序原因，不显示内部数字分数。逾期任务始终排在未逾期
任务之前；相同分数依次按“有截止时间、截止时间更早、优先级更高、创建时间
更早”排序。

截止时间接受本地时区的 `YYYY-MM-DD` 或 `YYYY-MM-DD HH:mm`。只填写日期时，
按当天 `23:59:59` 计算。

## 任务数据与生命周期

每个任务包含标题、多行 markdown 描述、状态、P0–P3 优先级、可选截止时间和任意
数量的标签。状态包括：

- `todo`：待办
- `in_progress`：进行中
- `done`：完成
- `cancelled`：取消

任务可以归档和恢复；任务归档后，也可以经过确认将其永久删除。永久删除不可恢复。
Notice 和带 DDL 的普通任务都可持久化提醒状态。旧数据库会自动升级到 schema v3，
旧任务不会突然启用声音提醒；编辑并保存提醒间隔后才会启用。

默认数据库路径：

```text
stdpath("data")/todo.nvim/todo.db
```

## 开发与测试

运行无额外测试框架依赖的 headless 测试：

```sh
bash scripts/test.sh
```

当 `kkharji/sqlite.lua` 位于 `runtimepath` 中时，会执行真实 SQLite 集成测试；
NUI 集成测试同样要求 `nui.nvim`。测试脚本会自动检测 lazy.nvim 的常见安装路径，
也可以通过 `TODO_SQLITE_PATH` 和 `TODO_NUI_PATH` 指定依赖目录。

有 SQLite 依赖时，还会使用本地裸 Git 仓库执行双设备同步测试，无需 GitHub 凭据或联网。
CI 配置覆盖 Linux、macOS，以及 Neovim 0.10.4 和当前稳定版。
