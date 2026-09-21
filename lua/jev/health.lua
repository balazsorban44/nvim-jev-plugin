---@brief `:checkhealth jev`

local M = {}

local health = vim.health or {}
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local err = health.error or health.report_error

function M.check()
  start('jev.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    ok('Neovim ' .. tostring(vim.version()))
  else
    err('jev.nvim needs Neovim 0.10 or newer')
  end

  if vim.fn.executable('curl') == 1 then
    ok('curl found at ' .. vim.fn.exepath('curl'))
  else
    err('curl not found on PATH', { 'Install curl; jev.nvim shells out to it for every request.' })
  end

  local config = require('jev.config')
  if config.options.api_key and config.options.api_key ~= '' then
    ok('API key set via setup({ api_key = ... })')
  elseif vim.env.TYPESAFE_API_KEY and vim.env.TYPESAFE_API_KEY ~= '' then
    ok('API key found in $TYPESAFE_API_KEY')
  else
    warn('no API key', {
      'export TYPESAFE_API_KEY=... or pass api_key to require("jev").setup().',
      'Keys live at https://console.typesafe.ai/keys',
    })
  end

  local actions = require('jev.actions')
  local count = #actions.list()
  if count > 0 then
    ok(string.format('%d actions in the catalog', count))
  else
    err('the action catalog is empty')
  end

  ok(string.format('model %s at %s', config.options.model, config.options.url))
end

return M
