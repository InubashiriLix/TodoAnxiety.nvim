local config = require("todo.config")
local i18n = require("todo.i18n")

local M = {}
local store_instance
local service_instance
local registered_maps = {}

local function close_store()
  if store_instance then
    pcall(function()
      store_instance:close()
    end)
  end
  store_instance, service_instance = nil, nil
end

local function map_is_ours(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  return type(mapping) == "table" and type(mapping.desc) == "string" and vim.startswith(mapping.desc, "todo.nvim:")
end

local function register_keymaps()
  for _, lhs in ipairs(registered_maps) do
    if map_is_ours(lhs) then
      pcall(vim.keymap.del, "n", lhs)
    end
  end
  registered_maps = {}
  local maps = config.get().keymaps
  if not maps.enabled then
    return
  end
  local prefix = maps.prefix
  local definitions = {
    {
      "t",
      function()
        M.toggle()
      end,
      "toggle",
    },
    {
      "a",
      function()
        M.add()
      end,
      "add task",
    },
    {
      "f",
      function()
        M.open({ mode = "float" })
      end,
      "open float",
    },
    {
      "s",
      function()
        M.open({ mode = "sidebar" })
      end,
      "open sidebar",
    },
    {
      "e",
      function()
        M.open({ mode = "float", view = "emergency" })
      end,
      "open emergency",
    },
  }
  for _, definition in ipairs(definitions) do
    local lhs = prefix .. definition[1]
    if vim.fn.maparg(lhs, "n") == "" then
      vim.keymap.set("n", lhs, definition[2], { silent = true, desc = "todo.nvim: " .. definition[3] })
      registered_maps[#registered_maps + 1] = lhs
    else
      vim.schedule(function()
        vim.notify(i18n.t("key_conflict", lhs), vim.log.levels.WARN, { title = "todo.nvim" })
      end)
    end
  end
end

function M.setup(opts)
  local old_path = config.get().db_path
  local result = config.setup(opts)
  if old_path ~= result.db_path then
    close_store()
  end
  register_keymaps()
  return result
end

function M._bootstrap()
  register_keymaps()
end

function M._service()
  if service_instance then
    return service_instance
  end
  local Store = require("todo.store")
  store_instance = Store.open(config.get().db_path)
  service_instance = require("todo.service").new(store_instance)
  return service_instance
end

function M.open(opts)
  require("todo.ui.panel").open(opts)
end

function M.toggle(opts)
  require("todo.ui.panel").toggle(opts)
end

function M.close()
  require("todo.ui.panel").close()
end

function M.add(opts)
  opts = opts or {}
  require("todo.ui.form").open({ title = opts.title or "" }, function(input)
    local result, errors = M._service():create(input)
    if result then
      require("todo.ui.panel").refresh()
    end
    return result, errors
  end)
end

function M.edit(id)
  local task = M._service().store:get(id)
  if not task then
    error(i18n.t("task_not_found", id))
  end
  require("todo.ui.form").open(task, function(input)
    local result, errors = M._service():update(id, input)
    if result then
      require("todo.ui.panel").refresh()
    end
    return result, errors
  end)
end

function M.set_status(id, status)
  local result, errors = M._service():set_status(id, status)
  if not result then
    if errors and errors.id then
      error(i18n.t("task_not_found", id))
    end
    error("invalid status: " .. tostring(status))
  end
  require("todo.ui.panel").refresh()
  return result
end

function M.archive(id)
  local result, errors = M._service():archive(id)
  if not result then
    error(errors and i18n.t("task_not_found", id) or "archive failed")
  end
  require("todo.ui.panel").refresh()
  return result
end

function M.restore(id)
  local result, errors = M._service():restore(id)
  if not result then
    error(errors and i18n.t("task_not_found", id) or "restore failed")
  end
  require("todo.ui.panel").refresh()
  return result
end

function M._reset_for_tests()
  close_store()
end

return M
