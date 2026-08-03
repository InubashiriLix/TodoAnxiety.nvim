local M = {}
M.__index = M

local function set_total(self, total)
    self.day_offset = math.floor(total / 1440)
    local clock = total % 1440
    self.hour = math.floor(clock / 60)
    self.minute = clock % 60
end

local function set_field(self, field, value)
    local total = self.day_offset * 1440
    if field == "hour" then
        total = total + value * 60 + self.minute
    else
        total = total + self.hour * 60 + value
    end
    set_total(self, total)
end

function M.new(value, now)
    local hour, minute = tostring(value or ""):match("(%d%d):(%d%d)$")
    local current = os.date("*t", now or os.time())
    return setmetatable({
        hour = tonumber(hour) or current.hour,
        minute = tonumber(minute) or current.min,
        day_offset = 0,
        field = "hour",
        digits = "",
    }, M)
end

function M:switch(delta)
    self.field = delta == 0 and self.field or (self.field == "hour" and "minute" or "hour")
    self.digits = ""
    return self
end

function M:move(delta)
    local step = self.field == "hour" and 60 or 1
    local total = self.day_offset * 1440 + self.hour * 60 + self.minute + delta * step
    set_total(self, total)
    self.digits = ""
    return self
end

function M:input_digit(digit)
    digit = tostring(digit)
    assert(digit:match("^%d$"), "time digit must be 0-9")
    self.digits = self.digits .. digit
    if #self.digits < 2 then
        return nil
    end
    local value = tonumber(self.digits)
    self.digits = ""
    set_field(self, self.field, value)
    if self.field == "hour" then
        self.field = "minute"
    end
    return true
end

function M:commit_digits()
    if self.digits == "" then
        return true
    end
    local value = tonumber(self.digits)
    self.digits = ""
    set_field(self, self.field, value)
    return true
end

function M:display(field)
    if self.field == field and #self.digits == 1 then
        return self.digits .. "_"
    end
    return string.format("%02d", self[field])
end

function M:value()
    return string.format("%02d:%02d", self.hour, self.minute)
end

return M
