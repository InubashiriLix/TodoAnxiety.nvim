# Inline images

TodoAnxiety uses [3rd/image.nvim](https://github.com/3rd/image.nvim) to display managed
attachments in task descriptions, notes, AI conversations and their Markdown
editors. Images are copied into persistent storage and referenced as
`todo-asset://<sha256>.<extension>`. Deleting the original file does not remove the
attachment.

## Recommended lazy.nvim configuration

This follows the configuration used during development: Kitty graphics,
ImageMagick CLI, no LuaRocks build, images retained while typing, and at most half
of the window height. Keep your existing image.nvim specification if you already
have one; merge these options there instead of calling `setup()` a second time.

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

- Install ImageMagick locally and check `magick -version`. Configure a backend
  supported by the terminal; image.nvim documents the prerequisites for Kitty,
  Sixel and Überzug++. The plugin does not install these tools.
- `floating_windows = false` controls image.nvim's built-in Markdown scanner.
  TodoAnxiety resolves its own attachment references and uses the public image
  API with explicit buffer/window bindings, so its floating editors and details
  can still show attachments. Setting this option to `true` is unnecessary.
- `download_remote_images = false` differs from the development configuration:
  managed attachments are resolved locally or downloaded through authenticated
  TodoAnxiety sync. This prevents the Markdown scanner from independently
  downloading arbitrary HTTP images. It does not disable attachment sync.
- The example skips image.nvim in Neovide, matching the development setup.
  Markdown, durable attachments and external viewing remain available.
- Avoid overriding image.nvim's setup inside TodoAnxiety's configuration. Backend
  choices also affect the rest of your Neovim session.

## Insert, display and troubleshoot

Use `Ctrl-v` in supported Markdown editors to paste a clipboard image, or
`:Todo image /absolute/path/to/image.png` to import a file. On Linux, clipboard
images require `wl-paste` or `xclip`, or `attachments.clipboard_command` configured
for your environment. Put the cursor on an attachment reference and press `gx`
to open it externally. Other platforms can use file import or a custom clipboard
command.

PNG, JPEG, GIF and WebP are accepted, up to 10 MiB per attachment. Images reserve
vertical space and are cleared when leaving their window. The same storage and
rendering path is used by notes and task descriptions.

Run `:checkhealth todo`, `:ImageReport` (provided by image.nvim), and
`:Todo diagnostics` when an image does not render. Check the terminal/backend,
ImageMagick and whether the local attachment exists. Missing synchronized files
can be fetched by `gx`. Rendering failures preserve the Markdown reference and
external viewer fallback. Set `attachments.inline = false` to disable inline
images while retaining attachments.

Automated tests cover the public image API integration, persistent files,
buffer updates, cleanup and fallback. Actual graphics output requires a matching
terminal/backend and should be checked in that terminal.
