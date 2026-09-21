---@brief The editor action catalog.
---
--- Each entry is a tiny, Ex-command-backed thing Jev can pick. Descriptions are
--- user-facing: they are the rubric Jev routes on, so they matter more than the code.
--- `run` executes with the target window already current (see |jev-flow|); it may
--- error() freely, the caller pcalls it.
---
--- Entries are grouped by `category` in this file, and |jev.actions.categories()|
--- hands that grouping back in the same order (see |:JevActions|).
---
--- Two things every entry owes the model:
---   * a name no other entry has, and
---   * a short description that says the one thing this entry does, in the words
---     a user would say. Every description rides in the routing Choice of every
---     request, so ~90 characters is the budget and overlap is the enemy: Jev is
---     literal, and two descriptions that could both match a phrase split the
---     probability between them.
---
--- Jev cannot count or do arithmetic, so anything numeric is either a Choice over
--- a small range, a number lifted from the user's own words, or computed here.

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
---@field category string
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

-- ---------------------------------------------------------------------------
-- Small shared helpers. Everything here is straightforward and short: an action
-- that needs more than a handful of lines is usually two actions.
-- ---------------------------------------------------------------------------

---@param ctx JevCtx|nil
---@return integer win, integer buf, integer line
local function here(ctx)
  local w = win(ctx)
  local b = vim.api.nvim_win_get_buf(w)
  return w, b, vim.api.nvim_win_get_cursor(w)[1]
end

---@param b integer
---@param l integer
---@return string
local function line_at(b, l)
  return vim.api.nvim_buf_get_lines(b, l - 1, l, false)[1] or ''
end

--- Type keys like <C-d> that `:normal!` cannot carry as text. 'n' keeps them
--- unmapped, 'x' runs them before this returns.
---@param seq string
local function press(seq)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(seq, true, false, true), 'nx', false)
end

---@param s any
---@return string
local function text(s)
  return tostring(s or '')
end

--- A literal (non-magic) Lua pattern for `s`, so the user's words are matched
--- exactly rather than as a regex they never asked for.
---@param s string
---@return string
local function literal(s)
  return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%1'))
end

---@param s string
---@return string
local function literal_replacement(s)
  return (s:gsub('%%', '%%%%'))
end

---@param b integer
---@return vim.lsp.Client[]
local function lsp_clients(b)
  local clients = vim.lsp.get_clients({ bufnr = b })
  if #clients == 0 then
    error('no language server attached to this buffer', 0)
  end
  return clients
end

---@param count integer
local function diagnostic_jump(count)
  if type(vim.diagnostic.jump) == 'function' then
    vim.diagnostic.jump({ count = count, float = false })
  elseif count > 0 then
    vim.diagnostic.goto_next({ float = false })
  else
    vim.diagnostic.goto_prev({ float = false })
  end
end

---@return integer
local function quickfix_size()
  return vim.fn.getqflist({ size = 0 }).size or 0
end

---@param w integer
---@return integer
local function loclist_size(w)
  return vim.fn.getloclist(w, { size = 0 }).size or 0
end

---@param name string
---@return string
local function tail(name)
  if name == '' then
    return '[No Name]'
  end
  return vim.fn.fnamemodify(name, ':t')
end

--- `a` .. `z`, the marks a user can name out loud.
---@return table<string,string>
local function letter_enum()
  local enum = {}
  for i = string.byte('a'), string.byte('z') do
    enum[string.char(i)] = ''
  end
  return enum
end

---@type JevAction[]
local catalog = {
  -- =========================================================================
  -- files
  -- =========================================================================
  {
    name = 'save_file',
    category = 'files',
    description = 'Write the current file to disk. Saves only this buffer, not the others.',
    params = {},
    run = function()
      vim.cmd('write')
      return 'saved'
    end,
  },
  {
    name = 'save_all',
    category = 'files',
    description = 'Write every modified file to disk at once.',
    params = {},
    run = function()
      vim.cmd('wall')
      return 'saved all'
    end,
  },
  {
    name = 'save_as',
    category = 'files',
    description = 'Save the current buffer under a new path, and keep editing that new file.',
    params = {
      path = { type = 'string', description = 'Path to save the file as', required = true },
    },
    run = function(args)
      local path = text(args.path)
      if path == '' then
        error('no path given', 0)
      end
      vim.cmd('saveas ' .. vim.fn.fnameescape(path))
      return 'saved as ' .. tail(path)
    end,
  },
  {
    name = 'open_file',
    category = 'files',
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
    name = 'new_file',
    category = 'files',
    description = 'Start a new empty unnamed buffer in this window.',
    params = {},
    run = function()
      vim.cmd('enew')
      return 'new buffer'
    end,
  },
  {
    name = 'reload_file',
    category = 'files',
    description = 'Reload the current file from disk, throwing away unsaved changes in it.',
    params = {},
    destructive = true,
    run = function()
      vim.cmd('edit!')
      return 'reloaded'
    end,
  },
  {
    name = 'set_filetype',
    category = 'files',
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
    name = 'show_file_path',
    category = 'files',
    description = 'Show the full path of the file in this window.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local name = vim.api.nvim_buf_get_name(buf(ctx))
      return name ~= '' and name or '[No Name]'
    end,
  },
  {
    name = 'cd_to_file_dir',
    category = 'files',
    description = "Change the working directory to the folder holding the current file.",
    params = {},
    run = function(_, ctx)
      local name = vim.api.nvim_buf_get_name(buf(ctx))
      if name == '' then
        error('this buffer has no file', 0)
      end
      local dir = vim.fn.fnamemodify(name, ':p:h')
      vim.cmd('cd ' .. vim.fn.fnameescape(dir))
      return 'cwd ' .. dir
    end,
  },

  -- =========================================================================
  -- buffers
  -- =========================================================================
  {
    name = 'next_buffer',
    category = 'buffers',
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
    category = 'buffers',
    description = 'Show the previous buffer in the buffer list in this window.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('bprevious')
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t')
    end,
  },
  {
    name = 'goto_buffer',
    category = 'buffers',
    description = 'Switch this window to the buffer with a given buffer number.',
    params = {
      number = { type = 'integer', description = 'Buffer number to switch to', required = true },
    },
    readOnly = true,
    run = function(args)
      local n = math.floor(tonumber(args.number) or 0)
      if vim.fn.bufexists(n) == 0 then
        error('no buffer ' .. n, 0)
      end
      vim.cmd('buffer ' .. n)
      return 'buffer ' .. n .. ': ' .. tail(vim.api.nvim_buf_get_name(0))
    end,
  },
  {
    name = 'list_buffers',
    category = 'buffers',
    description = 'List the open buffers and their numbers.',
    params = {},
    readOnly = true,
    run = function()
      local parts = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].buflisted then
          parts[#parts + 1] = b .. ':' .. tail(vim.api.nvim_buf_get_name(b))
        end
      end
      if #parts == 0 then
        return 'no listed buffers'
      end
      return #parts .. ' buffers — ' .. table.concat(parts, ', ')
    end,
  },
  {
    name = 'close_buffer',
    category = 'buffers',
    description = 'Close the current buffer. Refuses when it has unsaved changes.',
    params = {},
    run = function(_, ctx)
      local b = buf(ctx)
      if vim.bo[b].modified then
        error('buffer has unsaved changes', 0)
      end
      local name = tail(vim.api.nvim_buf_get_name(b))
      vim.cmd('bdelete')
      return 'closed ' .. name
    end,
  },
  {
    name = 'delete_buffer_force',
    category = 'buffers',
    description = 'Close the current buffer even when it has unsaved changes, losing them.',
    params = {},
    destructive = true,
    run = function(_, ctx)
      local name = tail(vim.api.nvim_buf_get_name(buf(ctx)))
      vim.cmd('bdelete!')
      return 'deleted ' .. name
    end,
  },
  {
    name = 'close_other_buffers',
    category = 'buffers',
    description = 'Close every buffer except this one, keeping the unsaved ones open.',
    params = {},
    destructive = true,
    run = function(_, ctx)
      local keep = buf(ctx)
      local closed, kept = 0, 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= keep and vim.bo[b].buflisted then
          if vim.bo[b].modified then
            kept = kept + 1
          else
            vim.api.nvim_buf_delete(b, {})
            closed = closed + 1
          end
        end
      end
      return ('closed %d, kept %d unsaved'):format(closed, kept)
    end,
  },

  -- =========================================================================
  -- windows
  -- =========================================================================
  {
    name = 'split_window',
    category = 'windows',
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
    name = 'close_window',
    category = 'windows',
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
    name = 'only_window',
    category = 'windows',
    description = 'Close every other split in this tab and leave only the current window.',
    params = {},
    run = function()
      local before = vim.fn.winnr('$')
      vim.cmd('only')
      return ('closed %d other windows'):format(math.max(before - 1, 0))
    end,
  },
  {
    name = 'equalize_windows',
    category = 'windows',
    description = 'Give every split in this tab the same size again.',
    params = {},
    run = function()
      vim.cmd('wincmd =')
      return 'windows equalized'
    end,
  },
  {
    name = 'maximize_window',
    category = 'windows',
    description = 'Make the current split as tall and wide as it can be.',
    params = {},
    run = function()
      vim.cmd('wincmd _')
      vim.cmd('wincmd |')
      return 'window maximized'
    end,
  },
  {
    name = 'resize_window',
    category = 'windows',
    description = 'Resize the current split to a given number of lines or columns.',
    params = {
      dimension = {
        type = 'enum',
        description = 'Which way to size it',
        required = true,
        enum = {
          height = 'Height, in lines',
          width = 'Width, in columns',
        },
      },
      size = { type = 'integer', description = 'How many lines or columns', required = true },
    },
    run = function(args, ctx)
      local w = win(ctx)
      local size = math.max(1, math.floor(tonumber(args.size) or 0))
      if args.dimension == 'width' then
        vim.api.nvim_win_set_width(w, size)
        return 'width ' .. size
      end
      vim.api.nvim_win_set_height(w, size)
      return 'height ' .. size
    end,
  },
  {
    name = 'swap_window',
    category = 'windows',
    description = 'Swap this split with the next one, exchanging their positions.',
    params = {},
    run = function()
      if vim.fn.winnr('$') < 2 then
        error('there is only one window', 0)
      end
      vim.cmd('wincmd x')
      return 'windows swapped'
    end,
  },
  {
    name = 'move_window_to_tab',
    category = 'windows',
    description = 'Move the current split out into a tab page of its own.',
    params = {},
    run = function()
      if vim.fn.winnr('$') < 2 then
        error('there is only one window', 0)
      end
      vim.cmd('wincmd T')
      return 'moved to a new tab'
    end,
  },
  {
    name = 'focus_window',
    category = 'windows',
    description = 'Move the cursor into the split to the left, right, above or below.',
    params = {
      direction = {
        type = 'enum',
        description = 'Which neighbouring split to go to',
        required = true,
        enum = {
          left = 'The split to the left',
          right = 'The split to the right',
          up = 'The split above',
          down = 'The split below',
        },
      },
    },
    readOnly = true,
    run = function(args)
      local keys = { left = 'h', right = 'l', up = 'k', down = 'j' }
      local key = keys[text(args.direction)]
      if not key then
        error('unknown direction', 0)
      end
      vim.cmd('wincmd ' .. key)
      return 'focus ' .. text(args.direction)
    end,
  },
  {
    name = 'toggle_diff_mode',
    category = 'windows',
    description = 'Turn diff mode for this window on or off, to compare it with another split.',
    params = {},
    run = function(_, ctx)
      local w = win(ctx)
      if vim.wo[w].diff then
        vim.cmd('diffoff')
        return 'diff off'
      end
      vim.cmd('diffthis')
      return 'diff on'
    end,
  },

  -- =========================================================================
  -- tabs
  -- =========================================================================
  {
    name = 'new_tab',
    category = 'tabs',
    description = 'Open a new, empty tab page.',
    params = {},
    run = function()
      vim.cmd('tabnew')
      return 'new tab'
    end,
  },
  {
    name = 'close_tab',
    category = 'tabs',
    description = 'Close the current tab page and its windows.',
    params = {},
    run = function()
      if #vim.api.nvim_list_tabpages() < 2 then
        error('this is the last tab', 0)
      end
      vim.cmd('tabclose')
      return 'tab closed'
    end,
  },
  {
    name = 'tab_only',
    category = 'tabs',
    description = 'Close every other tab page and keep only this one.',
    params = {},
    run = function()
      local before = #vim.api.nvim_list_tabpages()
      vim.cmd('tabonly')
      return ('closed %d other tabs'):format(math.max(before - 1, 0))
    end,
  },
  {
    name = 'next_tab',
    category = 'tabs',
    description = 'Go to the next tab page.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('tabnext')
      return 'tab ' .. vim.fn.tabpagenr()
    end,
  },
  {
    name = 'previous_tab',
    category = 'tabs',
    description = 'Go to the previous tab page.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('tabprevious')
      return 'tab ' .. vim.fn.tabpagenr()
    end,
  },
  {
    name = 'goto_tab',
    category = 'tabs',
    description = 'Go to a tab page by its number, counting from the left.',
    params = {
      number = {
        type = 'integer',
        description = 'Which tab, counting from the left',
        required = true,
        min = 1,
        max = 9,
      },
    },
    readOnly = true,
    run = function(args)
      local total = #vim.api.nvim_list_tabpages()
      local n = math.max(1, math.min(math.floor(tonumber(args.number) or 1), total))
      vim.cmd('tabnext ' .. n)
      return 'tab ' .. n
    end,
  },
  {
    name = 'move_tab',
    category = 'tabs',
    description = 'Move the current tab one place to the left or to the right.',
    params = {
      direction = {
        type = 'enum',
        description = 'Which way to move the tab',
        required = true,
        enum = { left = 'One place towards the front', right = 'One place towards the back' },
      },
    },
    run = function(args)
      local at, total = vim.fn.tabpagenr(), #vim.api.nvim_list_tabpages()
      if args.direction == 'left' then
        if at == 1 then
          error('already the first tab', 0)
        end
        vim.cmd('tabmove -1')
      else
        if at == total then
          error('already the last tab', 0)
        end
        vim.cmd('tabmove +1')
      end
      return 'tab ' .. vim.fn.tabpagenr()
    end,
  },

  -- =========================================================================
  -- navigation
  -- =========================================================================
  {
    name = 'goto_line',
    category = 'navigation',
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
    name = 'goto_top',
    category = 'navigation',
    description = 'Jump to the very top of the buffer, the first line.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      vim.api.nvim_win_set_cursor(win(ctx), { 1, 0 })
      return 'line 1'
    end,
  },
  {
    name = 'goto_bottom',
    category = 'navigation',
    description = 'Jump to the very bottom of the buffer, the last line.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local w, b = here(ctx)
      local last = vim.api.nvim_buf_line_count(b)
      vim.api.nvim_win_set_cursor(w, { last, 0 })
      return 'line ' .. last
    end,
  },
  {
    name = 'goto_percent',
    category = 'navigation',
    description = 'Jump part of the way through the file, by percentage.',
    params = {
      percent = {
        type = 'integer',
        description = 'How far through the file, 0 to 100',
        required = true,
      },
    },
    readOnly = true,
    run = function(args, ctx)
      local w, b = here(ctx)
      local pct = math.max(0, math.min(math.floor(tonumber(args.percent) or 0), 100))
      local total = vim.api.nvim_buf_line_count(b)
      local line = math.max(1, math.min(math.ceil(total * pct / 100), total))
      vim.api.nvim_win_set_cursor(w, { line, 0 })
      return pct .. '% — line ' .. line
    end,
  },
  {
    name = 'match_bracket',
    category = 'navigation',
    description = 'Jump to the bracket, brace or parenthesis matching the one at the cursor.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local w = win(ctx)
      local before = vim.api.nvim_win_get_cursor(w)
      vim.cmd('normal! %')
      local after = vim.api.nvim_win_get_cursor(w)
      if before[1] == after[1] and before[2] == after[2] then
        error('no matching bracket here', 0)
      end
      return 'line ' .. after[1]
    end,
  },
  {
    name = 'next_paragraph',
    category = 'navigation',
    description = 'Move the cursor down to the next blank line, the start of the next paragraph.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      vim.cmd('normal! }')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'previous_paragraph',
    category = 'navigation',
    description = 'Move the cursor up to the previous blank line, the paragraph before this one.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      vim.cmd('normal! {')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'next_function',
    category = 'navigation',
    description = 'Jump forward to the start of the next function or section.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      vim.cmd('normal! ]]')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'previous_function',
    category = 'navigation',
    description = 'Jump back to the start of the previous function or section.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      vim.cmd('normal! [[')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'scroll_half_page_down',
    category = 'navigation',
    description = 'Scroll half a screen down, towards the end of the file.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      press('<C-d>')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'scroll_half_page_up',
    category = 'navigation',
    description = 'Scroll half a screen up, back towards the start of the file.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      press('<C-u>')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'center_cursor_line',
    category = 'navigation',
    description = 'Scroll so the line the cursor is on sits in the middle of the screen.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('normal! zz')
      return 'centered'
    end,
  },
  {
    name = 'jump_back',
    category = 'navigation',
    description = 'Go back to where the cursor was before the last jump.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      press('<C-o>')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'jump_forward',
    category = 'navigation',
    description = 'Go forward again to the place you jumped back from.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      press('<C-i>')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'goto_last_edit',
    category = 'navigation',
    description = 'Jump to the spot where you last changed something in this buffer.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      vim.cmd('normal! `.')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'goto_mark',
    category = 'navigation',
    description = 'Jump to a mark you set earlier, named by a single letter.',
    params = {
      letter = {
        type = 'enum',
        description = 'The letter naming the mark',
        required = true,
        enum = letter_enum(),
      },
    },
    readOnly = true,
    run = function(args, ctx)
      local letter = text(args.letter):lower()
      if not letter:match('^%l$') then
        error('a mark is one letter', 0)
      end
      local w, b = here(ctx)
      if vim.api.nvim_buf_get_mark(b, letter)[1] == 0 then
        error('mark ' .. letter .. ' is not set', 0)
      end
      vim.cmd('normal! `' .. letter)
      return 'mark ' .. letter .. ' — line ' .. vim.api.nvim_win_get_cursor(w)[1]
    end,
  },
  {
    name = 'set_mark',
    category = 'navigation',
    description = 'Put a mark named by a letter on the current line, to jump back to later.',
    params = {
      letter = {
        type = 'enum',
        description = 'The letter to name the mark',
        required = true,
        enum = letter_enum(),
      },
    },
    run = function(args, ctx)
      local letter = text(args.letter):lower()
      if not letter:match('^%l$') then
        error('a mark is one letter', 0)
      end
      local _, _, line = here(ctx)
      vim.cmd('mark ' .. letter)
      return 'mark ' .. letter .. ' on line ' .. line
    end,
  },

  -- =========================================================================
  -- editing
  -- =========================================================================
  {
    name = 'undo',
    category = 'editing',
    description = 'Undo the last change in the current buffer.',
    params = {},
    run = function()
      vim.cmd('undo')
      return 'undone'
    end,
  },
  {
    name = 'redo',
    category = 'editing',
    description = 'Redo the change that was last undone.',
    params = {},
    run = function()
      vim.cmd('redo')
      return 'redone'
    end,
  },
  {
    name = 'delete_line',
    category = 'editing',
    description = 'Delete the line the cursor is on.',
    params = {},
    run = function(_, ctx)
      local _, b, line = here(ctx)
      vim.api.nvim_buf_set_lines(b, line - 1, line, false, {})
      return 'deleted line ' .. line
    end,
  },
  {
    name = 'duplicate_line',
    category = 'editing',
    description = 'Copy the current line and paste the copy right below it.',
    params = {},
    run = function(_, ctx)
      local w, b, line = here(ctx)
      vim.api.nvim_buf_set_lines(b, line, line, false, { line_at(b, line) })
      vim.api.nvim_win_set_cursor(w, { line + 1, 0 })
      return 'duplicated line ' .. line
    end,
  },
  {
    name = 'move_line_up',
    category = 'editing',
    description = 'Move the current line one line up, swapping it with the line above.',
    params = {},
    run = function(_, ctx)
      local w, b, line = here(ctx)
      if line == 1 then
        error('already the first line', 0)
      end
      local this = line_at(b, line)
      local above = line_at(b, line - 1)
      vim.api.nvim_buf_set_lines(b, line - 2, line, false, { this, above })
      vim.api.nvim_win_set_cursor(w, { line - 1, 0 })
      return 'line ' .. (line - 1)
    end,
  },
  {
    name = 'move_line_down',
    category = 'editing',
    description = 'Move the current line one line down, swapping it with the line below.',
    params = {},
    run = function(_, ctx)
      local w, b, line = here(ctx)
      if line >= vim.api.nvim_buf_line_count(b) then
        error('already the last line', 0)
      end
      local this = line_at(b, line)
      local below = line_at(b, line + 1)
      vim.api.nvim_buf_set_lines(b, line - 1, line + 1, false, { below, this })
      vim.api.nvim_win_set_cursor(w, { line + 1, 0 })
      return 'line ' .. (line + 1)
    end,
  },
  {
    name = 'join_lines',
    category = 'editing',
    description = 'Join the next line onto the end of this one, making them a single line.',
    params = {},
    run = function(_, ctx)
      local _, b, line = here(ctx)
      if line >= vim.api.nvim_buf_line_count(b) then
        error('nothing below to join', 0)
      end
      vim.cmd('normal! J')
      return 'joined line ' .. line
    end,
  },
  {
    name = 'indent_lines',
    category = 'editing',
    description = 'Indent lines at the cursor one step to the right.',
    params = {
      count = {
        type = 'integer',
        description = 'How many lines to indent',
        min = 1,
        max = 20,
        default = 1,
      },
    },
    run = function(args)
      local n = math.max(1, math.floor(tonumber(args.count) or 1))
      vim.cmd('normal! ' .. n .. '>>')
      return 'indented ' .. n .. (n == 1 and ' line' or ' lines')
    end,
  },
  {
    name = 'dedent_lines',
    category = 'editing',
    description = 'Unindent lines at the cursor one step to the left.',
    params = {
      count = {
        type = 'integer',
        description = 'How many lines to unindent',
        min = 1,
        max = 20,
        default = 1,
      },
    },
    run = function(args)
      local n = math.max(1, math.floor(tonumber(args.count) or 1))
      vim.cmd('normal! ' .. n .. '<<')
      return 'unindented ' .. n .. (n == 1 and ' line' or ' lines')
    end,
  },
  {
    name = 'toggle_comment',
    category = 'editing',
    description = 'Comment the current line out, or uncomment it when it is already a comment.',
    params = {},
    run = function(_, ctx)
      local _, _, line = here(ctx)
      vim.cmd('normal gcc')
      return 'toggled comment on line ' .. line
    end,
  },
  {
    name = 'uppercase_line',
    category = 'editing',
    description = 'Turn the whole current line into UPPER CASE.',
    params = {},
    run = function(_, ctx)
      local _, b, line = here(ctx)
      vim.api.nvim_buf_set_lines(b, line - 1, line, false, { line_at(b, line):upper() })
      return 'uppercased line ' .. line
    end,
  },
  {
    name = 'lowercase_line',
    category = 'editing',
    description = 'Turn the whole current line into lower case.',
    params = {},
    run = function(_, ctx)
      local _, b, line = here(ctx)
      vim.api.nvim_buf_set_lines(b, line - 1, line, false, { line_at(b, line):lower() })
      return 'lowercased line ' .. line
    end,
  },
  {
    name = 'uppercase_word',
    category = 'editing',
    description = 'Turn the single word under the cursor into UPPER CASE.',
    params = {},
    run = function()
      vim.cmd('normal! gUiw')
      return 'uppercased the word'
    end,
  },
  {
    name = 'lowercase_word',
    category = 'editing',
    description = 'Turn the single word under the cursor into lower case.',
    params = {},
    run = function()
      vim.cmd('normal! guiw')
      return 'lowercased the word'
    end,
  },
  {
    name = 'sort_lines',
    category = 'editing',
    description = 'Sort every line of the buffer, forwards or backwards, '
      .. 'optionally dropping duplicates.',
    params = {
      order = {
        type = 'enum',
        description = 'Sort order',
        enum = {
          ascending = 'A to Z, smallest first',
          descending = 'Z to A, largest first',
        },
        default = 'ascending',
      },
      unique = { type = 'boolean', description = 'drop duplicate lines while sorting' },
    },
    run = function(args, ctx)
      local b = buf(ctx)
      local before = vim.api.nvim_buf_line_count(b)
      local command = '%sort'
      if args.order == 'descending' then
        command = command .. '!'
      end
      if args.unique == true then
        command = command .. ' u'
      end
      vim.cmd(command)
      local after = vim.api.nvim_buf_line_count(b)
      local how = (args.order == 'descending') and 'descending' or 'ascending'
      if after < before then
        return ('sorted %s, dropped %d duplicates'):format(how, before - after)
      end
      return 'sorted ' .. how
    end,
  },
  {
    name = 'reverse_lines',
    category = 'editing',
    description = 'Reverse the order of every line in the buffer, last line first.',
    params = {},
    run = function(_, ctx)
      local b = buf(ctx)
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local flipped = {}
      for i = #lines, 1, -1 do
        flipped[#flipped + 1] = lines[i]
      end
      vim.api.nvim_buf_set_lines(b, 0, -1, false, flipped)
      return 'reversed ' .. #flipped .. ' lines'
    end,
  },
  {
    name = 'trim_trailing_whitespace',
    category = 'editing',
    description = 'Strip the spaces and tabs left at the end of lines in this buffer.',
    params = {},
    run = function(_, ctx)
      local b = buf(ctx)
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local touched = 0
      for i, line in ipairs(lines) do
        local trimmed = line:gsub('[ \t]+$', '')
        if trimmed ~= line then
          lines[i] = trimmed
          touched = touched + 1
        end
      end
      if touched > 0 then
        vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
      end
      return 'trimmed ' .. touched .. (touched == 1 and ' line' or ' lines')
    end,
  },
  {
    name = 'insert_line_above',
    category = 'editing',
    description = 'Open a new empty line above the current one.',
    params = {},
    run = function(_, ctx)
      local w, b, line = here(ctx)
      vim.api.nvim_buf_set_lines(b, line - 1, line - 1, false, { '' })
      vim.api.nvim_win_set_cursor(w, { line, 0 })
      return 'blank line above ' .. line
    end,
  },
  {
    name = 'insert_line_below',
    category = 'editing',
    description = 'Open a new empty line below the current one.',
    params = {},
    run = function(_, ctx)
      local w, b, line = here(ctx)
      vim.api.nvim_buf_set_lines(b, line, line, false, { '' })
      vim.api.nvim_win_set_cursor(w, { line + 1, 0 })
      return 'blank line below ' .. line
    end,
  },

  -- =========================================================================
  -- search
  -- =========================================================================
  {
    name = 'search',
    category = 'search',
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
    name = 'search_backward',
    category = 'search',
    description = 'Search backwards from the cursor and jump to the match before it.',
    params = {
      pattern = { type = 'string', description = 'Text or pattern to look for', required = true },
    },
    readOnly = true,
    run = function(args)
      local pattern = text(args.pattern)
      if pattern == '' then
        error('no pattern given', 0)
      end
      vim.fn.setreg('/', pattern)
      vim.opt.hlsearch = true
      local line = vim.fn.search(pattern, 'bw')
      if line == 0 then
        return 'no match for ' .. pattern
      end
      return 'match on line ' .. line
    end,
  },
  {
    name = 'search_next',
    category = 'search',
    description = 'Jump to the next match of the search you already ran.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      if vim.fn.getreg('/') == '' then
        error('nothing has been searched for yet', 0)
      end
      vim.cmd('normal! n')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'search_previous',
    category = 'search',
    description = 'Jump back to the previous match of the search you already ran.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      if vim.fn.getreg('/') == '' then
        error('nothing has been searched for yet', 0)
      end
      vim.cmd('normal! N')
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'clear_search_highlight',
    category = 'search',
    description = 'Stop highlighting the search matches currently lit up.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('nohlsearch')
      return 'highlight cleared'
    end,
  },
  {
    name = 'count_matches',
    category = 'search',
    description = 'Count how many times a piece of text appears in this buffer.',
    params = {
      pattern = { type = 'string', description = 'Text to count', required = true },
    },
    readOnly = true,
    run = function(args, ctx)
      local needle = text(args.pattern)
      if needle == '' then
        error('no text given', 0)
      end
      local found = 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf(ctx), 0, -1, false)) do
        local at = 1
        while true do
          local s, e = line:find(needle, at, true)
          if not s then
            break
          end
          found = found + 1
          at = e + 1
        end
      end
      return ('%d matches for %s'):format(found, needle)
    end,
  },
  {
    name = 'replace_in_line',
    category = 'search',
    description = 'Replace one piece of text with another, on the current line only.',
    params = {
      find = { type = 'string', description = 'Text to replace', required = true },
      replacement = { type = 'string', description = 'Text to put in its place', required = true },
    },
    run = function(args, ctx)
      local find, with = text(args.find), text(args.replacement)
      if find == '' then
        error('no text to replace', 0)
      end
      local _, b, line = here(ctx)
      local before = line_at(b, line)
      local after, n = before:gsub(literal(find), literal_replacement(with))
      if n == 0 then
        return 'no match on line ' .. line
      end
      vim.api.nvim_buf_set_lines(b, line - 1, line, false, { after })
      return ('replaced %d on line %d'):format(n, line)
    end,
  },
  {
    name = 'replace_in_buffer',
    category = 'search',
    description = 'Replace every occurrence of one piece of text with another, in the whole file.',
    params = {
      find = { type = 'string', description = 'Text to replace everywhere', required = true },
      replacement = { type = 'string', description = 'Text to put in its place', required = true },
    },
    destructive = true,
    run = function(args, ctx)
      local find, with = text(args.find), text(args.replacement)
      if find == '' then
        error('no text to replace', 0)
      end
      local b = buf(ctx)
      local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      local pattern, replacement = literal(find), literal_replacement(with)
      local total, touched = 0, 0
      for i, line in ipairs(lines) do
        local after, n = line:gsub(pattern, replacement)
        if n > 0 then
          lines[i] = after
          total = total + n
          touched = touched + 1
        end
      end
      if total == 0 then
        return 'no match for ' .. find
      end
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
      return ('replaced %d on %d lines'):format(total, touched)
    end,
  },

  -- =========================================================================
  -- selection
  -- =========================================================================
  {
    name = 'select_all',
    category = 'selection',
    description = 'Select the entire buffer in visual mode.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('normal! ggVG')
      return 'selected'
    end,
  },
  {
    name = 'select_line',
    category = 'selection',
    description = 'Select the current line in visual mode.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('normal! V')
      return 'line selected'
    end,
  },
  {
    name = 'select_word',
    category = 'selection',
    description = 'Select the word under the cursor in visual mode.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('normal! viw')
      return 'word selected'
    end,
  },
  {
    name = 'select_paragraph',
    category = 'selection',
    description = 'Select the paragraph the cursor is inside, up to the blank lines around it.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('normal! vip')
      return 'paragraph selected'
    end,
  },

  -- =========================================================================
  -- clipboard
  -- =========================================================================
  {
    name = 'copy_line_to_clipboard',
    category = 'clipboard',
    description = 'Copy the current line to the system clipboard.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local _, b, line = here(ctx)
      vim.fn.setreg('+', line_at(b, line) .. '\n', 'V')
      return 'copied line ' .. line
    end,
  },
  {
    name = 'copy_selection_to_clipboard',
    category = 'clipboard',
    description = 'Copy the text you last selected to the system clipboard.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local b = buf(ctx)
      local from = vim.api.nvim_buf_get_mark(b, '<')
      local to = vim.api.nvim_buf_get_mark(b, '>')
      if from[1] == 0 or to[1] == 0 then
        error('nothing has been selected yet', 0)
      end
      local lines = vim.api.nvim_buf_get_lines(b, from[1] - 1, to[1], false)
      vim.fn.setreg('+', table.concat(lines, '\n'), 'V')
      return 'copied ' .. #lines .. (#lines == 1 and ' line' or ' lines')
    end,
  },
  {
    name = 'paste_from_clipboard',
    category = 'clipboard',
    description = 'Paste what is on the system clipboard below the cursor.',
    params = {},
    run = function(_, ctx)
      local clip = vim.fn.getreg('+')
      if clip == nil or clip == '' then
        error('the clipboard is empty', 0)
      end
      local w, b, line = here(ctx)
      local lines = vim.split(clip:gsub('\n$', ''), '\n', { plain = true })
      vim.api.nvim_buf_set_lines(b, line, line, false, lines)
      vim.api.nvim_win_set_cursor(w, { line + 1, 0 })
      return 'pasted ' .. #lines .. (#lines == 1 and ' line' or ' lines')
    end,
  },
  {
    name = 'copy_file_path',
    category = 'clipboard',
    description = "Copy this file's full path to the system clipboard.",
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local name = vim.api.nvim_buf_get_name(buf(ctx))
      if name == '' then
        error('this buffer has no file', 0)
      end
      vim.fn.setreg('+', name)
      return 'copied ' .. name
    end,
  },

  -- =========================================================================
  -- folding
  -- =========================================================================
  {
    name = 'fold_all',
    category = 'folding',
    description = 'Fold everything shut, collapsing the file to its outermost level.',
    params = {},
    run = function()
      vim.cmd('normal! zM')
      return 'folded'
    end,
  },
  {
    name = 'unfold_all',
    category = 'folding',
    description = 'Open every fold, showing the whole file again.',
    params = {},
    run = function()
      vim.cmd('normal! zR')
      return 'unfolded'
    end,
  },
  {
    name = 'toggle_fold',
    category = 'folding',
    description = 'Open or close the one fold the cursor is inside.',
    params = {},
    run = function(_, ctx)
      local _, _, line = here(ctx)
      if vim.fn.foldlevel(line) == 0 then
        error('no fold on this line', 0)
      end
      vim.cmd('normal! za')
      return vim.fn.foldclosed(line) == -1 and 'fold open' or 'fold closed'
    end,
  },
  {
    name = 'set_fold_level',
    category = 'folding',
    description = 'Show folds only from a given nesting depth: 0 closes all, higher opens more.',
    params = {
      level = {
        type = 'integer',
        description = 'Fold depth to open down to',
        required = true,
        min = 0,
        max = 9,
      },
    },
    run = function(args, ctx)
      local w = win(ctx)
      local level = math.max(0, math.min(math.floor(tonumber(args.level) or 0), 9))
      vim.wo[w].foldenable = true
      vim.wo[w].foldlevel = level
      return 'fold level ' .. level
    end,
  },

  -- =========================================================================
  -- options
  -- =========================================================================
  {
    name = 'toggle_option',
    category = 'options',
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
          cursorcolumn = 'Highlight of the column the cursor is in',
          hlsearch = 'Highlighting of every search match',
          ignorecase = 'Case-insensitive searching',
          expandtab = 'Inserting spaces instead of tab characters',
          autoindent = 'Keeping the previous indent on a new line',
        },
      },
    },
    run = function(args, ctx)
      local w = win(ctx)
      local opt = tostring(args.option or '')
      local ok, current = pcall(function()
        return vim.wo[w][opt]
      end)
      if ok then
        vim.wo[w][opt] = not current
        return opt .. ' ' .. (not current and 'on' or 'off')
      end
      -- Not window-local: the editor-wide options in the same list.
      local global_ok, value = pcall(function()
        return vim.o[opt]
      end)
      if not global_ok or type(value) ~= 'boolean' then
        error('unknown option: ' .. opt, 0)
      end
      vim.o[opt] = not value
      return opt .. ' ' .. (not value and 'on' or 'off')
    end,
  },
  {
    name = 'set_tab_width',
    category = 'options',
    description = 'Set how many columns wide a tab looks in this buffer.',
    params = {
      width = {
        type = 'integer',
        description = 'Tab width in columns',
        required = true,
        min = 1,
        max = 8,
      },
    },
    run = function(args, ctx)
      local b = buf(ctx)
      local n = math.max(1, math.min(math.floor(tonumber(args.width) or 4), 8))
      vim.bo[b].tabstop = n
      vim.bo[b].softtabstop = n
      return 'tab width ' .. n
    end,
  },
  {
    name = 'set_shiftwidth',
    category = 'options',
    description = 'Set how many columns one indent step adds in this buffer.',
    params = {
      width = {
        type = 'integer',
        description = 'Indent step in columns',
        required = true,
        min = 1,
        max = 8,
      },
    },
    run = function(args, ctx)
      local b = buf(ctx)
      local n = math.max(1, math.min(math.floor(tonumber(args.width) or 4), 8))
      vim.bo[b].shiftwidth = n
      return 'shiftwidth ' .. n
    end,
  },
  {
    name = 'set_colorscheme',
    category = 'options',
    description = 'Switch to an installed colorscheme by name.',
    params = {
      name = { type = 'string', description = 'Name of the colorscheme', required = true },
    },
    run = function(args)
      local name = text(args.name)
      if name == '' then
        error('no colorscheme given', 0)
      end
      if not vim.tbl_contains(vim.fn.getcompletion('', 'color'), name) then
        error('no colorscheme named ' .. name, 0)
      end
      vim.cmd.colorscheme(name)
      return 'colorscheme ' .. name
    end,
  },
  {
    name = 'set_background',
    category = 'options',
    description = 'Tell Neovim the background is dark or light, so colors suit it.',
    params = {
      mode = {
        type = 'enum',
        description = 'Which background to assume',
        required = true,
        enum = { dark = 'A dark background', light = 'A light background' },
      },
    },
    run = function(args)
      local mode = text(args.mode)
      if mode ~= 'dark' and mode ~= 'light' then
        error('background is dark or light', 0)
      end
      vim.o.background = mode
      return 'background ' .. mode
    end,
  },

  -- =========================================================================
  -- lsp
  -- =========================================================================
  {
    name = 'lsp_definition',
    category = 'lsp',
    description = 'Jump to where the symbol under the cursor is defined.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.definition()
      return 'asked for the definition'
    end,
  },
  {
    name = 'lsp_type_definition',
    category = 'lsp',
    description = "Jump to where the type of the symbol under the cursor is defined.",
    params = {},
    readOnly = true,
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.type_definition()
      return 'asked for the type definition'
    end,
  },
  {
    name = 'lsp_implementation',
    category = 'lsp',
    description = 'Jump to the implementations of the interface or method under the cursor.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.implementation()
      return 'asked for implementations'
    end,
  },
  {
    name = 'lsp_references',
    category = 'lsp',
    description = 'List everywhere the symbol under the cursor is used.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.references()
      return 'asked for references'
    end,
  },
  {
    name = 'lsp_hover',
    category = 'lsp',
    description = 'Show the documentation and type of the symbol under the cursor.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.hover()
      return 'asked for hover docs'
    end,
  },
  {
    name = 'lsp_signature_help',
    category = 'lsp',
    description = 'Show the parameters of the function call the cursor is inside.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.signature_help()
      return 'asked for signature help'
    end,
  },
  {
    name = 'lsp_rename',
    category = 'lsp',
    description = 'Rename the symbol under the cursor everywhere the language server knows of.',
    params = {
      name = { type = 'string', description = 'The new name for the symbol', required = true },
    },
    destructive = true,
    run = function(args, ctx)
      local name = text(args.name)
      if name == '' then
        error('no new name given', 0)
      end
      lsp_clients(buf(ctx))
      vim.lsp.buf.rename(name)
      return 'renaming to ' .. name
    end,
  },
  {
    name = 'lsp_code_action',
    category = 'lsp',
    description = 'Offer the language server fixes and refactors available here.',
    params = {},
    run = function(_, ctx)
      lsp_clients(buf(ctx))
      vim.lsp.buf.code_action()
      return 'asked for code actions'
    end,
  },
  {
    name = 'format_buffer',
    category = 'lsp',
    description = 'Reformat the whole buffer with the attached language server.',
    params = {},
    run = function()
      vim.lsp.buf.format({ async = false })
      return 'formatted'
    end,
  },
  {
    name = 'lsp_restart',
    category = 'lsp',
    description = 'Stop the language servers on this buffer and let them attach again.',
    params = {},
    run = function(_, ctx)
      local b = buf(ctx)
      local clients = lsp_clients(b)
      for _, client in ipairs(clients) do
        client:stop()
      end
      vim.cmd('edit')
      return 'restarting ' .. #clients .. ' server(s)'
    end,
  },
  {
    name = 'lsp_info',
    category = 'lsp',
    description = 'Say which language servers are attached to this buffer.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local clients = vim.lsp.get_clients({ bufnr = buf(ctx) })
      if #clients == 0 then
        return 'no language server attached'
      end
      local names = {}
      for _, client in ipairs(clients) do
        names[#names + 1] = client.name
      end
      return table.concat(names, ', ')
    end,
  },

  -- =========================================================================
  -- diagnostics
  -- =========================================================================
  {
    name = 'show_diagnostics',
    category = 'diagnostics',
    description = 'Collect the diagnostics for this buffer into the quickfix list and open it.',
    params = {},
    readOnly = true,
    run = function()
      vim.diagnostic.setqflist({ open = true })
      return 'diagnostics in quickfix'
    end,
  },
  {
    name = 'next_diagnostic',
    category = 'diagnostics',
    description = 'Jump to the next error or warning below the cursor.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      diagnostic_jump(1)
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'previous_diagnostic',
    category = 'diagnostics',
    description = 'Jump back to the error or warning above the cursor.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      diagnostic_jump(-1)
      return 'line ' .. vim.api.nvim_win_get_cursor(win(ctx))[1]
    end,
  },
  {
    name = 'show_line_diagnostics',
    category = 'diagnostics',
    description = 'Show the full message of the errors on the current line, in a float.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local _, b, line = here(ctx)
      local found = vim.diagnostic.get(b, { lnum = line - 1 })
      if #found == 0 then
        return 'nothing wrong on line ' .. line
      end
      vim.diagnostic.open_float()
      return #found .. ' on line ' .. line
    end,
  },
  {
    name = 'toggle_virtual_text',
    category = 'diagnostics',
    description = 'Show or hide the diagnostic messages printed beside the code.',
    params = {},
    run = function()
      local current = vim.diagnostic.config() or {}
      local on = current.virtual_text ~= false and current.virtual_text ~= nil
      vim.diagnostic.config({ virtual_text = not on and true or false })
      return 'virtual text ' .. (not on and 'on' or 'off')
    end,
  },

  -- =========================================================================
  -- quickfix
  -- =========================================================================
  {
    name = 'quickfix_open',
    category = 'quickfix',
    description = 'Open the quickfix window with the current result list.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('copen')
      return quickfix_size() .. ' entries'
    end,
  },
  {
    name = 'quickfix_close',
    category = 'quickfix',
    description = 'Close the quickfix window.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('cclose')
      return 'quickfix closed'
    end,
  },
  {
    name = 'quickfix_next',
    category = 'quickfix',
    description = 'Go to the next entry in the quickfix list.',
    params = {},
    readOnly = true,
    run = function()
      if quickfix_size() == 0 then
        error('the quickfix list is empty', 0)
      end
      vim.cmd('cnext')
      return 'quickfix ' .. (vim.fn.getqflist({ idx = 0 }).idx or 0)
    end,
  },
  {
    name = 'quickfix_previous',
    category = 'quickfix',
    description = 'Go back to the previous entry in the quickfix list.',
    params = {},
    readOnly = true,
    run = function()
      if quickfix_size() == 0 then
        error('the quickfix list is empty', 0)
      end
      vim.cmd('cprevious')
      return 'quickfix ' .. (vim.fn.getqflist({ idx = 0 }).idx or 0)
    end,
  },
  {
    name = 'loclist_open',
    category = 'quickfix',
    description = "Open the location list, this window's own result list.",
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local w = win(ctx)
      if loclist_size(w) == 0 then
        error('the location list is empty', 0)
      end
      vim.cmd('lopen')
      return loclist_size(w) .. ' entries'
    end,
  },
  {
    name = 'loclist_close',
    category = 'quickfix',
    description = 'Close the location list window.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('lclose')
      return 'location list closed'
    end,
  },
  {
    name = 'loclist_next',
    category = 'quickfix',
    description = 'Go to the next entry in the location list.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      if loclist_size(win(ctx)) == 0 then
        error('the location list is empty', 0)
      end
      vim.cmd('lnext')
      return 'location ' .. (vim.fn.getloclist(win(ctx), { idx = 0 }).idx or 0)
    end,
  },
  {
    name = 'loclist_previous',
    category = 'quickfix',
    description = 'Go back to the previous entry in the location list.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      if loclist_size(win(ctx)) == 0 then
        error('the location list is empty', 0)
      end
      vim.cmd('lprevious')
      return 'location ' .. (vim.fn.getloclist(win(ctx), { idx = 0 }).idx or 0)
    end,
  },

  -- =========================================================================
  -- terminal
  -- =========================================================================
  {
    name = 'open_terminal',
    category = 'terminal',
    description = 'Open a shell in a terminal buffer, in a split or a new tab.',
    params = {
      where = {
        type = 'enum',
        description = 'Where to put the terminal',
        enum = {
          split = 'In a window below this one',
          vsplit = 'In a window beside this one',
          tab = 'In a tab page of its own',
        },
        default = 'split',
      },
    },
    run = function(args)
      local where = text(args.where)
      if where == 'tab' then
        vim.cmd('tabnew')
      elseif where == 'vsplit' then
        vim.cmd('vsplit')
      else
        vim.cmd('split')
      end
      vim.cmd('terminal')
      return 'terminal in a ' .. (where ~= '' and where or 'split')
    end,
  },
  {
    name = 'close_terminal',
    category = 'terminal',
    description = 'Close the terminal in this window and end the shell running in it.',
    params = {},
    destructive = true,
    run = function(_, ctx)
      local b = buf(ctx)
      if vim.bo[b].buftype ~= 'terminal' then
        error('this window is not a terminal', 0)
      end
      vim.api.nvim_buf_delete(b, { force = true })
      return 'terminal closed'
    end,
  },

  -- =========================================================================
  -- help
  -- =========================================================================
  {
    name = 'help_topic',
    category = 'help',
    description = 'Open the built-in help for a topic, command or option.',
    params = {
      topic = { type = 'string', description = 'Help topic to look up', required = true },
    },
    readOnly = true,
    run = function(args)
      local topic = text(args.topic)
      if topic == '' then
        error('no topic given', 0)
      end
      if #vim.fn.getcompletion(topic, 'help') == 0 then
        error('no help for ' .. topic, 0)
      end
      vim.cmd('help ' .. vim.fn.fnameescape(topic))
      return 'help for ' .. topic
    end,
  },
  {
    name = 'show_messages',
    category = 'help',
    description = 'Show the recent messages Neovim printed, the :messages history.',
    params = {},
    readOnly = true,
    run = function()
      local history = vim.split(vim.fn.execute('messages'), '\n', { plain = true })
      for i = #history, 1, -1 do
        if vim.trim(history[i]) ~= '' then
          return 'last message: ' .. history[i]
        end
      end
      return 'no messages'
    end,
  },
  {
    name = 'show_version',
    category = 'help',
    description = 'Say which version of Neovim this is.',
    params = {},
    readOnly = true,
    run = function()
      local v = vim.version()
      return ('nvim %d.%d.%d'):format(v.major, v.minor, v.patch)
    end,
  },

  -- =========================================================================
  -- spelling
  -- =========================================================================
  {
    name = 'next_misspelling',
    category = 'spelling',
    description = 'Jump to the next word the spell checker flags.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local w = win(ctx)
      if not vim.wo[w].spell then
        error('spell checking is off', 0)
      end
      vim.cmd('normal! ]s')
      return vim.fn.expand('<cword>')
    end,
  },
  {
    name = 'previous_misspelling',
    category = 'spelling',
    description = 'Jump back to the previous word the spell checker flags.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local w = win(ctx)
      if not vim.wo[w].spell then
        error('spell checking is off', 0)
      end
      vim.cmd('normal! [s')
      return vim.fn.expand('<cword>')
    end,
  },
  {
    name = 'spell_suggest',
    category = 'spelling',
    description = 'Suggest correct spellings for the word under the cursor.',
    params = {},
    readOnly = true,
    run = function()
      local word = vim.fn.expand('<cword>')
      if word == '' then
        error('no word under the cursor', 0)
      end
      local suggestions = vim.fn.spellsuggest(word, 5)
      if #suggestions == 0 then
        return 'no suggestions for ' .. word
      end
      return word .. ' → ' .. table.concat(suggestions, ', ')
    end,
  },
  {
    name = 'spell_add_word',
    category = 'spelling',
    description = 'Teach the spell checker the word under the cursor is spelled right.',
    params = {},
    run = function(_, ctx)
      if not vim.wo[win(ctx)].spell then
        error('spell checking is off', 0)
      end
      local word = vim.fn.expand('<cword>')
      if word == '' then
        error('no word under the cursor', 0)
      end
      vim.cmd('normal! zg')
      return 'added ' .. word
    end,
  },

  -- =========================================================================
  -- misc
  -- =========================================================================
  {
    name = 'quit_all',
    category = 'misc',
    description = 'Quit Neovim entirely, closing every window and tab.',
    params = {},
    destructive = true,
    run = function()
      vim.cmd('quitall')
    end,
  },
  {
    name = 'reload_config',
    category = 'misc',
    description = 'Re-read your init file, applying config changes without restarting.',
    params = {},
    destructive = true,
    run = function()
      local rc = vim.fn.expand('$MYVIMRC')
      if rc == '' or rc == '$MYVIMRC' or vim.fn.filereadable(rc) == 0 then
        error('no init file to reload', 0)
      end
      vim.cmd('source ' .. vim.fn.fnameescape(rc))
      return 'sourced ' .. vim.fn.fnamemodify(rc, ':t')
    end,
  },
  {
    name = 'redraw',
    category = 'misc',
    description = 'Redraw the screen, clearing whatever garbled it.',
    params = {},
    readOnly = true,
    run = function()
      vim.cmd('redraw!')
      return 'redrawn'
    end,
  },
  {
    name = 'show_cursor_position',
    category = 'misc',
    description = 'Say which line and column the cursor is on, and how long the file is.',
    params = {},
    readOnly = true,
    run = function(_, ctx)
      local w, b, line = here(ctx)
      local col = vim.api.nvim_win_get_cursor(w)[2] + 1
      return ('line %d, column %d of %d lines'):format(line, col, vim.api.nvim_buf_line_count(b))
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

--- The catalog grouped by `category`, categories in the order they first appear
--- in the file and actions in catalog order. Used by |:JevActions| and by the
--- README generator (`scripts/gen_actions_md.lua`).
---@return { name: string, actions: JevAction[] }[]
function M.categories()
  local groups, seen = {}, {}
  for _, action in ipairs(catalog) do
    local name = action.category or 'misc'
    local group = seen[name]
    if not group then
      group = { name = name, actions = {} }
      seen[name] = group
      groups[#groups + 1] = group
    end
    group.actions[#group.actions + 1] = action
  end
  return groups
end

return M
