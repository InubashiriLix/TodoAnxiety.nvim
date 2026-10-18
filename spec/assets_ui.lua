package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
require("todo.config").setup({ reminders = { enabled = false } })
local assets = require("todo.assets")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local store = { path = dir .. "/tasks.db" }
local original = package.loaded.image
local ok, err = xpcall(function()
    local source = dir .. "/source.png"
    local png = vim.base64.decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
    )
    vim.fn.writefile(png, source, "b")
    local attachment = assets.import(source, { store = store })
    vim.fn.delete(source)
    assert(assets.resolve(attachment.hash, store), "managed image must survive deletion of source")
    local renders, clears, options = 0, 0, nil
    package.loaded.image = {
        from_file = function(path, opts)
            assert(path == attachment.path)
            options = opts
            return {
                render = function()
                    renders = renders + 1
                end,
                clear = function()
                    clears = clears + 1
                end,
            }
        end,
    }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Note", attachment.markdown })
    assets.attach(buf, store)
    assert(vim.wait(1000, function()
        return renders == 1
    end))
    assert(options.buffer == buf and options.window == vim.api.nvim_get_current_win() and options.y == 1)
    assert(options.with_virtual_padding, "images must reserve space")
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "Only the prose changed" })
    vim.wait(150)
    assert(renders == 1 and clears == 0, "unchanged image references must retain the rendered image")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Revised note" })
    assert(
        vim.wait(1000, function()
            return clears == 1
        end),
        "API-driven updates must clear removed images"
    )
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "![AI attachment](todo-asset://" .. attachment.hash .. ")" })
    assert(vim.wait(1000, function()
        return renders == 2
    end))
    vim.cmd("enew")
    assert(clears == 2, "leaving the window must clear image rendering")
    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded.image = {
        from_file = function()
            error("test unsupported backend")
        end,
    }
    local fallback = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, fallback)
    vim.api.nvim_buf_set_lines(fallback, 0, -1, false, { attachment.markdown })
    assets.attach(fallback, store)
    vim.wait(150)
    assert(vim.api.nvim_buf_get_lines(fallback, 0, -1, false)[1] == attachment.markdown)
    assert(vim.fn.maparg("gx", "n") ~= "", "viewer fallback must remain available")
    vim.api.nvim_buf_delete(fallback, { force = true })
end, debug.traceback)
package.loaded.image = original
vim.fn.delete(dir, "rf")
if not ok then
    print(err)
    vim.cmd("cquit 1")
end
print("ok - inline image API, managed files, buffer updates, lifecycle and fallback")
vim.cmd("qa!")
