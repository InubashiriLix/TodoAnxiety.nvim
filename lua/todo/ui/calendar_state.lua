local M = {}
M.__index = M

local function at_noon(year, month, day)
    return os.time({ year = year, month = month, day = day, hour = 12, min = 0, sec = 0 })
end

local function days_in_month(year, month)
    return tonumber(os.date("%d", at_noon(year, month + 1, 0)))
end

function M.new(value, now)
    local year, month, day, time = tostring(value or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)%s*(%d?%d?:?%d?%d?)$")
    local today = os.date("*t", now or os.time())
    return setmetatable({
        year = tonumber(year) or today.year,
        month = tonumber(month) or today.month,
        day = tonumber(day) or today.day,
        time = time ~= "" and time or nil,
        today = { year = today.year, month = today.month, day = today.day },
    }, M)
end

function M:days_in_month()
    return days_in_month(self.year, self.month)
end

function M:shift_month(delta)
    local shifted = os.date("*t", at_noon(self.year, self.month + delta, 1))
    self.year, self.month = shifted.year, shifted.month
    self.day = math.min(self.day, self:days_in_month())
    return self
end

function M:move_days(delta)
    local shifted = os.date("*t", at_noon(self.year, self.month, self.day + delta))
    self.year, self.month, self.day = shifted.year, shifted.month, shifted.day
    return self
end

function M:set_today()
    self.year, self.month, self.day = self.today.year, self.today.month, self.today.day
    return self
end

function M:set_day(day)
    day = tonumber(day)
    assert(day and day >= 1 and day <= self:days_in_month(), "invalid calendar day")
    self.day = day
    return self
end

function M:set_time(value)
    self.time = value ~= "" and value or nil
    return self
end

function M:value()
    local date = string.format("%04d-%02d-%02d", self.year, self.month, self.day)
    return self.time and (date .. " " .. self.time) or date
end

function M:shifted_date(delta)
    local shifted = os.date("*t", at_noon(self.year, self.month, self.day + (delta or 0)))
    return string.format("%04d-%02d-%02d", shifted.year, shifted.month, shifted.day)
end

function M:cells()
    local first = os.date("*t", at_noon(self.year, self.month, 1))
    local monday_offset = (first.wday + 5) % 7
    local cells = {}
    for index = 1, 42 do
        local day = index - monday_offset
        cells[index] = day >= 1 and day <= self:days_in_month() and day or false
    end
    return cells
end

return M
