-- Neovim side of scripts/screenshot.mjs.
--
-- Loads jev.nvim out of this repository, then replaces `jev.client.post` with a
-- table of canned, API-shaped answers keyed by utterance. Everything else — the
-- questions, the decoder, the policy, the panel, the actions — is the real
-- plugin, so the screenshots show what the plugin actually does. Nothing here
-- reaches the network and no API key is needed.
--
-- Run it in an --embed instance:  :luafile scripts/shot_init.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.g.loaded_jev = nil
vim.cmd('runtime! plugin/jev.lua')

-- ---------------------------------------------------------------------------
-- Look
-- ---------------------------------------------------------------------------

vim.o.termguicolors = true
vim.o.background = 'dark'
pcall(vim.cmd.colorscheme, 'default')
vim.o.number = true
vim.o.cursorline = true
vim.o.signcolumn = 'no'
vim.o.laststatus = 2
vim.o.ruler = true
vim.o.showmode = true
vim.o.scrolloff = 3
vim.o.shortmess = vim.o.shortmess .. 'I'
vim.o.fillchars = 'vert:│,eob: '
vim.o.list = false
vim.o.wrap = false -- the panel sets its own 'wrap'; code panes read better without it
vim.o.swapfile = false
vim.o.shadafile = 'NONE'

-- ---------------------------------------------------------------------------
-- The canned Jev answers
-- ---------------------------------------------------------------------------

local ROUTE = '__tool__'
local NONE = '__none__'

--- One choice answer in the documented response shape.
---@param choice string
---@param probabilities table<string, number>
local function choice(choice_value, probabilities)
  return {
    type = 'choice',
    choice = choice_value,
    confidence = probabilities[choice_value],
    probabilities = probabilities,
  }
end

--- A full response: the route answer plus any argument answers.
---@param probabilities table<string, number>  route distribution
---@param picked string                        the route Jev chose
---@param args table<string, table>            extra answers by question id
---@param ms integer                           the latency to report
local function response(picked, probabilities, args, ms)
  local answers = { [ROUTE] = choice(picked, probabilities) }
  for qid, answer in pairs(args or {}) do
    answers[qid] = answer
  end
  return {
    ms = ms,
    body = {
      model = 'jev-1.13.0',
      answers = answers,
      usage = { input_tokens = 431, output_tokens = 57 },
    },
  }
end

--- What Jev "answers" for each utterance the screenshots ask.
local canned = {
  ['split the window vertically'] = response('split_window', {
    split_window = 0.93,
    new_tab = 0.04,
    [NONE] = 0.03,
  }, {
    ['split_window::direction'] = choice('vertical', { vertical = 0.96, horizontal = 0.04 }),
  }, 118),

  ['go to line 40'] = response('goto_line', {
    goto_line = 0.96,
    search = 0.02,
    [NONE] = 0.02,
  }, {
    ['goto_line::line'] = choice('40', { ['40'] = 0.97, ['(not stated)'] = 0.03 }),
  }, 96),

  ['use relative line numbers'] = response('toggle_option', {
    toggle_option = 0.9,
    [NONE] = 0.06,
    set_filetype = 0.04,
  }, {
    ['toggle_option::option'] = choice('relativenumber', {
      relativenumber = 0.88,
      number = 0.07,
      cursorline = 0.02,
      list = 0.01,
      wrap = 0.01,
      spell = 0.01,
    }),
  }, 104),

  ['throw away my changes and reload the file'] = response('reload_file', {
    reload_file = 0.95,
    undo = 0.03,
    [NONE] = 0.02,
  }, {}, 132),

  ['make me a sandwich'] = response(NONE, {
    [NONE] = 0.71,
    new_tab = 0.17,
    open_file = 0.12,
  }, {}, 141),
}

--- Stand in for the HTTP client. Same signature, same callback contract, one
--- scheduled tick of "latency" so the panel's pending line is real.
require('jev.client').post = function(_opts, body, cb)
  local canned_response = canned[vim.trim(tostring(body.state or ''))]
  vim.schedule(function()
    if not canned_response then
      cb('no canned answer for: ' .. tostring(body.state), nil, 0)
      return
    end
    cb(nil, canned_response.body, canned_response.ms)
  end)
end

require('jev').setup({ api_key = 'demo-key-not-a-real-one' })

-- The confirm tier hands over to `vim.ui.select`, whose stock implementation
-- blocks in `inputlist()` immediately — before Neovim returns to its main loop
-- and repaints. Without this the panel line the plugin wrote one statement
-- earlier is still the "…" placeholder on screen. Only the repaint is forced;
-- the prompt itself is the real, unmodified `vim.ui.select`.
local stock_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  vim.cmd('redraw')
  return stock_select(items, opts, on_choice)
end

-- ---------------------------------------------------------------------------
-- Helpers for the driver
-- ---------------------------------------------------------------------------

_G.JevShot = {}

--- Open `path` in the current window with syntax highlighting on.
---@param path string
---@param line integer|nil
function _G.JevShot.edit(path, line)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  vim.cmd('syntax enable')
  pcall(vim.treesitter.start, 0, 'lua')
  vim.wo.number = true
  vim.wo.cursorline = true
  if line then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd('normal! zz')
  end
end

--- The panel transcript, for the driver to poll.
---@return string[]
function _G.JevShot.lines()
  return require('jev.panel').lines()
end

return true
