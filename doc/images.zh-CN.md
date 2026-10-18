# 内嵌图片配置

TodoAnxiety 通过 [3rd/image.nvim](https://github.com/3rd/image.nvim) 在任务描述、备注、
AI 对话及相应 Markdown 编辑器中显示附件。图片复制到持久目录，使用
`todo-asset://<sha256>.<extension>` 引用，删除原文件不会丢失附件。

## 推荐 lazy.nvim 配置

以下参考开发环境现有配置：Kitty 协议、ImageMagick CLI、不构建 LuaRocks，
输入时保留图片，图片高度最多占窗口 50%。已有 image.nvim 配置时，将这些选项合并到
原配置，不要再次调用 `setup()`。其他文档类型的集成可以保留原设置。

```lua
return {
  {
    "3rd/image.nvim",
    cond = function() return not vim.g.neovide end,
    build = false, -- magick_cli needs ImageMagick, not a LuaRocks build.
    opts = {
      backend = "kitty", -- Choose "sixel" or "ueberzug" for a different terminal.
      processor = "magick_cli",
      integrations = {
        markdown = {
          enabled = true,
          clear_in_insert_mode = false,
          only_render_image_at_cursor = false,
          floating_windows = false,
          download_remote_images = false,
          filetypes = { "markdown", "vimwiki" },
        },
      },
      max_width_window_percentage = 100,
      max_height_window_percentage = 50,
      scale_factor = 1.0,
      window_overlap_clear_enabled = false,
    },
  },
  {
    "InubashiriLix/TodoAnxiety.nvim",
    dependencies = {
      "kkharji/sqlite.lua",
      "MunifTanjim/nui.nvim",
      "3rd/image.nvim",
    },
    config = function()
      require("todo").setup({ attachments = { inline = true } })
    end,
  }
}
```

- 本机需要 ImageMagick，可执行 `magick -version` 检查。后端必须匹配实际终端；
  Kitty、Sixel、Überzug++ 的具体环境要求见 image.nvim 官方文档，插件不自动安装系统依赖。
- `floating_windows = false` 只控制 image.nvim 自带的 Markdown 扫描器。
  TodoAnxiety 自己解析附件路径，并通过公共图片 API 显式绑定窗口和 buffer，
  因而任务详情和备注编辑浮窗仍可显示图片，不需要将此选项改为 `true`。
- `download_remote_images = false` 是相对开发环境配置的一项建议调整：
  附件由本插件从持久目录读取，或通过带认证的同步服务下载；不需要 Markdown 扫描器
  独立下载任意 HTTP 图片。关闭此项不影响本插件的附件同步。
- 沿用现有设置，在 Neovide 下跳过 image.nvim；仍可保存附件、阅读 Markdown 和外部打开。
- 不在 TodoAnxiety 的 `setup()` 中重配 image.nvim，以免覆盖其他插件共用的后端设置。

## 插入、显示与排查

在支持的 Markdown 编辑器里按 `Ctrl-v` 粘贴剪贴板图片，或执行
`:Todo image /absolute/path/to/image.png` 导入文件。Linux 剪贴板需要 `wl-paste`
或 `xclip`，也可以配置 `attachments.clipboard_command`；其他平台可以使用文件导入
或自定义剪贴板命令。光标移到附件引用所在行后，按 `gx` 外部打开图片。

支持 PNG、JPEG、GIF、WebP，单张最多 10 MiB。图片预留垂直空间，离开窗口时清理显示；
备注和任务描述使用相同的存储、显示机制。

遇到问题执行 `:checkhealth todo`、image.nvim 的 `:ImageReport` 和
`:Todo diagnostics`。依次检查终端协议、ImageMagick 和本机附件文件。
缺失的已同步图片可通过 `gx` 下载；渲染失败保留 Markdown 引用和外部打开入口。
设置 `attachments.inline = false` 可以关闭内嵌显示，同时继续保存和同步附件。

自动测试覆盖公共图片 API 接入、持久文件、buffer 更新、退出清理和失败降级。
实际图像输出需要在对应终端与后端中检查。
