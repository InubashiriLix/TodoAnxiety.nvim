local codec = require("todo.sync.codec")
local journal = require("todo.sync.store")
local uv = vim.uv or vim.loop
local M = {}
local manifest = codec.encode({ format = "todo.nvim", version = 1 }) .. "\n"

function M.directory(store)
    return vim.fn.fnamemodify(store.path, ":p") .. ".sync"
end

local function read(path)
    local stat = assert(uv.fs_lstat(path))
    assert(stat.type == "file", "sync path is not a regular file: " .. path)
    local fd = assert(uv.fs_open(path, "r", 384))
    local content, err = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    return assert(content, err)
end

local function write(repo, path, content)
    if uv.fs_lstat(path) then
        assert(read(path) == content, "immutable sync file changed: " .. path)
        return
    end
    local temporary = repo .. "/.git/todo-" .. codec.uuid() .. ".tmp"
    local fd = assert(uv.fs_open(temporary, "wx", 384))
    local ok, err = pcall(function()
        local offset = 0
        while offset < #content do
            local n = assert(uv.fs_write(fd, content:sub(offset + 1), offset))
            assert(n > 0, "could not write sync file")
            offset = offset + n
        end
        assert(uv.fs_fsync(fd))
    end)
    uv.fs_close(fd)
    if ok then
        ok, err = uv.fs_rename(temporary, path)
    end
    if not ok then
        uv.fs_unlink(temporary)
        error(err)
    end
end

local function event_path(path)
    return path:match("^events/([0-9a-f%-]+)%.json$")
end

local function local_payloads(repo)
    local payloads, ids = {}, {}
    local scan = assert(uv.fs_scandir(repo .. "/events"))
    while true do
        local file = uv.fs_scandir_next(scan)
        if not file then
            break
        end
        local id = assert(event_path("events/" .. file), "unexpected sync file: " .. file)
        local payload = read(repo .. "/events/" .. file)
        local event = codec.decode(payload)
        assert(event.id == id, "event filename and ID differ")
        payloads[#payloads + 1], ids[#ids + 1] = payload, id
    end
    return payloads, ids
end

function M.run(store, opts, callback)
    opts = vim.deepcopy(opts)
    assert(opts.enabled, require("todo.i18n").t("sync_disabled"))
    assert(vim.fn.executable("git") == 1, "Git is not installed")
    local token = journal.lock(store)
    local handle = { running = true }
    local downloaded, uploaded = 0, 0
    local repo = M.directory(store)
    local process, thread
    local function finish(err, result)
        if not handle.running then
            return
        end
        handle.running = false
        if err then
            pcall(store.set_setting, store, "sync_last_error", tostring(err))
        end
        pcall(journal.unlock, store, token)
        if callback then
            callback(err, result)
        end
    end
    function handle.cancel()
        if not handle.running then
            return
        end
        handle.cancelling = true
        if process then
            process:kill(15)
            process:wait(1000)
        end
        finish(require("todo.i18n").t("sync_cancelled"), { cancelled = true })
    end
    local function progress(phase, attempt)
        if opts.on_progress then
            -- Presentation failures must not interrupt database/Git work.
            pcall(opts.on_progress, { phase = phase, attempt = attempt or 1 })
        end
    end
    local function resume(result)
        if not handle.running or handle.cancelling then
            return
        end
        local ok, err = coroutine.resume(thread, result)
        if not ok then
            finish(err)
        end
    end
    local function git(args, allow_failure)
        local argv = {
            "git",
            "-c",
            "core.hooksPath=" .. repo .. "/.git/todo-no-hooks",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "merge.gpgsign=false",
            "-c",
            "core.autocrlf=false",
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "user.name=todo.nvim",
            "-c",
            "user.email=todo@localhost",
            "-c",
            "protocol.ext.allow=never",
            "-C",
            repo,
        }
        vim.list_extend(argv, args)
        process = vim.system(argv, {
            text = true,
            timeout = 30000,
            env = {
                GIT_TERMINAL_PROMPT = "0",
                GIT_SSH_COMMAND = "ssh -o BatchMode=yes -o ConnectTimeout=15",
                GIT_MERGE_AUTOEDIT = "no",
                GIT_EDITOR = "true",
                LC_ALL = "C",
            },
        }, function(result)
            vim.schedule(function()
                resume(result)
            end)
        end)
        local result = coroutine.yield()
        process = nil
        if result.code ~= 0 and not allow_failure then
            error(vim.trim(result.stderr or "") .. " (git " .. args[1] .. ", exit " .. result.code .. ")")
        end
        return result
    end
    local function validate_tree(ref)
        local tree = git({ "ls-tree", "-r", "-z", ref }).stdout
        local has_manifest = false
        for entry in tree:gmatch("([^%z]+)") do
            local mode, path = entry:match("^(%d+) blob %x+\t(.+)$")
            assert(
                mode == "100644" and (path == "format.json" or event_path(path)),
                "remote is not a todo.nvim sync repository"
            )
            if path == "format.json" then
                has_manifest = true
            end
        end
        assert(has_manifest, "missing sync format.json")
        assert(git({ "show", ref .. ":format.json" }).stdout == manifest, "unsupported sync repository format")
    end
    thread = coroutine.create(function()
        progress("prepare")
        local previous = store:get_setting("sync_remote")
        assert(
            not previous or previous == opts.remote .. "\n" .. opts.branch,
            "sync remote/branch changed; use a separate db_path for a different sync repository"
        )
        vim.fn.mkdir(repo, "p")
        if not uv.fs_lstat(repo .. "/.git") then
            local scan = assert(uv.fs_scandir(repo))
            assert(not uv.fs_scandir_next(scan), "sync directory is not empty")
            git({ "init", "-b", opts.branch })
        end
        assert(uv.fs_lstat(repo .. "/.git").type == "directory", "invalid sync repository")
        local branch = vim.trim(git({ "symbolic-ref", "--short", "HEAD" }).stdout)
        assert(branch == opts.branch, "unexpected local sync branch")
        store:set_setting("sync_remote", opts.remote .. "\n" .. opts.branch)
        local remote = git({ "remote", "get-url", "origin" }, true)
        if remote.code ~= 0 then
            git({ "remote", "add", "origin", opts.remote })
        else
            assert(vim.trim(remote.stdout) == opts.remote, "unexpected sync remote URL")
        end
        vim.fn.mkdir(repo .. "/events", "p")
        write(repo, repo .. "/format.json", manifest)
        -- Export all history so deleting the local Git cache is recoverable.
        for _, event in ipairs(journal.events(store)) do
            write(repo, repo .. "/events/" .. event.id .. ".json", event.payload .. "\n")
            if tonumber(event.published) == 0 then
                uploaded = uploaded + 1
            end
        end
        local_payloads(repo)
        git({ "add", "--force", "--", "format.json", "events" })
        local staged = git({ "diff", "--cached", "--quiet" }, true)
        assert(staged.code == 0 or staged.code == 1, "could not inspect staged sync records")
        if staged.code == 1 then
            git({ "commit", "-m", "Sync todo records" })
        end
        validate_tree("HEAD")
        for attempt = 1, 3 do
            progress("download", attempt)
            local remote_head = git({ "ls-remote", "--heads", "origin", "refs/heads/" .. opts.branch }).stdout
            if vim.trim(remote_head) ~= "" then
                git({
                    "fetch",
                    "--no-tags",
                    "origin",
                    "refs/heads/" .. opts.branch .. ":refs/remotes/origin/" .. opts.branch,
                })
                local ref = "refs/remotes/origin/" .. opts.branch
                validate_tree(ref)
                progress("merge", attempt)
                local merged = git({ "merge", "--no-edit", "--no-verify", "--allow-unrelated-histories", ref }, true)
                if merged.code ~= 0 then
                    git({ "merge", "--abort" }, true)
                    error("could not merge immutable sync records: " .. merged.stderr .. merged.stdout)
                end
            end
            progress("apply", attempt)
            local payloads, ids = local_payloads(repo)
            downloaded = downloaded + journal.import(store, payloads)
            if opts.on_import then
                opts.on_import()
            end
            progress("upload", attempt)
            local pushed = git({ "push", "--porcelain", "origin", "HEAD:refs/heads/" .. opts.branch }, true)
            if pushed.code == 0 then
                journal.published(store, ids)
                finish(nil, {
                    records = #ids,
                    pending = journal.status(store).pending,
                    uploaded = uploaded,
                    downloaded = downloaded,
                })
                return
            end
            local output = pushed.stdout .. pushed.stderr
            local raced = output:find("[rejected]", 1, true) or output:find("cannot lock ref", 1, true)
            if not raced or attempt == 3 then
                error("git push failed: " .. output)
            end
        end
    end)
    vim.schedule(function()
        resume()
    end)
    return handle
end

return M
