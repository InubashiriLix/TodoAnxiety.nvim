-- A native, non-focusable card: visible even when vim.notify INFO is filtered.
local i18n = require("todo.i18n")
local uv = vim.uv or vim.loop
local M = {}
local current
local phases = { prepare = 1, download = 2, merge = 3, apply = 4, upload = 5 }
local frames = { "|", "/", "-", "\\" }

local function history(message, error_level)
    vim.api.nvim_echo({ { message, error_level and "ErrorMsg" or "Normal" } }, true, {})
end

local function wrap(text, width)
    local result, line = {}, ""
    for i = 0, vim.fn.strchars(text) - 1 do
        local char = vim.fn.strcharpart(text, i, 1)
        if vim.fn.strdisplaywidth(line .. char) > width and line ~= "" then
            result[#result + 1], line = line, ""
        end
        line = line .. char
    end
    result[#result + 1] = line
    return result
end

function M.start()
    if current then
        current:close()
    end
    local self = { running = true, started = uv.hrtime(), phase = "prepare", attempt = 1 }
    current = self
    self.timer = uv.new_timer()
    self.group = vim.api.nvim_create_augroup("TodoSyncProgress", { clear = true })

    function self:elapsed()
        return math.floor((uv.hrtime() - self.started) / 1000000000)
    end

    function self:close()
        if self.closed then
            return
        end
        self.closed = true
        self.timer:stop()
        if not self.timer:is_closing() then
            self.timer:close()
        end
        if self.win and vim.api.nvim_win_is_valid(self.win) then
            vim.api.nvim_win_close(self.win, true)
        end
        if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
            vim.api.nvim_buf_delete(self.buf, { force = true })
        end
        pcall(vim.api.nvim_del_augroup_by_id, self.group)
        if current == self then
            current = nil
        end
    end

    function self:render()
        if self.closed then
            return
        end
        local lines = self.lines
        if self.running then
            local frame = frames[math.floor((uv.hrtime() - self.started) / 250000000) % #frames + 1]
            lines = {
                string.format("%s [%d/5] %s", frame, phases[self.phase], i18n.t("sync_phase_" .. self.phase)),
                self.attempt > 1 and i18n.t("sync_retry", self.attempt) or "",
                i18n.t("sync_elapsed", self:elapsed()),
                i18n.t("sync_working_hint"),
            }
        end
        local width = math.max(1, math.min(62, vim.o.columns - 6))
        local displayed = {}
        for _, line in ipairs(lines) do
            vim.list_extend(displayed, wrap(line, width))
        end
        local max_height = math.max(1, vim.o.lines - vim.o.cmdheight - 6)
        if #displayed > max_height then
            displayed = vim.list_slice(displayed, 1, max_height)
            displayed[#displayed] = "…"
        end
        if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
            self.buf = vim.api.nvim_create_buf(false, true)
            vim.bo[self.buf].bufhidden = "wipe"
            vim.bo[self.buf].filetype = "todo-sync"
        end
        vim.bo[self.buf].modifiable = true
        vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, displayed)
        vim.bo[self.buf].modifiable = false
        local opts = {
            relative = "editor",
            anchor = "SE",
            row = math.max(1, vim.o.lines - vim.o.cmdheight - 2),
            col = math.max(1, vim.o.columns - 2),
            width = width,
            height = #displayed,
            style = "minimal",
            border = "rounded",
            focusable = false,
            zindex = 150,
            title = " " .. i18n.t("sync_feedback_title") .. " ",
            title_pos = "left",
        }
        if self.win and vim.api.nvim_win_is_valid(self.win) then
            vim.api.nvim_win_set_config(self.win, opts)
        else
            opts.noautocmd = true
            self.win = vim.api.nvim_open_win(self.buf, false, opts)
        end
        local color = self.failed and "DiagnosticError" or (self.running and "DiagnosticInfo" or "DiagnosticOk")
        vim.wo[self.win].winhighlight = "Normal:NormalFloat,FloatBorder:" .. color
        vim.wo[self.win].wrap = false
        vim.wo[self.win].winblend = 0
    end

    function self:update(event)
        if not self.running or self.closed then
            return
        end
        assert(phases[event.phase], "unknown sync phase")
        self.phase, self.attempt = event.phase, event.attempt or 1
        self:render()
    end

    function self:finish(err, result)
        if not self.running or self.closed then
            return
        end
        self.running = false
        self.timer:stop()
        local elapsed = self:elapsed()
        local cancelled = result and result.cancelled
        self.failed = err ~= nil and not cancelled
        if err then
            self.lines = {
                i18n.t(cancelled and "sync_cancelled_title" or "sync_failed_title"),
                tostring(err):match("^[^\n]+") or tostring(err),
                i18n.t("sync_elapsed", elapsed),
                i18n.t("sync_details_hint"),
            }
            history(cancelled and i18n.t("sync_cancelled") or i18n.t("sync_failed", tostring(err)), not cancelled)
        else
            local uploaded, downloaded = result.uploaded or 0, result.downloaded or 0
            self.lines = {
                i18n.t("sync_done_title"),
                uploaded == 0 and downloaded == 0 and i18n.t("sync_no_changes")
                    or i18n.t("sync_transfers", uploaded, downloaded),
                i18n.t("sync_result_time", elapsed, result.pending),
                i18n.t(result.pending > 0 and "sync_pending_hint" or "sync_details_hint"),
            }
            history(table.concat(self.lines, "\n"))
        end
        self:render()
        self.timer:start(
            self.failed and 15000 or 8000,
            0,
            vim.schedule_wrap(function()
                self:close()
            end)
        )
    end

    vim.api.nvim_create_autocmd("VimResized", {
        group = self.group,
        callback = function()
            self:render()
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = self.group,
        callback = function()
            self:close()
        end,
    })
    self:render()
    self.timer:start(
        250,
        250,
        vim.schedule_wrap(function()
            self:render()
        end)
    )
    return self
end

function M.busy()
    if current then
        current:render()
    end
    history(i18n.t("sync_busy"))
end

function M.close()
    if current then
        current:close()
    end
end

function M.inspect_state()
    return current
end

return M
