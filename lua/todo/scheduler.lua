local M = {}
M.__index = M

local function default_timer()
    return (vim.uv or vim.loop).new_timer()
end

function M.new(service, opts)
    opts = opts or {}
    return setmetatable({
        service = service,
        now = opts.now or os.time,
        timer = opts.timer or default_timer(),
        presenter = opts.presenter or function(task, callback)
            require("todo.ui.reminder_popup").show(task, callback)
        end,
        dismiss = opts.dismiss or function()
            require("todo.ui.reminder_popup").close()
        end,
        play_sound = opts.play_sound or function()
            require("todo.sound").play(require("todo.config").get().reminders.sound)
        end,
        queue = {},
        pending_ids = {},
        presenting = false,
        running = false,
    }, M)
end

function M:_drain()
    if self.presenting or #self.queue == 0 then
        return
    end
    local task = table.remove(self.queue, 1)
    self.presenting = true
    self.active_task = task
    self.play_sound(task)
    self.presenter(task, function(action, value)
        if self.service.store and self.service.store.get and task.sync_revision then
            local current = self.service.store:get(task.id)
            if not current or current.sync_revision ~= task.sync_revision then
                action = "dismiss"
            end
        end
        if action == "complete" then
            self.service:complete_reminder(task.id, self.now())
        elseif action == "archive" then
            self.service:archive(task.id)
        elseif action == "snooze" then
            self.service:snooze(task.id, value, self.now())
        end
        pcall(function()
            require("todo.ui.panel").refresh()
        end)
        self.pending_ids[task.id] = nil
        self.presenting = false
        self.active_task = nil
        self:reschedule()
        self:_drain()
    end)
end

function M:reconcile()
    local function valid(task)
        local current = self.service.store:get(task.id)
        return current
            and current.sync_revision == task.sync_revision
            and not current.archived_at
            and current.reminder
            and current.reminder.enabled
            and (current.status == "todo" or current.status == "in_progress")
    end
    self.queue = vim.tbl_filter(function(task)
        if valid(task) then
            return true
        end
        self.pending_ids[task.id] = nil
        return false
    end, self.queue)
    if self.active_task and not valid(self.active_task) then
        self.dismiss()
    end
    if self.running then
        self:tick()
    end
end

function M:tick()
    if not self.running then
        return
    end
    local now = self.now()
    for _, task in ipairs(self.service:due_reminders(now)) do
        if not self.pending_ids[task.id] then
            local marked = self.service:mark_reminded(task.id, now)
            if marked then
                self.pending_ids[task.id] = true
                self.queue[#self.queue + 1] = marked
            end
        end
    end
    self:reschedule()
    self:_drain()
end

function M:reschedule()
    if not self.running then
        return
    end
    self.timer:stop()
    local next_at = self.service:next_reminder_time()
    if not next_at then
        return
    end
    local seconds = next_at - self.now()
    local delay = seconds <= 0 and next(self.pending_ids) and 30000
        or math.max(10, math.min(2147483647, seconds * 1000))
    self.timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            self:tick()
        end)
    )
end

function M:start()
    if self.running then
        self:reschedule()
        return
    end
    self.running = true
    self:tick()
end

function M:stop()
    self.running = false
    self.queue = {}
    if self.active_task then
        self.dismiss()
    end
    self.pending_ids = {}
    self.timer:stop()
    if not self.timer:is_closing() then
        self.timer:close()
    end
end

return M
