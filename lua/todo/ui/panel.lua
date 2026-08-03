local config = require("todo.config")
local highlights = require("todo.ui.highlights")
local i18n = require("todo.i18n")
local form = require("todo.ui.form")
local urgency = require("todo.urgency")
local viewmodel = require("todo.ui.viewmodel")

local Input = require("nui.input")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
local Popup = require("nui.popup")
local Split = require("nui.split")

local M = {}
local ns = vim.api.nvim_create_namespace("todo_dashboard")
local state = {
  owner = nil,
  mode = nil,
  view = "active",
  tasks = {},
  stats = { active = 0, emergency = 0, archived = 0 },
  filters = {},
  selected_id = nil,
  task_order = {},
  task_lines = {},
  tab_spans = {},
  tab_line = 1,
}

local function service()
  return require("todo")._service()
end

local function owner_valid()
  local owner = state.owner
  if not owner or owner.closed then
    return false
  end
  if owner.split then
    return owner.split.winid and vim.api.nvim_win_is_valid(owner.split.winid)
  end
  return owner.layout ~= nil and owner.list.winid and vim.api.nvim_win_is_valid(owner.list.winid)
end

local function owner_has_window(owner, winid)
  if not owner or not winid or not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  for _, name in ipairs({ "split", "header", "list", "footer", "detail", "detail_overlay", "transient" }) do
    local component = owner[name]
    if component and component.winid == winid then
      return true
    end
  end
  return false
end

local function tag_panel_has_window(winid)
  local tag_panel = package.loaded["todo.ui.tag_panel"]
  if type(tag_panel) ~= "table" or type(tag_panel.inspect_state) ~= "function" then
    return false
  end
  local tag_owner = tag_panel.inspect_state()
  if not tag_owner or tag_owner.closed then
    return false
  end
  for _, name in ipairs({ "popup", "transient" }) do
    local component = tag_owner[name]
    if component and component.winid == winid then
      return true
    end
  end
  return false
end

local function todo_has_window(owner, winid)
  return owner_has_window(owner, winid) or tag_panel_has_window(winid)
end

local function selected_task()
  for _, task in ipairs(state.tasks) do
    if task.id == state.selected_id then
      return task
    end
  end
  return nil
end

local function set_buffer(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function add_hl(buf, line, from, to, group)
  local content = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or ""
  from = math.max(0, math.min(from, #content))
  if to < 0 then
    to = #content
  end
  to = math.max(from, math.min(to, #content))
  if to == from then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, ns, line, from, {
    end_col = to,
    hl_group = group,
    priority = 120,
  })
end

local function filter_summary()
  local bits = {}
  for _, key in ipairs({ "search", "status", "priority", "tag" }) do
    local value = state.filters[key]
    if value and value ~= "" and value ~= "all" then
      bits[#bits + 1] = key .. ":" .. value
    end
  end
  return bits
end

local function header_content(compact, width)
  local line = compact and ("  TODO.NVIM · " .. i18n.t(state.view)) or "  TODO.NVIM  "
  local spans = {}
  local tabs = compact and " " or line
  for _, view in ipairs({ "active", "emergency", "archived" }) do
    local label = i18n.t(compact and (view .. "_short") or view)
    local text = string.format("[ %s %d ]", label, state.stats[view] or 0)
    local from = #tabs
    tabs = tabs .. text .. " "
    spans[#spans + 1] = { from = from, to = from + #text, view = view }
  end
  local filters = filter_summary()
  if compact then
    local result = {
      viewmodel.truncate(line, width),
      viewmodel.truncate(tabs, width),
    }
    if #filters > 0 then
      result[#result + 1] = viewmodel.truncate("  " .. table.concat(filters, "   "), width)
    end
    return result, spans, 2
  end
  local second = #filters > 0 and ("  " .. table.concat(filters, "   ")) or ("  / " .. i18n.t("search_placeholder"))
  return { tabs, second }, spans, 1
end

local function urgency_label(task)
  if not urgency.is_candidate(task) then
    return nil
  end
  local info = task.urgency or urgency.calculate(task)
  task.urgency = info
  return i18n.t(info.level)
end

local function list_content(width)
  local lines, mappings, order, decorations = {}, {}, {}, {}
  local sections = viewmodel.sections(state.tasks, state.view)
  for _, section in ipairs(sections) do
    lines[#lines + 1] = string.format("  %s  %d", section.label, #section.tasks)
    decorations[#decorations + 1] = { line = #lines - 1, from = 2, to = #lines[#lines], group = "TodoHeader" }
    for _, task in ipairs(section.tasks) do
      local line1, line2 = viewmodel.card(task, math.max(10, width - 3), urgency_label(task))
      local first = #lines + 1
      lines[#lines + 1] = " " .. line1
      lines[#lines + 1] = " " .. line2
      lines[#lines + 1] = ""
      mappings[first] = task
      mappings[first + 1] = task
      order[#order + 1] = task
      local priority_start = lines[first]:find("P" .. task.priority, 1, true)
      if priority_start then
        decorations[#decorations + 1] = {
          line = first - 1,
          from = priority_start - 1,
          to = priority_start + 1,
          group = "TodoPriority" .. task.priority,
        }
      end
      for _, tag in ipairs(task.tags or {}) do
        local marker = "#" .. tag
        local tag_start = lines[first + 1]:find(marker, 1, true)
        if tag_start then
          decorations[#decorations + 1] = {
            line = first,
            from = tag_start - 1,
            to = tag_start - 1 + #marker,
            group = highlights.tag(tag),
          }
        end
      end
      if task.id == state.selected_id then
        decorations[#decorations + 1] = { line = first - 1, from = 0, to = -1, group = "TodoSelected", whole = true }
        decorations[#decorations + 1] = { line = first, from = 0, to = -1, group = "TodoSelected", whole = true }
      end
    end
  end
  if #order == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. i18n.t("no_tasks")
    decorations[#decorations + 1] = { line = #lines - 1, from = 2, to = #lines[#lines], group = "TodoMuted" }
  end
  return lines, mappings, order, decorations
end

local function detail_content(task)
  if not task then
    return { "", "  " .. i18n.t("no_tasks") }, {}
  end
  local info = urgency.is_candidate(task) and (task.urgency or urgency.calculate(task)) or nil
  local lines = {
    " " .. task.title,
    "",
    string.format(" %s: %s", i18n.t("status"), i18n.t(task.status)),
    string.format(" %s: P%d", i18n.t("priority"), task.priority),
    string.format(
      " %s: %s",
      i18n.t("deadline"),
      task.due_date and (task.due_date .. (task.due_time and (" " .. task.due_time) or "")) or "—"
    ),
  }
  if info then
    lines[#lines + 1] = " " .. i18n.t(info.level)
  end
  lines[#lines + 1] = " " .. i18n.t("tags") .. ": " .. (#task.tags > 0 and table.concat(task.tags, "  ") or "—")
  lines[#lines + 1] = ""
  lines[#lines + 1] = " " .. i18n.t("description")
  lines[#lines + 1] = ""
  for _, line in
    ipairs(vim.split(task.description ~= "" and task.description or i18n.t("no_description"), "\n", { plain = true }))
  do
    lines[#lines + 1] = " " .. line
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format(" %s: %s", i18n.t("created"), os.date("%Y-%m-%d %H:%M", task.created_at))
  lines[#lines + 1] = string.format(" %s: %s", i18n.t("updated"), os.date("%Y-%m-%d %H:%M", task.updated_at))
  lines[#lines + 1] = ""
  lines[#lines + 1] = " [ e "
    .. i18n.t("action_edit")
    .. " ]  [ s "
    .. i18n.t("in_progress")
    .. " ]  [ x "
    .. i18n.t("done")
    .. " ]"
  local description_index = info and 9 or 8
  return lines,
    {
      { line = 0, from = 1, to = #lines[1], group = "TodoHeader" },
      { line = description_index - 1, from = 1, to = #lines[description_index], group = "TodoHeader" },
    }
end

local function apply_decorations(buf, decorations, offset)
  offset = offset or 0
  for _, item in ipairs(decorations) do
    if item.whole then
      vim.api.nvim_buf_set_extmark(buf, ns, item.line + offset, 0, {
        end_row = item.line + offset + 1,
        hl_group = item.group,
        hl_eol = true,
        priority = 80,
      })
    else
      add_hl(buf, item.line + offset, item.from, item.to, item.group)
    end
  end
end

local function footer_text(compact)
  local line = " "
  local items = compact
      and {
        { key = "a", label = "+" },
        { key = "e", label = "✎" },
        { key = "x", label = "✓" },
        { key = "/", label = "" },
        { key = "f", label = "" },
        { key = "?", label = "" },
      }
    or {
      { key = "a", label = i18n.t("action_add") },
      { key = "e", label = i18n.t("action_edit") },
      { key = "x", label = i18n.t("action_complete") },
      { key = "/", label = i18n.t("search") },
      { key = "f", label = i18n.t("filter") },
      { key = "?", label = i18n.t("help") },
    }
  if state.view == "archived" then
    table.insert(items, 4, { key = "D", label = compact and "" or i18n.t("action_delete") })
  end
  for _, item in ipairs(items) do
    local text = item.label == "" and string.format("[%s] ", item.key)
      or string.format("[%s %s] ", item.key, item.label)
    line = line .. text
  end
  return line
end

local function focus_selected(owner)
  local win = owner.split and owner.split.winid or owner.list.winid
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local selected_line
  for line, task in pairs(state.task_lines) do
    if task.id == state.selected_id then
      selected_line = not selected_line and line or math.min(selected_line, line)
    end
  end
  if selected_line then
    pcall(vim.api.nvim_win_set_cursor, win, { selected_line, 0 })
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("normal! zz")
    end)
  end
end

local render

local function render_float(owner)
  local header, spans, tab_line = header_content()
  state.tab_spans, state.tab_line = spans, tab_line
  set_buffer(owner.header.bufnr, header)
  add_hl(owner.header.bufnr, 0, 2, 11, "TodoHeader")
  for _, span in ipairs(spans) do
    add_hl(owner.header.bufnr, 0, span.from, span.to, span.view == state.view and "TodoTabActive" or "TodoTabInactive")
  end
  add_hl(owner.header.bufnr, 1, 0, #header[2], "TodoMuted")

  local width = vim.api.nvim_win_get_width(owner.list.winid)
  local lines, mappings, order, decorations = list_content(width)
  state.task_lines, state.task_order = mappings, order
  set_buffer(owner.list.bufnr, lines)
  owner.list.border:set_text("top", " " .. i18n.t(state.view) .. " ", "left")
  apply_decorations(owner.list.bufnr, decorations)

  if owner.detail then
    local details, detail_decorations = detail_content(selected_task())
    set_buffer(owner.detail.bufnr, details)
    apply_decorations(owner.detail.bufnr, detail_decorations)
  end
  set_buffer(owner.footer.bufnr, { footer_text() })
  add_hl(owner.footer.bufnr, 0, 0, -1, "TodoMuted")
  focus_selected(owner)
end

local function render_sidebar(owner)
  local width = vim.api.nvim_win_get_width(owner.split.winid)
  local header, spans, tab_line = header_content(true, width)
  state.tab_spans, state.tab_line = spans, tab_line
  local list_lines, mappings, order, decorations = list_content(width)
  local lines = vim.list_extend(vim.deepcopy(header), { "" })
  local list_offset = #lines
  vim.list_extend(lines, list_lines)
  lines[#lines + 1] = footer_text(true)
  state.task_lines, state.task_order = {}, order
  for line, task in pairs(mappings) do
    state.task_lines[line + list_offset] = task
  end
  set_buffer(owner.split.bufnr, lines)
  add_hl(owner.split.bufnr, 0, 2, 11, "TodoHeader")
  for _, span in ipairs(spans) do
    add_hl(
      owner.split.bufnr,
      tab_line - 1,
      span.from,
      span.to,
      span.view == state.view and "TodoTabActive" or "TodoTabInactive"
    )
  end
  if #header > 2 then
    add_hl(owner.split.bufnr, 2, 0, -1, "TodoMuted")
  end
  apply_decorations(owner.split.bufnr, decorations, list_offset)
  add_hl(owner.split.bufnr, #lines - 1, 0, -1, "TodoMuted")
  focus_selected(owner)
end

render = function()
  if not owner_valid() then
    return
  end
  local ok, tasks, stats = pcall(function()
    return service():list(state.view, state.filters), service():stats()
  end)
  if not ok then
    vim.notify(i18n.t("db_error", tasks), vim.log.levels.ERROR)
    return
  end
  state.tasks, state.stats = tasks, stats
  if not selected_task() then
    state.selected_id = tasks[1] and tasks[1].id or nil
  end
  if state.owner.split then
    render_sidebar(state.owner)
  else
    render_float(state.owner)
  end
end

local function select_delta(delta)
  if #state.task_order == 0 then
    return
  end
  local current_index = 1
  for index, task in ipairs(state.task_order) do
    if task.id == state.selected_id then
      current_index = index
      break
    end
  end
  current_index = math.max(1, math.min(#state.task_order, current_index + delta))
  state.selected_id = state.task_order[current_index].id
  if state.owner.split then
    render_sidebar(state.owner)
  else
    render_float(state.owner)
  end
end

local function change_view(view)
  state.view, state.selected_id = view, nil
  render()
end

local function cycle_view(delta)
  local views = { "active", "emergency", "archived" }
  local index = 1
  for i, view in ipairs(views) do
    if view == state.view then
      index = i
      break
    end
  end
  change_view(views[(index - 1 + delta) % #views + 1])
end

local function open_task_form(task, save_task)
  local reopen = {
    mode = state.mode,
    view = state.view,
    filters = vim.deepcopy(state.filters),
    selected_id = state.selected_id,
  }
  M.close()
  form.open(task, function(input)
    local result, errors = save_task(input)
    if result then
      reopen.selected_id = result.id
    end
    return result, errors
  end, {
    on_close = function(reason)
      if reason ~= "replaced" and not owner_valid() then
        M.open(reopen)
      end
    end,
  })
end

local function add_task(opts)
  opts = opts or {}
  open_task_form({ title = opts.title or "" }, function(input)
    return service():create(input)
  end)
end

local function require_task()
  local task = selected_task()
  if not task then
    vim.notify(i18n.t("missing_task"), vim.log.levels.WARN)
  end
  return task
end

local function edit_task()
  local task = require_task()
  if not task then
    return
  end
  open_task_form(task, function(input)
    return service():update(task.id, input)
  end)
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
  state.selected_id = nil
  vim.notify(i18n.t(restore and "restored" or "archived_ok"), vim.log.levels.INFO)
  render()
end

local function close_transient(owner)
  if owner.transient then
    pcall(function()
      owner.transient:unmount()
    end)
    owner.transient = nil
  end
end

local function menu(owner, title, items, on_submit)
  close_transient(owner)
  local lines = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = Menu.item(item.label, { value = item.value })
  end
  local component = Menu({
    relative = "editor",
    position = "50%",
    border = { style = config.get().ui.float.border, text = { top = " " .. title .. " ", top_align = "center" } },
    win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder,CursorLine:TodoSelected" },
    zindex = 80,
  }, {
    lines = lines,
    min_width = 26,
    max_height = 14,
    on_close = function()
      owner.transient = nil
    end,
    on_submit = function(item)
      owner.transient = nil
      on_submit(item.value)
    end,
  })
  owner.transient = component
  component:mount()
end

local function delete_archived_task()
  local task = require_task()
  if not task then
    return
  end
  if not task.archived_at then
    vim.notify(i18n.t("delete_archived_only"), vim.log.levels.WARN)
    return
  end
  menu(state.owner, i18n.t("delete_task_title"), {
    { label = i18n.t("cancel"), value = false },
    { label = i18n.t("delete_task_confirm", task.id, task.title), value = true },
  }, function(confirmed)
    if not confirmed then
      return
    end
    local ok, deleted = pcall(function()
      return service():delete_archived(task.id)
    end)
    if not ok or not deleted then
      vim.notify(i18n.t("delete_failed"), vim.log.levels.ERROR)
      return
    end
    state.selected_id = nil
    vim.notify(i18n.t("deleted"), vim.log.levels.INFO)
    render()
  end)
end

local function open_filter()
  local owner = state.owner
  menu(owner, i18n.t("filter"), {
    { label = i18n.t("status"), value = "status" },
    { label = i18n.t("priority"), value = "priority" },
    { label = i18n.t("tags"), value = "tag" },
    { label = i18n.t("clear"), value = "clear" },
  }, function(kind)
    if kind == "clear" then
      state.filters = {}
      render()
      return
    end
    local values = {}
    if kind == "status" then
      values[#values + 1] = { label = i18n.t("all"), value = "all" }
      for _, value in ipairs({ "todo", "in_progress", "done", "cancelled" }) do
        values[#values + 1] = { label = i18n.t(value), value = value }
      end
    elseif kind == "priority" then
      values[#values + 1] = { label = i18n.t("all"), value = "all" }
      for value = 0, 3 do
        values[#values + 1] = { label = "P" .. value, value = "P" .. value }
      end
    else
      values[#values + 1] = { label = i18n.t("all"), value = "" }
      for _, tag in ipairs(service():list_tags()) do
        values[#values + 1] = { label = "#" .. tag, value = tag }
      end
    end
    menu(owner, i18n.t(kind == "tag" and "tags" or kind), values, function(value)
      state.filters[kind] = value
      render()
    end)
  end)
end

local function open_search()
  local owner = state.owner
  close_transient(owner)
  local search = Input({
    relative = "editor",
    position = { row = 2, col = "50%" },
    size = { width = math.max(10, math.min(60, vim.o.columns - 8)) },
    border = { style = config.get().ui.float.border, text = { top = " " .. i18n.t("search") .. " " } },
    win_options = { winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    zindex = 80,
  }, {
    default_value = state.filters.search or "",
    on_change = function(value)
      state.filters.search = value
      vim.schedule(render)
    end,
    on_submit = function(value)
      owner.transient = nil
      state.filters.search = value
      render()
    end,
    on_close = function()
      owner.transient = nil
      render()
    end,
  })
  owner.transient = search
  search:mount()
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = search.bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        if owner.closed or state.owner ~= owner or owner.transient ~= search then
          return
        end
        local target_win = vim.api.nvim_get_current_win()
        close_transient(owner)
        if owner.mode == "float" and not owner_has_window(owner, target_win) then
          M.close()
        else
          render()
        end
      end)
    end,
  })
end

local function show_help()
  local owner = state.owner
  close_transient(owner)
  local help = Popup({
    relative = "editor",
    position = "50%",
    size = { width = math.max(10, math.min(90, vim.o.columns - 8)), height = 5 },
    enter = true,
    border = {
      style = config.get().ui.float.border,
      text = { top = " " .. i18n.t("help") .. " ", top_align = "center" },
    },
    win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    zindex = 80,
  })
  owner.transient = help
  help:mount()
  vim.api.nvim_buf_set_lines(
    help.bufnr,
    0,
    -1,
    false,
    { "", "  " .. i18n.t("panel_help"), "", "  h/l focus list or details   [/] change view" }
  )
  local close = function()
    help:unmount()
    owner.transient = nil
  end
  vim.keymap.set("n", "q", close, { buffer = help.bufnr })
end

local function render_overlay(overlay)
  local lines, decorations = detail_content(selected_task())
  set_buffer(overlay.bufnr, lines)
  apply_decorations(overlay.bufnr, decorations)
end

local function open_details()
  local task = require_task()
  if not task then
    return
  end
  local owner = state.owner
  if owner.detail then
    vim.api.nvim_set_current_win(owner.detail.winid)
    return
  end
  if owner.detail_overlay then
    owner.detail_overlay:unmount()
  end
  local width = math.max(10, math.min(72, vim.o.columns - 6))
  local height = math.max(4, math.min(24, vim.o.lines - 6))
  local position = "50%"
  if owner.split and owner.split.winid and vim.api.nvim_win_is_valid(owner.split.winid) then
    local pos = vim.api.nvim_win_get_position(owner.split.winid)
    local split_width = vim.api.nvim_win_get_width(owner.split.winid)
    if pos[2] > width + 2 then
      position = { row = pos[1], col = pos[2] - width - 2 }
    elseif pos[2] + split_width + width + 2 < vim.o.columns then
      position = { row = pos[1], col = pos[2] + split_width + 1 }
    end
  end
  local overlay = Popup({
    relative = "editor",
    position = position,
    size = { width = width, height = height },
    enter = true,
    border = {
      style = config.get().ui.float.border,
      text = { top = " " .. i18n.t("details") .. " ", top_align = "center" },
    },
    win_options = { wrap = true, winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder" },
    zindex = 70,
  })
  owner.detail_overlay = overlay
  overlay:mount()
  render_overlay(overlay)
  local close = function()
    overlay:unmount()
    owner.detail_overlay = nil
  end
  vim.keymap.set("n", "q", close, { buffer = overlay.bufnr })
  vim.keymap.set("n", "e", edit_task, { buffer = overlay.bufnr })
  vim.keymap.set("n", "s", function()
    change_status("in_progress")
    render_overlay(overlay)
  end, { buffer = overlay.bufnr })
  vim.keymap.set("n", "x", function()
    change_status("done")
    render_overlay(overlay)
  end, { buffer = overlay.bufnr })
end

local function set_mappings(component, role)
  local buf = component.bufnr
  local opts = function(desc)
    return { buffer = buf, silent = true, desc = desc }
  end
  vim.keymap.set("n", "q", M.close, opts("Close todo dashboard"))
  vim.keymap.set("n", "j", function()
    select_delta(1)
  end, opts("Next task"))
  vim.keymap.set("n", "k", function()
    select_delta(-1)
  end, opts("Previous task"))
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
  vim.keymap.set("n", "D", delete_archived_task, opts("Permanently delete archived task"))
  vim.keymap.set("n", "r", render, opts("Refresh dashboard"))
  vim.keymap.set("n", "/", open_search, opts("Search tasks"))
  vim.keymap.set("n", "f", open_filter, opts("Filter tasks"))
  vim.keymap.set("n", "?", show_help, opts("Dashboard help"))
  vim.keymap.set("n", "g", function()
    require("todo").tags()
  end, opts("Manage tags"))
  vim.keymap.set("n", "[", function()
    cycle_view(-1)
  end, opts("Previous view"))
  vim.keymap.set("n", "]", function()
    cycle_view(1)
  end, opts("Next view"))
  vim.keymap.set("n", "v", function()
    menu(state.owner, i18n.t("filter"), {
      { label = i18n.t("active"), value = "active" },
      { label = i18n.t("emergency"), value = "emergency" },
      { label = i18n.t("archived"), value = "archived" },
    }, change_view)
  end, opts("Choose view"))
  vim.keymap.set("n", "<CR>", open_details, opts("Open details"))
  if role == "list" and state.owner and state.owner.detail then
    vim.keymap.set("n", "l", function()
      vim.api.nvim_set_current_win(state.owner.detail.winid)
    end, opts("Focus details"))
  elseif role == "detail" then
    vim.keymap.set("n", "h", function()
      vim.api.nvim_set_current_win(state.owner.list.winid)
    end, opts("Focus list"))
  end
end

local function base_popup(label, opts)
  opts = opts or {}
  return Popup({
    enter = opts.enter or false,
    focusable = opts.focusable ~= false,
    border = opts.border == false and "none" or {
      style = config.get().ui.float.border,
      text = { top = label and (" " .. label .. " ") or "", top_align = "left" },
    },
    buf_options = { buftype = "nofile", bufhidden = "hide", swapfile = false, modifiable = false },
    win_options = {
      wrap = opts.wrap or false,
      cursorline = false,
      number = false,
      relativenumber = false,
      winhighlight = "Normal:NormalFloat,FloatBorder:TodoBorder",
    },
  })
end

local function create_float(owner)
  local cfg = config.get().ui.float
  local width = math.max(10, math.min(vim.o.columns - 4, math.floor(vim.o.columns * cfg.width)))
  local height = math.max(6, math.min(vim.o.lines - 4, math.floor((vim.o.lines - 2) * cfg.height)))
  owner.wide = width >= 100
  owner.header = base_popup(nil, { border = false })
  owner.list = base_popup(i18n.t(state.view), { enter = true })
  owner.footer = base_popup(nil, { border = false })
  local body
  if owner.wide then
    owner.detail = base_popup(i18n.t("details"), { enter = false, wrap = true })
    body = Layout.Box({
      Layout.Box(owner.list, { size = "58%" }),
      Layout.Box(owner.detail, { size = "42%" }),
    }, { dir = "row", grow = 1 })
  else
    body = Layout.Box(owner.list, { grow = 1 })
  end
  owner.layout = Layout(
    { relative = "editor", position = "50%", size = { width = width, height = height } },
    Layout.Box({
      Layout.Box(owner.header, { size = 2 }),
      body,
      Layout.Box(owner.footer, { size = 1 }),
    }, { dir = "col" })
  )
  owner.layout:mount()
  set_mappings(owner.header, "header")
  set_mappings(owner.list, "list")
  set_mappings(owner.footer, "footer")
  if owner.detail then
    set_mappings(owner.detail, "detail")
  end
  vim.api.nvim_set_current_win(owner.list.winid)
end

local function create_sidebar(owner)
  local cfg = config.get().ui.sidebar
  owner.split = Split({
    relative = "editor",
    position = cfg.side,
    size = math.max(20, math.min(cfg.width, vim.o.columns - 2)),
    enter = true,
    buf_options = { buftype = "nofile", bufhidden = "wipe", swapfile = false, modifiable = false },
    win_options = { wrap = false, number = false, relativenumber = false, winhighlight = "Normal:NormalFloat" },
  })
  owner.split:mount()
  set_mappings(owner.split, "sidebar")
end

function M.open(opts)
  opts = opts or {}
  if owner_valid() then
    M.close()
  end
  highlights.setup()
  state.mode = opts.mode or config.get().ui.default_mode
  state.view = opts.view or config.get().ui.default_view
  state.filters = opts.filters or state.filters or {}
  state.selected_id = opts.selected_id or state.selected_id
  local owner = { closed = false, transient = nil, mode = state.mode }
  state.owner = owner
  if state.mode == "sidebar" then
    create_sidebar(owner)
  else
    create_float(owner)
  end
  render()
  owner.resize_group = vim.api.nvim_create_augroup("TodoDashboardResize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = owner.resize_group,
    callback = function()
      if owner_valid() then
        local reopen = {
          mode = state.mode,
          view = state.view,
          filters = vim.deepcopy(state.filters),
          selected_id = state.selected_id,
        }
        vim.schedule(function()
          M.open(reopen)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = owner.resize_group,
    callback = function()
      if owner.mode ~= "float" then
        return
      end
      vim.schedule(function()
        if owner.closed or state.owner ~= owner then
          return
        end
        if not todo_has_window(owner, vim.api.nvim_get_current_win()) then
          M.close()
        end
      end)
    end,
  })
end

function M.close()
  local owner = state.owner
  if not owner then
    return
  end
  owner.closed = true
  close_transient(owner)
  if owner.detail_overlay then
    pcall(function()
      owner.detail_overlay:unmount()
    end)
  end
  if owner.layout then
    pcall(function()
      owner.layout:unmount()
    end)
  end
  if owner.split then
    pcall(function()
      owner.split:unmount()
    end)
  end
  if owner.resize_group then
    pcall(vim.api.nvim_del_augroup_by_id, owner.resize_group)
  end
  state.owner = nil
end

function M.toggle(opts)
  if owner_valid() then
    M.close()
  else
    M.open(opts)
  end
end

function M.refresh()
  if owner_valid() then
    render()
  end
end

function M.current_task()
  return selected_task()
end

function M.add(opts)
  if not owner_valid() then
    return false
  end
  add_task(opts)
  return true
end

function M.edit(id)
  if not owner_valid() then
    return false
  end
  local task = id and service().store:get(id) or selected_task()
  if not task then
    error(i18n.t("task_not_found", id or "?"))
  end
  open_task_form(task, function(input)
    return service():update(task.id, input)
  end)
  return true
end

function M.is_open()
  return owner_valid()
end

function M.inspect_state()
  return state
end

return M
