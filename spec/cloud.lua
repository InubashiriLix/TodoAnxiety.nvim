local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local cfg = require("todo.config")
cfg.setup({ reminders = { enabled = false } })
local store = require("todo.store")
local workspace = require("todo.workspace")
local service = require("todo.service")
local cloud = require("todo.cloud")
local uv = vim.uv or vim.loop
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local server
local function check(v, message)
    assert(v, message)
end
local ok, err = xpcall(function()
    local bin = vim.env.TODO_SERVER_BIN or root .. "/server/target/debug/todoanxiety-sync"
    check(vim.fn.executable(bin) == 1, "build server before cloud test")
    local init = vim.system({ bin, "init", "--data-dir", dir .. "/remote" }, { text = true }):wait()
    check(init.code == 0, init.stderr)
    local token = vim.system({ bin, "token", "create", "test", "--data-dir", dir .. "/remote" }, { text = true }):wait()
    check(token.code == 0, token.stderr)
    vim.env.TODO_TEST_TOKEN = vim.trim(token.stdout)
    local tcp = uv.new_tcp()
    tcp:bind("127.0.0.1", 0)
    local port = tcp:getsockname().port
    tcp:close()
    server = vim.system(
        { bin, "serve", "--data-dir", dir .. "/remote", "--bind", "127.0.0.1:" .. port },
        { text = true }
    )
    vim.wait(200)
    local opts = vim.tbl_extend("force", cfg.get().sync, {
        provider = "server",
        enabled = true,
        allow_http = true,
        auto = false,
        url = "http://127.0.0.1:" .. port,
        token_env = "TODO_TEST_TOKEN",
    })
    local a, b = store.open(dir .. "/a.db"), store.open(dir .. "/b.db")
    local wa, wb = workspace.new(a), workspace.new(b)
    local sa, sb = service.new(a), service.new(b)
    local function sync(ws, allow_error)
        local done, failure = false, nil
        cloud.run(ws, opts, function(e)
            failure = e
            done = true
        end)
        check(
            vim.wait(10000, function()
                return done
            end, 10),
            "sync timed out"
        )
        if not allow_error then
            check(not failure, failure)
        end
        return failure
    end
    local task = assert(
        sa:create({
            title = "Shared task",
            description = "full description",
            deadline = "2030-01-01",
            reminder_interval = "5m",
        })
    )
    local plan = require("todo.planning").new(wa, sa)
    plan:add(task.sync_uuid)
    local image = dir .. "/source.png"
    local bytes = "\137PNG\r\n\26\n\0binary image"
    local fd = assert(uv.fs_open(image, "w", 384))
    uv.fs_write(fd, bytes, 0)
    uv.fs_close(fd)
    local asset = require("todo.assets").import(image, { store = a })
    uv.fs_unlink(image)
    check(require("todo.assets").read(asset.hash, a) == bytes, "asset must survive source deletion")
    wa:put(
        "note",
        "test-note",
        { task_uuid = task.sync_uuid, text = asset.markdown, source = "user", created_at = os.time() }
    )
    sync(wa)
    sync(wb)
    check(#sb:list("today") == 1, "today must sync")
    local remote = sb:list("today")[1]
    check(
        remote.sync_uuid == task.sync_uuid and remote.description == "full description",
        "task IDs and description must sync"
    )
    check(wb:get("note", "test-note").text == asset.markdown, "notes must sync")
    local done, fail = false, nil
    cloud.fetch_asset(asset.hash, b, opts, function(e)
        fail = e
        done = true
    end)
    check(
        vim.wait(10000, function()
            return done
        end, 10),
        "image download timed out"
    )
    check(not fail, fail)
    check(require("todo.assets").read(asset.hash, b) == bytes, "downloaded image differs")
    sa:set_status(task.id, "in_progress")
    sb:set_status(remote.id, "done")
    sync(wa)
    check(sync(wb, true), "concurrent edits must conflict")
    check(b:get(remote.id).status == "done", "dirty local task overwritten")
    wb:resolve("task", task.sync_uuid, "remote")
    sync(wb)
    check(b:get(remote.id).status == "in_progress", "remote resolution failed")
    local op = wa:export_pending()
    if op then
        sync(wa)
    end
    sa:set_status(task.id, "cancelled")
    sb:set_status(remote.id, "todo")
    sync(wa)
    check(sync(wb, true), "second conflict expected")
    wb:resolve("task", task.sync_uuid, "local")
    sync(wb)
    sync(wa)
    check(a:get(task.id).status == "todo", "local resolution failed to reach other device")
    local lease, leaseerr
    done = false
    cloud.acquire_lease("test-session", "device-a", opts, function(e, r)
        leaseerr = e
        lease = r
        done = true
    end)
    check(vim.wait(5000, function()
        return done
    end, 10) and not leaseerr, leaseerr)
    done = false
    cloud.release_lease("test-session", "device-a", lease.token, opts, function(e)
        leaseerr = e
        done = true
    end)
    check(vim.wait(5000, function()
        return done
    end, 10) and not leaseerr, "204 lease release must succeed")
    -- Lost acknowledgements must not turn a later local edit into a conflict.
    wa:put("note", "replay", { text = "before", nullable = vim.NIL })
    local frozen = assert(wa:export_pending())
    assert(
        require("todo.sync.codec").encode(frozen) == require("todo.sync.codec").encode(wa:export_pending()),
        "retry body changed"
    )
    done = false
    local pusherr
    cloud.request(opts, "POST", "/v1/push", frozen, function(e)
        pusherr = e
        done = true
    end)
    check(vim.wait(5000, function()
        return done
    end, 10) and not pusherr, pusherr)
    wa:put("note", "replay", { text = "after", nullable = vim.NIL })
    sync(wa)
    sync(wb)
    check(wb:get("note", "replay").text == "after", "lost ack overwrote later edit")
    check(wb:get("note", "replay").nullable == vim.NIL, "JSON null changed in transit")
    wa:put("note", "replay", nil)
    local deletion = assert(wa:export_pending())
    check(
        require("todo.sync.codec").encode(deletion) == require("todo.sync.codec").encode(wa:export_pending()),
        "tombstone retry changed"
    )
    sync(wa)
    sync(wb)
    check(wb:get("note", "replay") == nil, "tombstone failed")
    a:close()
    b:close()
    print("ok - two-device task/plan/image sync, conflict resolution and lease release")
end, debug.traceback)
if server then
    server:kill(15)
    server:wait(1000)
end
vim.fn.delete(dir, "rf")
if not ok then
    print(err)
    vim.cmd("cquit 1")
end
vim.cmd("qa!")
