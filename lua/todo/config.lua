local M = {}

local defaults = {
  db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
  language = "en",
  ui = {
    default_mode = "float",
    default_view = "active",
    float = { width = 0.80, height = 0.75, border = "rounded" },
    sidebar = { width = 42, side = "right" },
  },
  keymaps = {
    enabled = true,
    prefix = "<leader>T",
  },
}

local current = vim.deepcopy(defaults)

local function validate(opts)
  vim.validate({
    db_path = { opts.db_path, "string" },
    language = {
      opts.language,
      function(v)
        return v == "en" or v == "zh-CN"
      end,
      "'en' or 'zh-CN'",
    },
    ui = { opts.ui, "table" },
    keymaps = { opts.keymaps, "table" },
  })
  vim.validate({
    default_mode = {
      opts.ui.default_mode,
      function(v)
        return v == "float" or v == "sidebar"
      end,
      "'float' or 'sidebar'",
    },
    default_view = {
      opts.ui.default_view,
      function(v)
        return v == "active" or v == "emergency" or v == "archived"
      end,
      "valid todo view",
    },
    keymaps_enabled = { opts.keymaps.enabled, "boolean" },
    keymaps_prefix = { opts.keymaps.prefix, "string" },
    float = { opts.ui.float, "table" },
    sidebar = { opts.ui.sidebar, "table" },
  })
  vim.validate({
    float_width = {
      opts.ui.float.width,
      function(v)
        return type(v) == "number" and v > 0 and v <= 1
      end,
      "number in (0, 1]",
    },
    float_height = {
      opts.ui.float.height,
      function(v)
        return type(v) == "number" and v > 0 and v <= 1
      end,
      "number in (0, 1]",
    },
    sidebar_width = {
      opts.ui.sidebar.width,
      function(v)
        return type(v) == "number" and v >= 20 and v % 1 == 0
      end,
      "integer >= 20",
    },
    sidebar_side = {
      opts.ui.sidebar.side,
      function(v)
        return v == "left" or v == "right"
      end,
      "'left' or 'right'",
    },
  })
  assert(opts.keymaps.prefix ~= "", "keymaps.prefix must not be empty")
end

function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  validate(current)
  return current
end

function M.get()
  return current
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
