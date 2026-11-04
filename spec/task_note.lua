local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("todo.config").setup({ language = "en", reminders = { enabled = false } })

local store = require("todo.store").open(vim.fn.tempname() .. ".db")
local ws = require("todo.workspace").new(store)
local svc = require("todo.service").new(store)
local task = assert(svc:create({ title = "Notes", description = "Description" }))
local note = require("todo.ui.task_note")

ws:put("note", "ai-note", {
    task_uuid = task.sync_uuid,
    text = "confirm tablet get method and task details",
    source = "ai",
    created_at = 1,
})

local records = note.records(task, { service = svc, workspace = ws })
assert(#records == 1 and records[1].value.source == "ai", "AI notes must be listed")
assert(#note.records({}, { service = svc, workspace = ws }) == 0, "unsaved tasks have no notes")

local original_select = vim.ui.select
local function choose(index)
    vim.ui.select = function(items, _, callback)
        assert(items[index], "missing note choice")
        callback(items[index])
    end
end

choose(2)
local edited
note.edit(task, {
    service = svc,
    workspace = ws,
    records = records,
    editor = function(_, text, on_save)
        assert(text == "confirm tablet get method and task details", "existing text must load into the editor")
        assert(on_save("confirm tablet get method and task details — revised"))
        edited = true
    end,
})
assert(edited, "the shared note editor must be used")
local saved = ws:get("note", "ai-note")
assert(saved.text:find("revised", 1, true), "editing must update the AI note")
assert(saved.source == "ai", "editing must preserve where the note came from")

-- Clearing an existing note removes the record; a new blank note is a no-op.
choose(2)
note.edit(task, {
    service = svc,
    workspace = ws,
    records = note.records(task, { service = svc, workspace = ws }),
    editor = function(_, _, on_save)
        assert(on_save(""))
    end,
})
assert(ws:get("note", "ai-note") == nil, "empty existing notes must be removed")

choose(1)
local created
note.edit(task, {
    service = svc,
    workspace = ws,
    records = note.records(task, { service = svc, workspace = ws }),
    editor = function(_, text, on_save)
        assert(text == "", "new notes start empty")
        assert(on_save("A note written by the user"))
        created = true
    end,
})
assert(created)
local all = note.records(task, { service = svc, workspace = ws })
assert(#all == 1 and all[1].value.source == "user", "new notes are user-authored")

vim.ui.select = original_select
store:close()
print("ok - AI notes are listed, edited in place, preserved by source, and cleared notes are removed")
