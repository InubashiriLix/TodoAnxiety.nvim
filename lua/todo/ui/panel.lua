local config = require("todo.config")
local i18n = require("todo.i18n")
local urgency = require("todo.urgency")
local form = require("todo.ui.form")

local M = {}
local ns = vim.api.nvim_create_namespace("todo_panel")
local state = {
  buf = nil,
  win = nil,
  mode = nil,
  view = "active",
  tasks = {},
  line_to_task = {},
  filters = {},
  selected_id = nil,
}

local status_icons = { todo = "○", in_progress = "▶", done = "✓", cancelled = "×" }
local tag_highlights = {
  "DiagnosticOk",
  "DiagnosticInfo",
  "DiagnosticHint",
  "DiagnosticWarn",
  "String",
  "Identifier",
  "Type",
  "Special",
}

local function valid()
  return state.win and vim.api.nvim_win_is_valid(state.win) and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function hash_tag(tag)
  local value = 0
  for index = 1, #tag do
    value = (value * 31 + tag:byte(index)) % #tag_highlights
  end
  return tag_highlights[value + 1]
end

local function service()
  return require("todo")._service()
end

local function selected_task()
  if not valid() then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.line_to_task[line] or (state.selected_id and service().store:get(state.selected_id)) or nil
end

local function urgency_reason(info)
  if info.reason == "due_in_days" then
    return i18n.t("due_in_days", info.days)
  end
  return i18n.t(info.reason)
end

local function task_line(task)
  local parts = {
    status_icons[task.status] or "?",
    " P" .. task.priority,
    "  " .. task.title,
  }
  if task.due_date then
    parts[#parts + 1] = "  ⏱ " .. task.due_date .. (task.due_time and (" " .. task.due_time) or "")
  end
  if task.urgency then
    parts[#parts + 1] = "  [" .. i18n.t(task.urgency.level) .. " · " .. urgency_reason(task.urgency) .. "]"
  end
  for _, tag in ipairs(task.tags) do
    parts[#parts + 1] = "  #" .. tag
  end
  return table.concat(parts)
end

local function filter_summary()
  local bits = {}
  for _, key in ipairs({ "search", "status", "priority", "tag" }) do
    local value = state.filters[key]
    if value and value ~= "" and value ~= "all" then
      bits[#bits + 1] = key .. "=" .. value
    end
  end
  return #bits > 0 and ("  [" .. table.concat(bits, " ") .. "]") or ""
end

local function render_details(task, start_line)
  local lines = { "", "─ " .. i18n.t("details") .. " " .. string.rep("─", 12) }
  if task then
    lines[#lines + 1] = i18n.t("title") .. ": " .. task.title
    lines[#lines + 1] = i18n.t("status")
      .. ": "
      .. task.status
      .. "    "
      .. i18n.t("priority")
      .. ": P"
      .. task.priority
    lines[#lines + 1] = i18n.t("deadline")
      .. ": "
      .. (task.due_date and (task.due_date .. (task.due_time and " " .. task.due_time or "")) or "—")
    lines[#lines + 1] = i18n.t("tags") .. ": " .. (#task.tags > 0 and table.concat(task.tags, ", ") or "—")
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(task.description ~= "" and task.description or "—", "\n", { plain = true }))
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, start_line, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function render()
  if not valid() then
    return
  end
  local ok, tasks_or_error = pcall(function()
    return service():list(state.view, state.filters)
  end)
  if not ok then
    vim.notify(i18n.t("db_error", tasks_or_error), vim.log.levels.ERROR)
    return
  end
  state.tasks = tasks_or_error
  state.line_to_task = {}
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  local lines = {
    " TODO.NVIM  •  " .. i18n.t(state.view) .. "  (" .. #state.tasks .. ")" .. filter_summary(),
    " " .. i18n.t("panel_help"),
    "",
  }
  if #state.tasks == 0 then
    lines[#lines + 1] = "  " .. i18n.t("no_tasks")
  else
    for _, task in ipairs(state.tasks) do
      local line_number = #lines + 1
      lines[#lines + 1] = task_line(task)
      state.line_to_task[line_number] = task
      if task.id == state.selected_id then
        state.selected_line = line_number
      end
    end
  end
  local detail_start = #lines
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  vim.api.nvim_buf_set_extmark(state.buf, ns, 1, 0, { end_col = #lines[2], hl_group = "Comment" })
  for line_number, task in pairs(state.line_to_task) do
    local line = lines[line_number]
    local pstart = line:find("P" .. task.priority, 1, true)
    if pstart then
      local p_hl = ({ [0] = "DiagnosticError", [1] = "DiagnosticWarn", [2] = "DiagnosticInfo", [3] = "Comment" })[task.priority]
      vim.api.nvim_buf_set_extmark(
        state.buf,
        ns,
        line_number - 1,
        pstart - 1,
        { end_col = pstart + 1, hl_group = p_hl }
      )
    end
    for _, tag in ipairs(task.tags) do
      local marker = "#" .. tag
      local from = line:find(marker, 1, true)
      if from then
        vim.api.nvim_buf_set_extmark(
          state.buf,
          ns,
          line_number - 1,
          from - 1,
          { end_col = from - 1 + #marker, hl_group = hash_tag(tag) }
        )
      end
    end
  end
  local initial = state.selected_line or (#state.tasks > 0 and 4 or 1)
  state.selected_line = nil
  pcall(vim.api.nvim_win_set_cursor, state.win, { initial, 0 })
  local task = state.line_to_task[initial] or state.tasks[1]
  state.selected_id = task and task.id or nil
  render_details(task, detail_start)
end

local function refresh_details()
  local task = selected_task()
  if not task then
    return
  end
  state.selected_id = task.id
  local start_line = 3 + math.max(#state.tasks, 1)
  render_details(task, start_line)
end

local function require_task()
  local task = selected_task()
  if not task then
    vim.notify(i18n.t("missing_task"), vim.log.levels.WARN)
  end
  return task
end

local function change_status(status)
  local task = require_task()
  if not task then
    return
  end
  local ok, result = pcall(function()
    return service():set_status(task.id, status)
  end)
  if not ok or not result then
    vim.notify(i18n.t("db_error", result), vim.log.levels.ERROR)
  else
    render()
  end
end

local function edit_task()
  local task = require_task()
  if not task then
    return
  end
  form.open(task, function(input)
    local result, errors = service():update(task.id, input)
    if result then
      vim.schedule(render)
    end
    return result, errors
  end)
end

local function add_task()
  form.open({}, function(input)
    local result, errors = service():create(input)
    if result then
      state.selected_id = result.id
      vim.schedule(render)
    end
    return result, errors
  end)
end

local function archive_task(restore)
  local task = require_task()
  if not task then
    return
  end
  local ok, result = pcall(function()
    return restore and service():restore(task.id) or service():archive(task.id)
  end)
  if not ok or not result then
    vim.notify(i18n.t("db_error", result), vim.log.levels.ERROR)
    return
  end
  vim.notify(i18n.t(restore and "restored" or "archived_ok"), vim.log.levels.INFO)
  state.selected_id = nil
  render()
end

local function choose_view()
  local choices = { "active", "emergency", "archived" }
  vim.ui.select(choices, { prompt = i18n.t("filter"), format_item = i18n.t }, function(choice)
    if choice then
      state.view = choice
      state.selected_id = nil
      render()
    end
  end)
end

local function choose_filter()
  vim.ui.select({ "status", "priority", "tag", "clear" }, { prompt = i18n.t("filter") }, function(kind)
    if kind == "clear" then
      state.filters = {}
      render()
    elseif kind == "status" then
      vim.ui.select({ "all", "todo", "in_progress", "done", "cancelled" }, { prompt = "status" }, function(value)
        if value then
          state.filters.status = value
          render()
        end
      end)
    elseif kind == "priority" then
      vim.ui.select({ "all", "P0", "P1", "P2", "P3" }, { prompt = "priority" }, function(value)
        if value then
          state.filters.priority = value
          render()
        end
      end)
    elseif kind == "tag" then
      vim.ui.input({ prompt = "tag: ", default = state.filters.tag or "" }, function(value)
        if value ~= nil then
          state.filters.tag = value
          render()
        end
      end)
    end
  end)
end

local function set_mappings(buf)
  local opts = function(desc)
    return { buffer = buf, silent = true, desc = desc }
  end
  vim.keymap.set("n", "q", M.close, opts("Close todo panel"))
  vim.keymap.set("n", "a", add_task, opts("Add task"))
  vim.keymap.set("n", "e", edit_task, opts("Edit task"))
  vim.keymap.set("n", "s", function()
    change_status("in_progress")
  end, opts("Start task"))
  vim.keymap.set("n", "x", function()
    change_status("done")
  end, opts("Complete task"))
  vim.keymap.set("n", "c", function()
    change_status("cancelled")
  end, opts("Cancel task"))
  vim.keymap.set("n", "u", function()
    change_status("todo")
  end, opts("Reopen task"))
  vim.keymap.set("n", "A", function()
    archive_task(false)
  end, opts("Archive task"))
  vim.keymap.set("n", "R", function()
    archive_task(true)
  end, opts("Restore task"))
  vim.keymap.set("n", "r", render, opts("Refresh tasks"))
  vim.keymap.set("n", "<CR>", refresh_details, opts("Show task details"))
  vim.keymap.set("n", "v", choose_view, opts("Choose todo view"))
  vim.keymap.set("n", "f", choose_filter, opts("Filter tasks"))
  vim.keymap.set("n", "/", function()
    vim.ui.input({ prompt = i18n.t("search") .. ": ", default = state.filters.search or "" }, function(value)
      if value ~= nil then
        state.filters.search = value
        render()
      end
    end)
  end, opts("Search tasks"))
  vim.keymap.set("n", "?", function()
    vim.notify(i18n.t("panel_help"), vim.log.levels.INFO)
  end, opts("Todo help"))
end

local function create_window(mode)
  local cfg = config.get().ui
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "todo"
  local win
  if mode == "sidebar" then
    vim.cmd(cfg.sidebar.side == "left" and "topleft vsplit" or "botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, math.max(1, math.min(cfg.sidebar.width, vim.o.columns - 2)))
  else
    local width = math.max(30, math.floor(vim.o.columns * cfg.float.width))
    local height = math.max(8, math.floor((vim.o.lines - 2) * cfg.float.height))
    width = math.max(1, math.min(width, vim.o.columns - 4))
    height = math.max(1, math.min(height, vim.o.lines - 4))
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = cfg.float.border,
      title = " Todo.nvim ",
      title_pos = "center",
    })
  end
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  return buf, win
end

function M.open(opts)
  opts = opts or {}
  vim.validate({
    mode = {
      opts.mode,
      function(v)
        return v == nil or v == "float" or v == "sidebar"
      end,
      "'float' or 'sidebar'",
    },
    view = {
      opts.view,
      function(v)
        return v == nil or v == "active" or v == "emergency" or v == "archived"
      end,
      "valid todo view",
    },
  })
  if valid() then
    M.close()
  end
  state.mode = opts.mode or config.get().ui.default_mode
  state.view = opts.view or config.get().ui.default_view
  state.filters = opts.filters or {}
  state.buf, state.win = create_window(state.mode)
  set_mappings(state.buf)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.buf,
    callback = function()
      if valid() then
        refresh_details()
      end
    end,
  })
  render()
end

function M.close()
  if valid() then
    vim.api.nvim_win_close(state.win, true)
  end
  state.buf, state.win = nil, nil
end

function M.toggle(opts)
  if valid() then
    M.close()
  else
    M.open(opts)
  end
end

function M.refresh()
  if valid() then
    render()
  end
end

function M.current_task()
  return selected_task()
end

function M.is_open()
  return valid()
end

function M.inspect_state()
  return state
end

return M
