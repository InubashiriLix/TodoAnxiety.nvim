local M = {}

local defaults = {
    db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
    language = "en",
    core = { bin = "" }, -- Required Rust core binary; empty finds core/target or $TODO_CORE_BIN.
    ai = {
        enabled = false,
        provider = "deepseek",
        capabilities = {},
        max_tokens_field = "max_tokens",
        base_url = "https://api.deepseek.com",
        model = "deepseek-flash",
        api_key_env = "DEEPSEEK_API_KEY",
        api_key = false, -- String or function returning a key; takes precedence.
        api_key_file = "", -- Raw key file, not the JSON UI credential store.
        preferences_source = "workspace", -- "config" makes Lua language/persona authoritative.
        text_only = false,
        extended = false,
        mode = "plan",
        permissions = {
            roots = {}, -- Explicit consent to read these directories and send excerpts to AI.
            domains = {}, -- Exact HTTPS hosts; redirects and private addresses are rejected.
            rules = { read_file = "allow", search_files = "allow", fetch_url = "ask", run_command = "ask" },
            auto_apply_documents = true,
            max_calls_per_item = 6,
            max_output_bytes = 12000,
            timeout_ms = 15000,
            snapshot_max_files = 500,
            snapshot_max_bytes = 2097152,
            max_processes = 64,
            memory_mb = 256,
            cpu_seconds = 5,
            scratch_mb = 16,
        },
        language = "auto",
        persona = "A practical, patient planning assistant. Ask only necessary questions, then propose an executable plan.",
        planning = {
            max_rounds_per_item = 10,
            questions_per_round = 4,
            max_requests_per_item = 16,
            max_requests_total = false,
            stream = true,
            image_paste_key = "<localleader>p",
        },
        max_questions = 10, -- Legacy alias for max_rounds.
        max_rounds = 10,
        max_questions_per_round = 8,
        context_tokens = 16000,
        memory = { enabled = true, search_limit = 8, context_tokens = 2000, recent_turns = 4 },
        max_requests = 20,
        max_output_tokens = 4096,
        max_input_bytes = 524288,
        timeout_ms = 90000,
        session_budget_usd = false,
        daily_budget_usd = false,
        pricing = { version = "2026-10-15", cache_hit = 0.006, cache_miss = 0.30, output = 1.20 },
    },
    planning = { capacity_minutes = 480, reserve_minutes = 60, reserve_ratio = 0.125, timezone_offset_minutes = false },
    attachments = { directory = "", max_bytes = 10485760, clipboard_command = false, viewer = false, inline = true },
    -- Configure in require("todo").setup({ sync = { ... } }) on each device.
    -- Use a dedicated private, empty Git repository and existing Git credentials.
    -- Run :Todo sync manually; :Todo sync status only checks local state.
    sync = {
        provider = "git",
        url = "",
        token_env = "TODO_SYNC_TOKEN",
        token = false, -- String or function returning a token.
        token_file = "",
        allow_http = false,
        tls_verify = true,
        ca_file = "",
        auto = false, -- Explicit opt-in: upload local edits quietly.
        interval_seconds = 0, -- Optional remote polling; zero disables it.
        debounce_ms = 2000,
        enabled = false, -- Set true after filling in remote on every device.
        remote = "", -- e.g. "git@github.com:YOUR_NAME/private-todos.git"
        branch = "main", -- Use the same remote and branch on all devices.
    },
    ui = {
        performance = false, -- Bounded, local timings in :Todo diagnostics.
        daily_keys = {}, -- Action-name overrides; false disables a local mapping.
        default_mode = "float",
        default_view = "active",
        markdown = true,
        float = { width = 0.80, height = 0.75, border = "rounded" },
        sidebar = { width = 42, side = "right" },
    },
    keymaps = {
        toggle = "<leader>Tt",
        add = "<leader>Ta",
        open_float = "<leader>Tf",
        open_sidebar = "<leader>Ts",
        open_emergency = "<leader>Te",
        manage_tags = "<leader>Tg",
        add_notice = "<leader>Tn",
    },
    icons = {
        toggle = { icon = "\u{f204}", color = "yellow" },
        add = { icon = "\u{f067}", color = "green" },
        open_float = { icon = "\u{eb7f}", color = "blue" },
        open_sidebar = { icon = "\u{f03c7}", color = "cyan" },
        open_emergency = { icon = "\u{f071}", color = "orange" },
        manage_tags = { icon = "\u{f02c}", color = "purple" },
        add_notice = { icon = "\u{f0f3}", color = "orange" },
    },
    reminders = {
        enabled = true,
        sound = { path = "", command = false },
    },
}

local current = vim.deepcopy(defaults)

local function local_ai_path()
    return vim.fn.stdpath("data") .. "/todo.nvim/ai.json"
end

function M.local_ai()
    if vim.env.TODO_DISABLE_LOCAL_AI == "1" then
        return {}
    end
    local path = local_ai_path()
    local stat = (vim.uv or vim.loop).fs_stat(path)
    if not stat or stat.type ~= "file" or stat.size > 65536 then
        return {}
    end
    local ok, value = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    return ok and type(value) == "table" and value or {}
end

function M.set_local_ai(values)
    local uv = vim.uv or vim.loop
    local saved = M.local_ai()
    for key, value in pairs(values or {}) do
        saved[key] = value
        current.ai[key] = value
    end
    local dir = vim.fs.dirname(local_ai_path())
    vim.fn.mkdir(dir, "p", 448)
    local tmp = local_ai_path() .. ".tmp"
    local fd = assert(uv.fs_open(tmp, "w", 384), "cannot save AI settings")
    assert(uv.fs_write(fd, vim.json.encode(saved), 0))
    uv.fs_close(fd)
    assert(uv.fs_rename(tmp, local_ai_path()))
    pcall(uv.fs_chmod, local_ai_path(), 384)
    return saved
end

local function validate(opts)
    assert(type(opts.sync) == "table" and type(opts.sync.enabled) == "boolean", "sync.enabled must be a boolean")
    local function credential(value, file, env, label)
        assert(
            value == false or type(value) == "string" or type(value) == "function",
            label .. " must be false, a string or function"
        )
        assert(
            type(file) == "string" and type(env) == "string" and env ~= "",
            "invalid credential file/environment configuration"
        )
        if type(value) == "string" then
            assert(#value > 0 and #value <= 8192 and not value:find("[%c]"), "invalid configured credential")
        end
    end
    credential(opts.ai.api_key, opts.ai.api_key_file, opts.ai.api_key_env, "ai.api_key")
    credential(opts.sync.token, opts.sync.token_file, opts.sync.token_env, "sync.token")
    assert(
        opts.ai.preferences_source == "workspace" or opts.ai.preferences_source == "config",
        "invalid ai.preferences_source"
    )
    assert(type(opts.ai.text_only) == "boolean" and type(opts.ai.extended) == "boolean", "invalid AI session defaults")
    local planning = opts.planning
    assert(
        type(planning.capacity_minutes) == "number"
            and planning.capacity_minutes > 0
            and planning.capacity_minutes <= 1440
            and planning.capacity_minutes % 1 == 0,
        "invalid planning.capacity_minutes"
    )
    assert(
        type(planning.reserve_ratio) == "number" and planning.reserve_ratio >= 0 and planning.reserve_ratio < 1,
        "invalid planning.reserve_ratio"
    )
    assert(
        planning.timezone_offset_minutes == false
            or (
                type(planning.timezone_offset_minutes) == "number"
                and planning.timezone_offset_minutes % 1 == 0
                and math.abs(planning.timezone_offset_minutes) <= 840
            ),
        "invalid planning.timezone_offset_minutes"
    )
    local remote, branch = opts.sync.remote, opts.sync.branch
    assert(
        type(remote) == "string" and not remote:find("[%z\r\n]") and not remote:match("^%-"),
        "sync.remote must be a Git URL or path"
    )
    assert(opts.sync.provider == "git" or opts.sync.provider == "server", "invalid sync.provider")
    assert(
        not opts.sync.enabled or opts.sync.provider ~= "git" or remote ~= "",
        "sync.remote is required when Git sync is enabled"
    )
    assert(
        not opts.sync.enabled or opts.sync.provider ~= "server" or opts.sync.url:match("^https?://"),
        "sync.url is required for server sync"
    )
    assert(
        type(opts.sync.allow_http) == "boolean" and type(opts.sync.tls_verify) == "boolean",
        "invalid sync TLS settings"
    )
    assert(
        opts.ai.max_questions >= 0
            and opts.ai.max_questions % 1 == 0
            and opts.ai.max_requests > 0
            and opts.ai.max_requests % 1 == 0,
        "invalid AI request limits"
    )
    assert(type(opts.ai.persona) == "string" and type(opts.ai.language) == "string", "invalid AI profile")
    assert(
        opts.ai.provider == "deepseek"
            or opts.ai.provider == "openai_compatible"
            or opts.ai.provider == "openai"
            or opts.ai.provider == "anthropic",
        "unsupported AI provider"
    )
    assert(
        type(opts.ai.base_url) == "string"
            and opts.ai.base_url:match("^https://")
            and not opts.ai.base_url:find("[%c?#]"),
        "AI base_url must be HTTPS without query or fragment"
    )
    assert(
        opts.ai.provider ~= "deepseek" or opts.ai.base_url:gsub("/+$", "") == "https://api.deepseek.com",
        "Custom AI endpoints must use openai_compatible to isolate credentials"
    )
    if opts.ai.provider == "openai" or opts.ai.provider == "anthropic" or opts.ai.provider == "openai_compatible" then
        assert(opts.ai.base_url ~= "", "AI base_url required for this provider")
        assert(opts.ai.model ~= "", "AI model required for this provider")
    end
    assert(type(opts.ai.model) == "string" and opts.ai.model ~= "", "AI model required")
    assert(
        opts.ai.max_tokens_field == "max_tokens"
            or opts.ai.max_tokens_field == "max_completion_tokens"
            or opts.ai.max_tokens_field == "max_output_tokens",
        "unsupported token limit field"
    )
    for name, value in pairs(opts.ai.capabilities) do
        assert(
            ({ vision = true, balance = true, json_mode = true, thinking_control = true })[name]
                and type(value) == "boolean",
            "invalid AI capability"
        )
    end
    if opts.ai.pricing then
        for _, name in ipairs({ "cache_hit", "cache_miss", "output" }) do
            local rate = opts.ai.pricing[name]
            assert(type(rate) == "number" and rate >= 0 and rate < math.huge, "invalid AI price")
        end
    else
        assert(
            not opts.ai.session_budget_usd and not opts.ai.daily_budget_usd,
            "AI cost budgets require explicit pricing"
        )
    end
    assert(
        opts.attachments.max_bytes > 0 and opts.attachments.max_bytes <= 10485760,
        "attachment limit must be <=10MiB"
    )
    assert(
        type(branch) == "string"
            and branch:match("^[%w][%w/_.%-]*$")
            and not branch:find("..", 1, true)
            and not branch:find("//", 1, true)
            and not branch:find("/.", 1, true)
            and not branch:match("[/.]$")
            and not (branch .. "/"):find("%.lock/"),
        "sync.branch must be a valid branch name"
    )
    vim.validate({
        db_path = { opts.db_path, "string" },
        language = {
            opts.language,
            function(v)
                return v == "en" or v == "zh-CN"
            end,
            "'en' or 'zh-CN'",
        },
        ui = { opts.ui, "table" },
        ui_default_mode = {
            opts.ui.default_mode,
            function(v)
                return v == "float" or v == "sidebar"
            end,
            "'float' or 'sidebar'",
        },
        ui_default_view = {
            opts.ui.default_view,
            function(v)
                return require("todo.ui.grouping").is_view(v)
            end,
            "'active', 'emergency', 'by_urgency', 'by_time', 'by_tag', 'notices', or 'archived'",
        },
        ui_markdown = { opts.ui.markdown, "boolean" },
        ui_performance = { opts.ui.performance, "boolean" },
        ui_daily_keys = { opts.ui.daily_keys, "table" },
        keymaps = { opts.keymaps, "table" },
        icons = { opts.icons, "table" },
        reminders = { opts.reminders, "table" },
        reminder_sound = { opts.reminders.sound, "table" },
        float = { opts.ui.float, "table" },
        sidebar = { opts.ui.sidebar, "table" },
    })
    vim.validate({
        core_bin = {
            opts.core.bin,
            function(v)
                return type(v) == "string"
            end,
            "string",
        },
        float_width = {
            opts.ui.float.width,
            function(v)
                return type(v) == "number" and v > 0 and v <= 1
            end,
            "number in (0, 1]",
        },
        float_height = {
            opts.ui.float.height,
            function(v)
                return type(v) == "number" and v > 0 and v <= 1
            end,
            "number in (0, 1]",
        },
        sidebar_width = {
            opts.ui.sidebar.width,
            function(v)
                return type(v) == "number" and v >= 20 and v % 1 == 0
            end,
            "integer >= 20",
        },
        sidebar_side = {
            opts.ui.sidebar.side,
            function(v)
                return v == "left" or v == "right"
            end,
            "'left' or 'right'",
        },
        reminders_enabled = { opts.reminders.enabled, "boolean" },
        reminder_sound_path = { opts.reminders.sound.path, "string" },
    })
    require("todo.ui.daily_keys").validate(opts.ui.daily_keys)
    local command = opts.reminders.sound.command
    if command ~= false then
        if type(command) ~= "table" or #command == 0 then
            error("reminders.sound.command must be a non-empty argv list or false")
        end
        for _, value in ipairs(command) do
            if type(value) ~= "string" or value == "" then
                error("reminders.sound.command entries must be non-empty strings")
            end
        end
    end
    for name, key in pairs(opts.keymaps) do
        if key == false then
            goto keymap_continue
        end
        if type(key) ~= "string" or key == "" then
            error("keymaps." .. name .. " must be a non-empty string or false")
        end
        ::keymap_continue::
    end
    local colors = {
        azure = true,
        blue = true,
        cyan = true,
        green = true,
        grey = true,
        orange = true,
        purple = true,
        red = true,
        yellow = true,
    }
    for name, icon in pairs(opts.icons) do
        if icon == false or type(icon) == "string" then
            goto icon_continue
        end
        if type(icon) ~= "table" or type(icon.icon) ~= "string" or icon.icon == "" then
            error("icons." .. name .. " must be a string, false, or a which-key icon table")
        end
        if icon.color ~= nil and not colors[icon.color] then
            error("icons." .. name .. ".color is not a supported which-key color")
        end
        ::icon_continue::
    end
end

function M.setup(opts)
    local local_ai = M.local_ai()
    current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), { ai = local_ai }, opts or {})
    local supplied = (opts or {}).ai or {}
    local presets = {
        deepseek = {
            base_url = "https://api.deepseek.com",
            model = "deepseek-flash",
            api_key_env = "DEEPSEEK_API_KEY",
            max_tokens_field = "max_tokens",
        },
        openai = {
            base_url = "https://api.openai.com/v1",
            api_key_env = "OPENAI_API_KEY",
            max_tokens_field = "max_output_tokens",
        },
        anthropic = {
            base_url = "https://api.anthropic.com",
            api_key_env = "ANTHROPIC_API_KEY",
            max_tokens_field = "max_tokens",
        },
        openai_compatible = { api_key_env = "AI_API_KEY", max_tokens_field = "max_tokens" },
    }
    local preset = presets[current.ai.provider]
    if preset then
        local local_provider = local_ai.provider == current.ai.provider
        if supplied.base_url == nil and not (local_provider and local_ai.base_url) then
            current.ai.base_url = preset.base_url or ""
        end
        if supplied.model == nil and not (local_provider and local_ai.model) then
            current.ai.model = preset.model or ""
        end
        if supplied.api_key_env == nil and preset.api_key_env then
            current.ai.api_key_env = preset.api_key_env
        end
        if supplied.max_tokens_field == nil and preset.max_tokens_field then
            current.ai.max_tokens_field = preset.max_tokens_field
        end
    end
    if current.ai.provider ~= "deepseek" and supplied.pricing == nil then
        current.ai.pricing = false
    end
    if opts and opts.ai and opts.ai.max_questions and not opts.ai.max_rounds then
        current.ai.max_rounds = opts.ai.max_questions
    end
    assert(
        current.ai.max_rounds >= 0 and current.ai.max_rounds <= 10 and current.ai.max_rounds % 1 == 0,
        "invalid round limit"
    )
    assert(
        current.ai.max_questions_per_round >= 1
            and current.ai.max_questions_per_round <= 20
            and current.ai.max_questions_per_round % 1 == 0,
        "invalid questions per round"
    )
    assert(
        current.ai.context_tokens >= 2048
            and current.ai.memory.context_tokens >= 0
            and current.ai.memory.recent_turns >= 1,
        "invalid memory budget"
    )
    assert(({ plan = true, build = true, auto = true })[current.ai.mode], "invalid AI mode")
    local permissions = current.ai.permissions
    for _, key in ipairs({ "roots", "domains" }) do
        assert(type(permissions[key]) == "table" and vim.islist(permissions[key]), "invalid permission " .. key)
        for _, value in ipairs(permissions[key]) do
            assert(type(value) == "string" and value ~= "", "invalid permission scope")
        end
    end
    for tool, rule in pairs(permissions.rules) do
        assert(
            ({ read_file = true, search_files = true, fetch_url = true, run_command = true })[tool],
            "unknown permission tool"
        )
        assert(({ allow = true, ask = true, deny = true })[rule], "invalid permission decision")
    end
    assert(type(permissions.auto_apply_documents) == "boolean", "invalid document write policy")
    for _, key in ipairs({
        "max_calls_per_item",
        "max_output_bytes",
        "timeout_ms",
        "snapshot_max_files",
        "snapshot_max_bytes",
        "max_processes",
        "memory_mb",
        "cpu_seconds",
        "scratch_mb",
    }) do
        assert(
            type(permissions[key]) == "number" and permissions[key] >= 1 and permissions[key] % 1 == 0,
            "invalid permission limit: " .. key
        )
    end
    assert(permissions.max_output_bytes >= 4, "research output budget must fit UTF-8")
    local daily = current.ai.planning
    assert(
        daily.max_rounds_per_item >= 0 and daily.max_rounds_per_item <= 10 and daily.max_rounds_per_item % 1 == 0,
        "invalid item rounds"
    )
    assert(
        daily.questions_per_round >= 1 and daily.questions_per_round <= 4 and daily.questions_per_round % 1 == 0,
        "invalid daily question count"
    )
    assert(daily.max_requests_per_item >= 2 and daily.max_requests_per_item % 1 == 0, "invalid per-item request cap")
    assert(
        daily.max_requests_total == false
            or type(daily.max_requests_total) == "number"
                and daily.max_requests_total >= 2
                and daily.max_requests_total % 1 == 0,
        "invalid daily request cap"
    )
    assert(type(daily.stream) == "boolean", "invalid daily stream setting")
    assert(type(daily.image_paste_key) == "string" and daily.image_paste_key ~= "", "invalid image paste key")
    if
        opts
        and opts.planning
        and opts.planning.capacity_minutes
        and opts.planning.reserve_minutes == nil
        and opts.planning.reserve_ratio == nil
        and current.planning.capacity_minutes <= 60
    then
        current.planning.reserve_minutes = math.floor(current.planning.capacity_minutes / 8)
    end
    if opts and opts.planning and opts.planning.reserve_ratio ~= nil and opts.planning.reserve_minutes == nil then
        current.planning.reserve_minutes = false
    end
    assert(
        current.planning.reserve_minutes == false
            or type(current.planning.reserve_minutes) == "number"
                and current.planning.reserve_minutes >= 0
                and current.planning.reserve_minutes < current.planning.capacity_minutes,
        "invalid reserve minutes"
    )
    validate(current)
    return current
end

function M.get()
    return current
end

function M.defaults()
    return vim.deepcopy(defaults)
end

return M
