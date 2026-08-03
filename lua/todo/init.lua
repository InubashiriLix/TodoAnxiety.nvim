local config = require("todo.config")
local i18n = require("todo.i18n")

local M = {}
local store_instance
local service_instance
local registered_maps = {}
local highlights_registered = false

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
  local icons = maps.icons or {}
  local definitions = {
    {
      maps.mappings.toggle,
      function()
        M.toggle()
      end,
      "toggle",
      icons.toggle or "",
    },
    {
      maps.mappings.add,
      function()
        M.add()
      end,
      "add task",
      icons.add or "",
    },
    {
      maps.mappings.open_float,
      function()
        M.open({ mode = "float" })
      end,
      "open float",
      icons.open_float or "",
    },
    {
      maps.mappings.open_sidebar,
      function()
        M.open({ mode = "sidebar" })
      end,
      "open sidebar",
      icons.open_sidebar or "",
    },
    {
      maps.mappings.open_emergency,
      function()
        M.open({ mode = "float", view = "emergency" })
      end,
      "open emergency",
      icons.open_emergency or "",
    },
    {
      maps.mappings.manage_tags,
      function()
        M.tags()
      end,
      "manage tags",
      icons.manage_tags or "",
    },
  }
  for _, definition in ipairs(definitions) do
    if definition[1] == false then
      goto continue
    end
    local lhs = prefix .. definition[1]
    if vim.fn.maparg(lhs, "n") == "" then
      local desc = "todo.nvim: " .. definition[3]
      if definition[4] ~= "" then
        desc = "todo.nvim: " .. definition[4] .. " " .. definition[3]
      end
      vim.keymap.set("n", lhs, definition[2], { silent = true, desc = desc })
      registered_maps[#registered_maps + 1] = lhs
    else
      vim.schedule(function()
        vim.notify(i18n.t("key_conflict", lhs), vim.log.levels.WARN, { title = "todo.nvim" })
      end)
    end
    ::continue::
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
  require("todo.ui.highlights").setup()
  if not highlights_registered then
    highlights_registered = true
    local group = vim.api.nvim_create_augroup("TodoNvimHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = function()
        require("todo.ui.highlights").setup()
      end,
    })
  end
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

function M.tags()
  require("todo.ui.tag_panel").open({
    on_close = function()
      require("todo.ui.panel").refresh()
    end,
  })
end

function M.add(opts)
  opts = opts or {}
  local panel = require("todo.ui.panel")
  if panel.add(opts) then
    return
  end
  require("todo.ui.form").open({ title = opts.title or "" }, function(input)
    local result, errors = M._service():create(input)
    if result then
      require("todo.ui.panel").refresh()
    end
    return result, errors
  end)
end

function M.edit(id)
  local panel = require("todo.ui.panel")
  if panel.edit(id) then
    return
  end
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

function M.delete(id)
  local result, errors = M._service():delete_archived(id)
  if not result then
    if errors and errors.id then
      error(i18n.t("task_not_found", id))
    elseif errors and errors.archived then
      error(i18n.t("delete_archived_only"))
    end
    error(i18n.t("delete_failed"))
  end
  require("todo.ui.panel").refresh()
  return result
end

function M._reset_for_tests()
  close_store()
end

return M
