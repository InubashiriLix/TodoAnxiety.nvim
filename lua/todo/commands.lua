local M = {}

local actions = {
  start = "in_progress",
  done = "done",
  cancel = "cancelled",
  reopen = "todo",
}

local function split_words(value)
  return vim.split(vim.trim(value or ""), "%s+", { trimempty = true })
end

local function resolve_id(raw)
  if raw and raw ~= "" then
    local id = tonumber(raw)
    if not id or id < 1 or id % 1 ~= 0 then
      error("task ID must be a number")
    end
    return id
  end
  local task = require("todo.ui.panel").current_task()
  if not task then
    error(require("todo.i18n").t("missing_task"))
  end
  return task.id
end

local function notify_error(err)
  vim.notify(tostring(err), vim.log.levels.ERROR, { title = "todo.nvim" })
end

function M.run(args)
  local command, rest = (args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command ~= "" and command or "open"
  local todo = require("todo")
  local ok, err = pcall(function()
    if command == "open" then
      local words = split_words(rest)
      local mode, view
      for _, word in ipairs(words) do
        if word == "float" or word == "sidebar" then
          mode = word
        end
        if word == "active" or word == "emergency" or word == "archived" then
          view = word
        end
      end
      todo.open({ mode = mode, view = view })
    elseif command == "toggle" then
      local words = split_words(rest)
      todo.toggle({ mode = words[1] })
    elseif command == "add" then
      todo.add({ title = rest })
    elseif command == "tags" then
      todo.tags()
    elseif command == "edit" then
      todo.edit(resolve_id(rest))
    elseif actions[command] then
      todo.set_status(resolve_id(rest), actions[command])
    elseif command == "archive" then
      todo.archive(resolve_id(rest))
    elseif command == "restore" then
      todo.restore(resolve_id(rest))
    elseif command == "delete" then
      todo.delete(resolve_id(rest))
    elseif command == "close" then
      todo.close()
    else
      error("unknown Todo subcommand: " .. command)
    end
  end)
  if not ok then
    notify_error(err)
  end
end

function M.complete(arglead, cmdline)
  local input = cmdline:gsub("^%s*", "")
  if input:sub(1, 1) == ":" then
    input = input:sub(2):gsub("^%s*", "")
  end
  local after_todo = input:match("^Todo!?%s*(.*)$") or ""
  local command = after_todo:match("^(%S+)%s+")
  if not command then
    local commands = {
      "open",
      "toggle",
      "add",
      "tags",
      "edit",
      "start",
      "done",
      "cancel",
      "reopen",
      "archive",
      "restore",
      "delete",
      "close",
    }
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arglead)
    end, commands)
  end
  if command == "open" then
    local options = { "float", "sidebar", "active", "emergency", "archived" }
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arglead)
    end, options)
  elseif command == "toggle" then
    return vim.tbl_filter(function(item)
      return vim.startswith(item, arglead)
    end, { "float", "sidebar" })
  end
  return {}
end

return M
