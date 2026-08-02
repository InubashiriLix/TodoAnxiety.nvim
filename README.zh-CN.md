# todo.nvim

[English](README.md) | [简体中文](README.zh-CN.md)

一个专注、本地优先的 Neovim 任务管理插件，提供响应式 dashboard、结构化
任务表单和 SQLite 持久化。插件根据截止时间和优先级透明地计算任务紧急程度，
让紧急视图直接回答“接下来应该做什么？”
https://github.com/user-attachments/assets/2d69b477-6317-413d-8381-6ce3469251cc
## 环境要求

- Neovim 0.10+
- [`kkharji/sqlite.lua`](https://github.com/kkharji/sqlite.lua)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)
- 系统 SQLite 动态库：`libsqlite3.so`、`libsqlite3.dylib` 或 `sqlite3.dll`

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
:Todo tags                    " 打开标签管理面板
:Todo done 42                " 完成 ID 为 42 的任务
:Todo archive 42             " 归档任务，仍可恢复
:Todo restore 42             " 恢复已归档任务
:Todo delete 42              " 永久删除已归档任务
```

所有命令都通过统一的 `:Todo` 入口调用：

```text
open [float|sidebar] [active|emergency|archived]
toggle [float|sidebar]
add [title]
tags
edit [id]
start|done|cancel|reopen [id]
archive|restore|delete [id]
close
```

在 todo.nvim 面板内省略 ID 时，命令会操作光标所在的任务。

默认全局快捷键：

| 快捷键 | 操作 |
| --- | --- |
| `<leader>Tt` | 切换默认任务面板 |
| `<leader>Ta` | 新增任务 |
| `<leader>Tf` | 打开浮动面板 |
| `<leader>Ts` | 打开侧栏 |
| `<leader>Te` | 打开紧急任务视图 |
| `<leader>Tg` | 管理标签 |

dashboard 底部会显示当前上下文的常用操作，按 `?` 可以查看完整帮助。插件不会
覆盖已有的全局快捷键。

在“已归档”视图选中任务后按 `D`，确认后即可永久删除；确认菜单默认停在“取消”，
避免误按 Enter。也可以使用 `:Todo delete [id]`。永久删除仅允许作用于已归档任务，
活动任务会被数据库服务层拒绝。此操作不可恢复。

## Dashboard 与任务表单

浮动 dashboard 在可用宽度达到 100 列时使用左侧任务列表、右侧固定详情的布局。
窄浮窗和侧栏使用清晰的两行任务卡，按 Enter 为选中任务打开详情浮窗。活动视图
按状态分组，紧急视图继续按紧急度排序。

新增/编辑表单使用独立控件，不再解析整块纯文本：

- 带行内校验的标题输入框
- 始终可见的 P0–P3 优先级选择器（`0`–`3`、方向键或 Enter 菜单）和四段式
  状态选择器（`1`–`4`、方向键或 Enter 菜单）
- 纯键盘月历和不受预设限制的时间编辑器：可直接输入 `HHMM`，也可以按 1 或 5
  小时/分钟调整，或者保留为仅日期；不再提供固定时间或隐藏的鼠标日期按钮
- 独立标签面板，支持选择、新建、重命名、删除、筛选和查看使用量；在空标签
  输入框按 Enter 打开，再用 `j`/`k` 和 Enter/空格切换选中；也可以使用
  `:Todo tags` 或 `<leader>Tg` 全局管理。删除
  标签前会确认；删除只会解除所有任务上的该标签，不会删除任务
- 可正常换行的独立多行描述编辑器

使用 Tab 和 Shift-Tab 在字段间移动，`<C-s>` 保存；Normal 模式按 `q`，或在
任意模式按 `<C-q>` 关闭。Esc 只退出 Insert 模式，永远不会关闭表单。有未保存内容时，
表单会询问保存、放弃或继续编辑。todo.nvim 不再注册任何鼠标映射，所有操作只有
一套明确可见的键盘路径。从 dashboard 打开
表单时，原面板会暂时收起，并在表单关闭后恢复，不会出现两个界面互相重叠。

## 配置

```lua
require("todo").setup({
  db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
  language = "zh-CN", -- "en" 或 "zh-CN"
  ui = {
    default_mode = "float", -- "float" 或 "sidebar"
    default_view = "active", -- "active"、"emergency" 或 "archived"
    float = { width = 0.80, height = 0.75, border = "rounded" },
    sidebar = { width = 42, side = "right" },
  },
  keymaps = {
    enabled = true,
    prefix = "<leader>T",
  },
})
```

插件使用单个全局数据库，不会为不同代码项目分别创建数据库。备份数据库时，
可以先关闭 Neovim 再复制配置中的 `.db` 文件；数据库正在使用时则应使用
SQLite 提供的备份工具。

## 紧急度排序

紧急视图只考虑未归档且状态为 `todo` 或 `in_progress` 的任务。所有设置了
截止时间的任务都会进入此视图；没有截止时间的 P0 和 P1 任务也会进入。

截止时间基础分：

| 截止情况 | 分数 |
| --- | ---: |
| 已逾期 | 120 |
| 24 小时内 | 80 |
| 3 天内 | 60 |
| 7 天内 | 40 |
| 7 天以后 | 20 |
| 无截止时间 | 0 |

优先级修正：

| 优先级 | 加分 |
| --- | ---: |
| P0 | +30 |
| P1 | +20 |
| P2 | +10 |
| P3 | +0 |

界面只显示紧急等级和排序原因，不显示内部数字分数。逾期任务始终排在未逾期
任务之前；相同分数依次按“有截止时间、截止时间更早、优先级更高、创建时间
更早”排序。

截止时间接受本地时区的 `YYYY-MM-DD` 或 `YYYY-MM-DD HH:mm`。只填写日期时，
按当天 `23:59:59` 计算。

## 任务数据与生命周期

每个任务包含标题、多行纯文本描述、状态、P0–P3 优先级、可选截止时间和任意
数量的标签。状态包括：

- `todo`：待办
- `in_progress`：进行中
- `done`：完成
- `cancelled`：取消

任务可以归档和恢复；任务归档后，也可以经过确认将其永久删除。永久删除不可恢复。
首版有意不包含提醒、重复任务、子任务、云同步和项目级数据库。

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
