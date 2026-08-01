local i18n = require("todo.i18n")
local model = require("todo.model")

local M = {}
local ns = vim.api.nvim_create_namespace("todo_form_errors")
local current

local function close()
  if current and vim.api.nvim_win_is_valid(current.win) then
    vim.api.nvim_win_close(current.win, true)
  end
  current = nil
end

local function lines_for(task)
  local description = vim.split(task.description or "", "\n", { plain = true })
  if #description == 0 then
    description = { "" }
  end
  local lines = {
    i18n.t("title") .. ": " .. (task.title or ""),
    i18n.t("priority") .. ": P" .. tostring(task.priority == nil and 2 or task.priority),
    i18n.t("deadline") .. ": " .. model.deadline_text(task),
    i18n.t("tags") .. ": " .. table.concat(task.tags or {}, ", "),
    i18n.t("status") .. ": " .. (task.status or "todo"),
    "",
    i18n.t("description") .. ":",
  }
  vim.list_extend(lines, description)
  lines[#lines + 1] = ""
  lines[#lines + 1] = i18n.t("form_help")
  return lines
end

local function after_colon(line)
  return line:match("^[^:：]+[:：]%s*(.*)$") or ""
end

local function parse(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local description = {}
  local help_line = math.max(8, #lines - 1)
  for index = 8, help_line do
    description[#description + 1] = lines[index] or ""
  end
  while #description > 0 and description[#description] == "" do
    table.remove(description)
  end
  return {
    title = after_colon(lines[1] or ""),
    priority = after_colon(lines[2] or ""),
    deadline = after_colon(lines[3] or ""),
    tags = after_colon(lines[4] or ""),
    status = after_colon(lines[5] or ""),
    description = table.concat(description, "\n"),
  }
end

local function show_errors(buf, errors)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local line_by_field = { title = 0, priority = 1, deadline = 2, status = 4 }
  for field, _ in pairs(errors or {}) do
    local message = field == "title" and i18n.t("title_required")
      or field == "priority" and i18n.t("invalid_priority")
      or field == "deadline" and i18n.t("invalid_deadline")
      or field == "status" and "todo | in_progress | done | cancelled"
      or tostring(field)
    if line_by_field[field] then
      vim.api.nvim_buf_set_extmark(buf, ns, line_by_field[field], 0, {
        virt_text = { { "  ! " .. message, "DiagnosticError" } },
        virt_text_pos = "eol",
      })
    end
  end
  vim.notify(i18n.t("invalid_form"), vim.log.levels.ERROR)
end

function M.open(task, on_save)
  close()
  task = task or {}
  local width = math.min(78, math.max(40, vim.o.columns - 8))
  local height = math.min(18, math.max(10, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "todoform"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines_for(task))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = require("todo.config").get().ui.float.border,
    title = " Todo ",
    title_pos = "center",
  })
  current = { buf = buf, win = win }
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true

  local function save()
    local input = parse(buf)
    local normalized, errors = model.validate(input)
    if not normalized then
      show_errors(buf, errors)
      return
    end
    local ok, result, save_errors = pcall(on_save, input)
    if not ok then
      vim.notify(i18n.t("db_error", result), vim.log.levels.ERROR)
      return
    end
    if not result then
      show_errors(buf, save_errors)
      return
    end
    close()
    vim.notify(i18n.t("saved"), vim.log.levels.INFO)
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = buf, desc = i18n.t("save") })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = i18n.t("cancel") })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = i18n.t("cancel") })
  vim.api.nvim_win_set_cursor(win, { 1, #(task.title or "") + #i18n.t("title") + 2 })
  vim.cmd("startinsert!")
end

return M
