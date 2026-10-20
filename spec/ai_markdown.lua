package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local markdown = require("todo.ai.markdown")

local function codes(text, kind)
    local out = {}
    for _, issue in ipairs(markdown.check(text, kind)) do
        out[issue.code] = true
    end
    return out
end

local clean = [[## Goal

- Finish the API
- Write the report

```lua
print("ok")
```
]]
assert(#markdown.check(clean, "description") == 0, "well-formed Markdown must pass")

local wrapped = codes("```markdown\n# description:\n- Goal\n```", "description")
assert(wrapped.wrapped, "outer code fence must be reported")
assert(wrapped.meta, "description label inside a fence must be reported")

local meta = codes("# description:\n- Goal", "description")
assert(meta.meta and meta.h1, "meta label and H1 must be reported")

local plain_meta = codes("Description: - Goal", "description")
assert(plain_meta.meta, "plain description labels must be reported")

local fence = codes("```lua\nprint(1)", "description")
assert(fence.fence, "unclosed fence must be reported")

local heading = codes("## Goal\nText", "description")
assert(heading.heading_space, "heading without a leading blank line must be reported")

local list = codes("Text\n- item", "description")
assert(list.list_space, "list without a leading blank line must be reported")

local note = codes("# Heading\nSomething", "note")
assert(note.note_heading, "notes starting with a heading must be reported")

local html = codes("## Goal\n<span>text</span>", "description")
assert(html.html, "HTML tags must be reported")

local code_html = codes("## Goal\n\n```html\n<div>ok</div>\n```", "description")
assert(not code_html.html, "HTML inside a code block is an example, not markup")

local h1 = codes("Body\n\n# Details", "description")
assert(h1.h1, "an H1 anywhere in a description must be reported")

local heading_text = codes("## Description of the API\n\nText", "description")
assert(not heading_text.meta, "a normal heading starting with 'Description' is not a meta label")

local control = codes("Goal\1bad", "description")
assert(control.control, "control characters must be reported")

local empty = codes("  \n\t", "description")
assert(empty.empty, "whitespace-only content must be reported as empty")

assert(#markdown.check("Short note", "note") == 0, "plain short notes must pass")
print("ok - AI Markdown warnings cover wrapping, labels, spacing, fences, HTML and control characters")
vim.cmd("qa!")
