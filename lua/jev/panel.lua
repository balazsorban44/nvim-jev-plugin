---@brief The prompt-buffer side panel.
---
--- One `buftype=prompt` buffer holds the whole transcript: what you asked, what Jev
--- picked, and what happened. Output lines are inserted just above the trailing
--- prompt line so the prompt always stays last. `bufhidden=hide` keeps the history
--- across toggles.

local config = require('jev.config')

local M = {}

M._state = {
  win = nil, ---@type integer|nil
  buf = nil, ---@type integer|nil
  target_win = nil, ---@type integer|nil
  target_buf = nil, ---@type integer|nil
}

local ns = vim.api.nvim_create_namespace('jev_panel')

---@return boolean
local function buf_ok()
  return M._state.buf ~= nil and vim.api.nvim_buf_is_valid(M._state.buf)
end

---@return boolean
function M.is_open()
  return M._state.win ~= nil and vim.api.nvim_win_is_valid(M._state.win)
end

--- The transcript buffer, created on first use so output survives a closed panel.
---@return integer
function M.buf()
  if buf_ok() then
    return M._state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'prompt'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'jev'
  vim.fn.prompt_setprompt(buf, config.get().prompt)
  vim.fn.prompt_setcallback(buf, function(text)
    require('jev').ask(text)
  end)
  M._state.buf = buf
  return buf
end

--- Remember where the user came from and open the panel on the right.
function M.open()
  local current = vim.api.nvim_get_current_win()
  if not M.is_open() or current ~= M._state.win then
    if current ~= M._state.win then
      M._state.target_win = current
      M._state.target_buf = vim.api.nvim_win_get_buf(current)
    end
  end

  if M.is_open() then
    vim.api.nvim_set_current_win(M._state.win)
    return M._state.win
  end

  local cfg = config.get()
  local buf = M.buf()
  vim.cmd('botright vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, cfg.width)
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  M._state.win = win
  M.scroll()
  return win
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(M._state.win, true)
  end
  M._state.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- The window an action should run in: what the user came from, else the first
--- ordinary non-panel window, else whatever is current.
---@return integer target_win, integer target_buf
function M.target()
  local remembered = M._state.target_win
  if
    remembered
    and remembered ~= M._state.win
    and vim.api.nvim_win_is_valid(remembered)
  then
    return remembered, vim.api.nvim_win_get_buf(remembered)
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= M._state.win and vim.api.nvim_win_get_config(win).relative == '' then
      M._state.target_win = win
      M._state.target_buf = vim.api.nvim_win_get_buf(win)
      return win, M._state.target_buf
    end
  end
  local win = vim.api.nvim_get_current_win()
  return win, vim.api.nvim_win_get_buf(win)
end

--- Keep the prompt line in view.
function M.scroll()
  if not M.is_open() or not buf_ok() then
    return
  end
  local count = vim.api.nvim_buf_line_count(M._state.buf)
  pcall(vim.api.nvim_win_set_cursor, M._state.win, { count, 0 })
end

---@param lines string|string[]
---@return string[]
local function as_lines(lines)
  if type(lines) == 'string' then
    return vim.split(lines, '\n', { plain = true })
  end
  return lines or {}
end

--- Insert output lines above the trailing prompt line.
---@param lines string|string[]
---@return integer row  0-based row of the first inserted line
function M.print(lines)
  local buf = M.buf()
  lines = as_lines(lines)
  if #lines == 0 then
    return vim.api.nvim_buf_line_count(buf) - 1
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local row = math.max(last - 1, 0)
  vim.api.nvim_buf_set_lines(buf, row, row, false, lines)
  M.scroll()
  return row
end

--- Print a placeholder line and return a handle for |jev.panel.resolve()|.
---@param text string
---@return integer handle
function M.pending(text)
  local buf = M.buf()
  local row = M.print(text)
  return vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {})
end

--- Replace the line a |jev.panel.pending()| handle marks.
---@param handle integer|nil
---@param lines string|string[]
function M.resolve(handle, lines)
  local buf = M.buf()
  lines = as_lines(lines)
  if not handle then
    M.print(lines)
    return
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, handle, {})
  vim.api.nvim_buf_del_extmark(buf, ns, handle)
  if not mark or not mark[1] then
    M.print(lines)
    return
  end
  local row = mark[1]
  if row >= vim.api.nvim_buf_line_count(buf) then
    M.print(lines)
    return
  end
  vim.api.nvim_buf_set_lines(buf, row, row + 1, false, lines)
  M.scroll()
end

--- The transcript, for tests and for `:JevAsk` debugging.
---@return string[]
function M.lines()
  if not buf_ok() then
    return {}
  end
  return vim.api.nvim_buf_get_lines(M._state.buf, 0, -1, false)
end

--- Drop the transcript and start over.
function M.clear()
  if not buf_ok() then
    return
  end
  vim.api.nvim_buf_clear_namespace(M._state.buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(M._state.buf, 0, -1, false, { vim.fn.prompt_getprompt(M._state.buf) })
  M.scroll()
end

return M
