-- Non-focusable asynchronous operation cards. Timers never perform network IO.
local M = {}
local uv = vim.uv or vim.loop
local active = {}
local serial = 0
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local function L(en, zh)
    return require("todo.config").get().language == "zh-CN" and zh or en
end
function M.start(title)
    for _, card in pairs(active) do
        if card.title == title then
            card:close()
        end
    end
    serial = serial + 1
    local self =
        { id = serial, title = title, started = uv.hrtime(), running = true, stage = L("Preparing", "准备中") }
    active[self.id] = self
    function self:close()
        if self.closed then
            return
        end
        self.closed = true
        active[self.id] = nil
        self.timer:stop()
        self.timer:close()
        if self.win and vim.api.nvim_win_is_valid(self.win) then
            pcall(vim.api.nvim_win_close, self.win, true)
        end
        if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
            pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
        end
    end
    function self:render()
        if self.closed then
            return
        end
        local elapsed = math.floor((uv.hrtime() - self.started) / 1e9)
        local icon = self.running and frames[math.floor((uv.hrtime() - self.started) / 1e8) % #frames + 1]
            or self.cancelled and "■"
            or self.failed and "!"
            or "✓"
        local width = math.max(1, math.min(62, vim.o.columns - 6))
        local suffix = self.total and string.format("  %d/%d", self.count or 0, self.total) or ""
        local lines = {
            icon .. " " .. self.stage .. suffix,
            L("Elapsed ", "耗时 ") .. elapsed .. L("s · editing stays responsive", " 秒 · 可继续编辑"),
        }
        if self.total and self.total > 0 then
            local n = math.max(0, math.min(20, math.floor((self.count or 0) / self.total * 20)))
            lines[#lines + 1] = "[" .. string.rep("━", n) .. string.rep("─", 20 - n) .. "]"
        end
        if self.error then
            lines[#lines + 1] = self.error:gsub("\n", " "):sub(1, 220)
        end
        if self.failed then
            lines[#lines + 1] = ":Todo diagnostics · :Todo sync status"
        end
        local display = {}
        for _, line in ipairs(lines) do
            while vim.fn.strdisplaywidth(line) > width do
                local count = 1
                while
                    count < vim.fn.strchars(line)
                    and vim.fn.strdisplaywidth(vim.fn.strcharpart(line, 0, count + 1)) <= width
                do
                    count = count + 1
                end
                display[#display + 1] = vim.fn.strcharpart(line, 0, count)
                line = vim.fn.strcharpart(line, count)
            end
            display[#display + 1] = line
        end
        local maxheight = math.max(1, vim.o.lines - vim.o.cmdheight - 6)
        while #display > maxheight do
            table.remove(display)
        end
        if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
            self.buf = vim.api.nvim_create_buf(false, true)
            vim.bo[self.buf].bufhidden = "wipe"
        end
        vim.bo[self.buf].modifiable = true
        vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, display)
        vim.bo[self.buf].modifiable = false
        local newer = 0
        for id, card in pairs(active) do
            if id > self.id and not card.closed then
                newer = newer + 1
            end
        end
        local row = math.max(#display + 2, vim.o.lines - vim.o.cmdheight - 2 - newer * 7)
        local opts = {
            relative = "editor",
            anchor = "SE",
            row = row,
            col = math.max(1, vim.o.columns - 2),
            width = width,
            height = #display,
            style = "minimal",
            border = "rounded",
            focusable = false,
            zindex = 180,
            title = " " .. self.title .. " ",
            title_pos = "left",
        }
        if self.win and vim.api.nvim_win_is_valid(self.win) then
            vim.api.nvim_win_set_config(self.win, opts)
        else
            opts.noautocmd = true
            self.win = vim.api.nvim_open_win(self.buf, false, opts)
        end
        vim.wo[self.win].winhighlight = "Normal:NormalFloat,FloatBorder:"
            .. (self.failed and "DiagnosticError" or self.running and "DiagnosticInfo" or "DiagnosticOk")
    end
    function self:update(stage, count, total)
        if self.closed or not self.running then
            return
        end
        self.stage = stage
        self.count = count
        self.total = total
        require("todo.diagnostics").record({
            id = tostring(self.id),
            operation = self.title,
            stage = stage,
            status = "running",
            count = count,
            total = total,
        })
        self:render()
    end
    function self:finish(err, detail)
        if self.closed or not self.running then
            return
        end
        self.running = false
        self.cancelled = err == "cancelled"
        self.failed = err ~= nil and not self.cancelled
        self.error = err and require("todo.diagnostics").redact(err) or nil
        self.stage = detail
            or (
                self.cancelled and L("Cancelled", "已取消")
                or err and L("Failed — local data retained", "失败，已保留本地数据")
                or L("Complete", "完成")
            )
        require("todo.diagnostics").record({
            id = tostring(self.id),
            operation = self.title,
            stage = self.stage,
            status = err and "failed" or "complete",
            error = self.error,
            elapsed_ms = math.floor((uv.hrtime() - self.started) / 1e6),
        })
        self:render()
        self.timer:start(
            err and 15000 or 4000,
            0,
            vim.schedule_wrap(function()
                self:close()
            end)
        )
        if err and not self.cancelled then
            vim.notify(self.error .. "\n:Todo diagnostics", vim.log.levels.WARN, { title = self.title })
        end
    end
    self.timer = uv.new_timer()
    self:render()
    self.timer:start(
        100,
        100,
        vim.schedule_wrap(function()
            self:render()
        end)
    )
    return self
end
function M.close()
    local cards = {}
    for _, c in pairs(active) do
        cards[#cards + 1] = c
    end
    for _, c in ipairs(cards) do
        c:close()
    end
end
function M.inspect_state()
    return active
end
local group = vim.api.nvim_create_augroup("TodoNetworkProgress", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close })
vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
        for _, c in pairs(active) do
            c:render()
        end
    end,
})
return M
