local duration = require("todo.duration")

local M = {}
M.__index = M

local fields = { "days", "hours", "minutes", "seconds" }
local units = { days = 86400, hours = 3600, minutes = 60, seconds = 1 }

local function set_total(self, total)
    total = math.max(0, math.floor(total))
    self.days = math.floor(total / 86400)
    total = total % 86400
    self.hours = math.floor(total / 3600)
    total = total % 3600
    self.minutes = math.floor(total / 60)
    self.seconds = total % 60
end

function M.new(value)
    local self = setmetatable({ field_index = 1, digits = "" }, M)
    set_total(self, duration.parse(value) or 300)
    return self
end

function M:field()
    return fields[self.field_index]
end

function M:switch(delta)
    self.field_index = (self.field_index - 1 + delta) % #fields + 1
    self.digits = ""
    return self
end

function M:value()
    return self.days * 86400 + self.hours * 3600 + self.minutes * 60 + self.seconds
end

function M:formatted()
    return duration.format(self:value())
end

function M:move(delta)
    set_total(self, self:value() + delta * units[self:field()])
    self.digits = ""
    return self
end

local function set_field(self, value)
    local field = self:field()
    set_total(self, self:value() - self[field] * units[field] + value * units[field])
end

function M:input_digit(digit)
    digit = tostring(digit)
    assert(digit:match("^%d$"), "duration digit must be 0-9")
    self.digits = self.digits .. digit
    if #self.digits < 2 then
        return nil
    end
    set_field(self, tonumber(self.digits))
    self.digits = ""
    self:switch(1)
    return true
end

function M:commit_digits()
    if self.digits ~= "" then
        set_field(self, tonumber(self.digits))
        self.digits = ""
    end
    return self:value() > 0
end

function M:display(field)
    if self:field() == field and #self.digits == 1 then
        return self.digits .. "_"
    end
    if field == "days" then
        return string.format("%02d", self.days)
    end
    return string.format("%02d", self[field])
end

return M
