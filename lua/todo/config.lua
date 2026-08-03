local M = {}

local defaults = {
    db_path = vim.fn.stdpath("data") .. "/todo.nvim/todo.db",
    language = "en",
    ui = {
        default_mode = "float",
        default_view = "active",
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

local function validate(opts)
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
                return v == "active" or v == "emergency" or v == "notices" or v == "archived"
            end,
            "'active', 'emergency', 'notices', or 'archived'",
        },
        keymaps = { opts.keymaps, "table" },
        icons = { opts.icons, "table" },
        reminders = { opts.reminders, "table" },
        reminder_sound = { opts.reminders.sound, "table" },
        float = { opts.ui.float, "table" },
        sidebar = { opts.ui.sidebar, "table" },
    })
    vim.validate({
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
    current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
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
