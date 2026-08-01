local M = {}
M.__index = M

function M.new(value, now)
  local hour, minute = tostring(value or ""):match("(%d%d):(%d%d)$")
  local current = os.date("*t", now or os.time())
  return setmetatable({
    hour = tonumber(hour) or current.hour,
    minute = tonumber(minute) or current.min,
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
  local limit = self.field == "hour" and 24 or 60
  self[self.field] = (self[self.field] + delta) % limit
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
  local limit = self.field == "hour" and 23 or 59
  self.digits = ""
  if value > limit then
    return false
  end
  self[self.field] = value
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
  local limit = self.field == "hour" and 23 or 59
  self.digits = ""
  if value > limit then
    return false
  end
  self[self.field] = value
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
