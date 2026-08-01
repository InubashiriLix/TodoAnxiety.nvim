local M = {}

function M.check()
  vim.health.start("todo.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10+ detected")
  else
    vim.health.error("todo.nvim requires Neovim 0.10 or newer")
  end

  local ok, sqlite = pcall(require, "sqlite.db")
  if ok then
    vim.health.ok("kkharji/sqlite.lua is available")
  else
    vim.health.error("kkharji/sqlite.lua is missing", {
      "Install https://github.com/kkharji/sqlite.lua with your plugin manager",
      tostring(sqlite),
    })
  end

  local nui_ok, nui = pcall(require, "nui.popup")
  if nui_ok then
    vim.health.ok("MunifTanjim/nui.nvim is available")
  else
    vim.health.error("MunifTanjim/nui.nvim is missing", {
      "Install https://github.com/MunifTanjim/nui.nvim with your plugin manager",
      tostring(nui),
    })
  end

  local cfg_ok, cfg = pcall(function()
    return require("todo.config").get()
  end)
  if not cfg_ok then
    vim.health.error("Configuration is invalid: " .. tostring(cfg))
    return
  end

  local parent = vim.fs.dirname(cfg.db_path)
  if vim.fn.isdirectory(parent) == 1 then
    if vim.fn.filewritable(parent) == 2 then
      vim.health.ok("Database directory is writable: " .. parent)
    else
      vim.health.error("Database directory is not writable: " .. parent)
    end
  else
    local ancestor = vim.fs.dirname(parent)
    if vim.fn.filewritable(ancestor) == 2 then
      vim.health.ok("Database directory can be created: " .. parent)
    else
      vim.health.warn("Could not confirm database directory is writable: " .. parent)
    end
  end

  if ok then
    local opened, err = pcall(function()
      local db = sqlite:open(":memory:")
      db:eval("SELECT sqlite_version() AS version")
      db:close()
    end)
    if opened then
      vim.health.ok("SQLite dynamic library can be loaded")
    else
      vim.health.error("SQLite dynamic library could not be loaded", { tostring(err) })
    end
  end

  local prefix = cfg.keymaps.prefix
  for _, suffix in ipairs({ "t", "a", "f", "s", "e", "g" }) do
    local lhs = prefix .. suffix
    local mapping = vim.fn.maparg(lhs, "n", false, true)
    if type(mapping) == "table" and mapping.lhs and mapping.lhs ~= "" then
      if type(mapping.desc) == "string" and vim.startswith(mapping.desc, "todo.nvim:") then
        vim.health.ok("Default mapping active: " .. lhs)
      else
        vim.health.warn("Default mapping conflicts with an existing mapping: " .. lhs)
      end
    end
  end
end

return M
