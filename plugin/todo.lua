if vim.g.loaded_todo_nvim then
  return
end
vim.g.loaded_todo_nvim = true

vim.api.nvim_create_user_command("Todo", function(command)
  require("todo.commands").run(command.args)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    return require("todo.commands").complete(arglead, cmdline)
  end,
  desc = "Manage todo.nvim tasks",
})

require("todo")._bootstrap()
