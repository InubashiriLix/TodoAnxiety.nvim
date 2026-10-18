-- sqlite.lua treats strings matching function-call syntax as SQL expressions in
-- table bindings. Bind these values by index so Markdown images stay literal.
local M = {}
function M.literal_bindings(db)
    local original = db.eval
    db.eval = function(self, sql, params)
        local function affected(values)
            for _, value in pairs(values) do
                if type(value) == "string" and value:match("^[%S]+%(.*%)$") then
                    return true
                end
                if type(value) == "table" and affected(value) then
                    return true
                end
            end
            return false
        end
        if type(params) ~= "table" or not affected(params) then
            return original(self, sql, params)
        end
        local defs = require("sqlite.defs")
        local statement = require("sqlite.stmt"):parse(self.conn, sql)
        local rows = {}
        local ok, err = pcall(function()
            for _, values in ipairs(type(params[1]) == "table" and params or { params }) do
                local unnamed = 0
                for index = 1, statement:nparam() do
                    local name = statement:param(index)
                    local value
                    if name == "?" then
                        unnamed = unnamed + 1
                        value = values[unnamed]
                    else
                        value = values[name:sub(2)]
                    end
                    if value ~= nil then
                        assert(statement:bind(index, value) == defs.flags.ok, "SQLite literal binding failed")
                    end
                end
                while true do
                    local code = statement:step()
                    if code == defs.flags.done then
                        break
                    end
                    assert(code == defs.flags.row, "SQLite statement failed: " .. defs.last_errmsg(self.conn))
                    rows[#rows + 1] = statement:kv()
                end
                statement:reset()
                statement:bind_clear()
            end
        end)
        local finalized, finalize_error = pcall(statement.finalize, statement)
        if not ok then
            error(err, 0)
        end
        assert(finalized, finalize_error)
        self.modified = true
        return #rows > 0 and rows or true
    end
end
return M
