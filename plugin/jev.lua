-- jev.nvim: user commands. Kept thin; everything real lives in lua/jev/.

if vim.g.loaded_jev then
  return
end
vim.g.loaded_jev = true

vim.api.nvim_create_user_command('Jev', function()
  require('jev').toggle()
end, { desc = 'Toggle the jev panel' })

vim.api.nvim_create_user_command('JevToggle', function()
  require('jev').toggle()
end, { desc = 'Toggle the jev panel' })

vim.api.nvim_create_user_command('JevAsk', function(opts)
  local jev = require('jev')
  if not jev.panel.is_open() then
    jev.open()
  end
  jev.ask(opts.args)
end, { nargs = '*', desc = 'Ask jev for an editor action' })
