---@brief The editor action catalog.
---
--- Each entry is a tiny, Ex-command-backed thing Jev can pick. Descriptions are
--- user-facing: they are the rubric Jev routes on, so they matter more than the code.
--- `run` executes with the target window already current (see |jev-flow|); it may
--- error() freely, the caller pcalls it.

---@class JevParam
---@field type "enum"|"boolean"|"integer"|"string"
---@field description string
---@field required boolean|nil
---@field enum table<string,string>|nil
---@field min integer|nil
---@field max integer|nil
---@field default any|nil

---@class JevCtx
---@field target_win integer
---@field target_buf integer

---@class JevAction
---@field name string
---@field description string
---@field params table<string, JevParam>
---@field readOnly boolean|nil
---@field destructive boolean|nil
---@field run fun(args: table, ctx: JevCtx): string|nil

local M = {}

--- The window the action should act on. Inside |nvim_win_call()| that is the
--- current window; fall back to ctx for direct calls.
---@param ctx JevCtx|nil
---@return integer
local function win(ctx)
  local w = vim.api.nvim_get_current_win()
  if ctx and ctx.target_win and vim.api.nvim_win_is_valid(ctx.target_win) then
    -- Prefer the current window when we really are inside nvim_win_call().
    if w == ctx.target_win then
      return w
    end
    return ctx.target_win
  end
  return w
end

---@param ctx JevCtx|nil
---@return integer
local function buf(ctx)
  return vim.api.nvim_win_get_buf(win(ctx))
end

---@type JevAction[]
local catalog = {
  {
    name = 'save_file',
    description = 'Write the current file to disk. Saves only this buffer, not the others.',
    params = {},
    run = function()
      vim.cmd('write')
      return 'saved'
    end,
  },
  {
    name = 'save_all',
    description = 'Write every modified file to disk at once.',
    params = {},
    run = function()
      vim.cmd('wall')
      return 'saved all'
    end,
  },
  {
    name = 'close_window',
    description = 'Close the current window or split. Refuses when it is the last one, '
      .. 'or when the buffer has unsaved changes.',
    params = {},
    run = function()
      if vim.fn.winnr('$') == 1 and #vim.api.nvim_list_tabpages() == 1 then
        error('this is the last window', 0)
      end
      vim.cmd('quit')
      return 'closed'
    end,
  },
  {
    name = 'quit_all',
    description = 'Quit Neovim entirely, closing every window and tab.',
    params = {},
    destructive = true,
    run = function()
      vim.cmd('quitall')
    end,
  },
  {
    name = 'reload_file',
    description = 'Reload the current file from disk, throwing away unsaved changes in it.',
    params = {},
    destructive = true,
    run = function()
      vim.cmd('edit!')
      return 'reloaded'
    end,
  },
  {
    name = 'open_file',
    description = 'Open a file by path in the current window.',
    params = {
      path = { type = 'string', description = 'Path of the file to open', required = true },
    },
    run = function(args)
      local path = tostring(args.path or '')
      if path == '' then
        error('no path given', 0)
      end
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
      return 'opened ' .. vim.fn.fnamemodify(path, ':t')
    end,
  },
  {
    name = 'goto_line',
    description = 'Move the cursor to a line number in the current buffer.',
    params = {
      line = { type = 'integer', description = 'Line number to jump to', required = true },
    },
    readOnly = true,
    run = function(args, ctx)
      local w = win(ctx)
      local b = vim.api.nvim_win_get_buf(w)
      local want = math.floor(tonumber(args.line) or 0)
      local count = vim.api.nvim_buf_line_count(b)
      local line = math.max(1, math.min(want, count))
      vim.api.nvim_win_set_cursor(w, { line, 0 })
      return 'line ' .. line
    end,
  },
  {
    name = 'split_window',
    description = 'Split the current window in two, side by side or one above the other.',
    params = {
      direction = {
        type = 'enum',
        description = 'Which way to split',
        required = true,
        enum = {
          vertical = 'Side by side, a new window to the left or right',
          horizontal = 'Stacked, a new window above or below',
        },
      },
    },
    run = function(args)
      if args.direction == 'vertical' then
        vim.cmd('vsplit')
      else
        vim.cmd('split')
      end
      return tostring(args.direction) .. ' split'
    end,
  },
  {
    name = 'new_tab',
    description = 'Open a new, empty tab page.',
    params = {},
    run = function()
      vim.cmd('tabnew')
      return 'new tab'
    end,
  },
  {
    name = 'next_buffer',
    description = 'Show the next buffer in the buffer list in this window.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('bnext')
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')
    end,
  },
  {
    name = 'previous_buffer',
    description = 'Show the previous buffer in the buffer list in this window.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('bprevious')
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')
    end,
  },
  {
    name = 'toggle_option',
    description = 'Turn a window display option on or off.',
    params = {
      option = {
        type = 'enum',
        description = 'Which option to flip',
        required = true,
        enum = {
          number = 'Line numbers in the gutter',
          relativenumber = 'Line numbers counted from the cursor',
          wrap = 'Soft wrapping of long lines',
          spell = 'Spell checking',
          list = 'Visible tabs, trailing spaces and other whitespace',
          cursorline = 'Highlight of the line the cursor is on',
        },
      },
    },
    run = function(args, ctx)
      local w = win(ctx)
      local opt = tostring(args.option or '')
      local ok, current = pcall(function()
        return vim.wo[w][opt]
      end)
      if not ok then
        error('unknown option: ' .. opt, 0)
      end
      vim.wo[w][opt] = not current
      return opt .. ' ' .. (not current and 'on' or 'off')
    end,
  },
  {
    name = 'search',
    description = 'Search the current buffer for a pattern and jump to the next match.',
    params = {
      pattern = { type = 'string', description = 'Text or pattern to look for', required = true },
    },
    readOnly = true,
    run = function(args)
      local pattern = tostring(args.pattern or '')
      if pattern == '' then
        error('no pattern given', 0)
      end
      vim.fn.setreg('/', pattern)
      vim.opt.hlsearch = true
      local line = vim.fn.search(pattern, 'w')
      if line == 0 then
        return 'no match for ' .. pattern
      end
      return 'match on line ' .. line
    end,
  },
  {
    name = 'undo',
    description = 'Undo the last change in the current buffer.',
    params = {},
    run = function()
      vim.cmd('undo')
      return 'undone'
    end,
  },
  {
    name = 'redo',
    description = 'Redo the change that was last undone.',
    params = {},
    run = function()
      vim.cmd('redo')
      return 'redone'
    end,
  },
  {
    name = 'format_buffer',
    description = 'Reformat the whole buffer with the attached language server.',
    params = {},
    run = function()
      vim.lsp.buf.format({ async = false })
      return 'formatted'
    end,
  },
  {
    name = 'select_all',
    description = 'Select the entire buffer in visual mode.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('normal! ggVG')
      return 'selected'
    end,
  },
  {
    name = 'set_filetype',
    description = 'Set the filetype of the current buffer, which drives syntax and plugins.',
    params = {
      filetype = {
        type = 'string',
        description = 'Filetype name, such as lua, python or markdown',
        required = true,
      },
    },
    run = function(args, ctx)
      local ft = tostring(args.filetype or '')
      if ft == '' then
        error('no filetype given', 0)
      end
      vim.bo[buf(ctx)].filetype = ft
      return 'filetype ' .. ft
    end,
  },
  {
    name = 'show_diagnostics',
    description = 'Collect the diagnostics for this buffer into the quickfix list and open it.',
    params = {},
    readOnly = true,
    run = function()
      vim.diagnostic.setqflist({ open = true })
      return 'diagnostics in quickfix'
    end,
  },
}

local index = {}
for _, action in ipairs(catalog) do
  index[action.name] = action
end

--- Every action, in a stable order.
---@return JevAction[]
function M.list()
  return catalog
end

---@param name string|nil
---@return JevAction|nil
function M.by_name(name)
  if type(name) ~= 'string' then
    return nil
  end
  return index[name]
end

return M
