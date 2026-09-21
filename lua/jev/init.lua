---@brief jev.nvim — ask for an editor action in plain words.
---
--- The whole flow lives in |jev.ask()|: build typed questions from the action
--- catalog, send them to Jev in one request, decode the answers into a call,
--- apply the policy, run it in the window you came from.
---
--- Jev is not an LLM. It never writes text; it only picks from the options we
--- hand it. Nothing here generates anything.

local config = require('jev.config')
local panel = require('jev.panel')

local M = {}

--- Bumped per request; a stale response is dropped rather than shown.
M._seq = 0

---@param s any
---@param n integer|nil
---@return string
local function oneline(s, n)
  s = tostring(s or ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  n = n or 160
  if #s > n then
    s = s:sub(1, n) .. '…'
  end
  return s
end

---@param p number|nil
---@return integer
local function pct(p)
  return math.floor((tonumber(p) or 0) * 100 + 0.5)
end

--- `{direction=vertical, line=40}`, keys sorted so the line is stable.
---@param args table|nil
---@return string
local function format_args(args)
  if type(args) ~= 'table' then
    return ''
  end
  local keys = {}
  for k in pairs(args) do
    keys[#keys + 1] = tostring(k)
  end
  if #keys == 0 then
    return ''
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = args[k]
    if type(v) == 'table' then
      v = table.concat(vim.tbl_map(tostring, v), '|')
    end
    parts[#parts + 1] = string.format('%s=%s', k, tostring(v))
  end
  return '{' .. table.concat(parts, ', ') .. '}'
end

---@param decoded table
---@return string
local function format_call(decoded)
  local args = format_args(decoded.args)
  return decoded.name .. (args ~= '' and (' ' .. args) or '')
end

--- The runner-up route, for the "no confident match" line. Prefers whatever the
--- decoder exposed; falls back to reading the route answer itself.
---@param decoded table
---@param answers table|nil
---@return string|nil name, number probability
local function best_route(decoded, answers)
  if type(decoded.routes) == 'table' then
    for _, route in ipairs(decoded.routes) do
      local name = route.value or route.name
      if type(name) == 'string' and name ~= '__none__' then
        return name, tonumber(route.probability) or 0
      end
    end
  end
  local route = answers and answers['__tool__']
  if type(route) ~= 'table' or type(route.probabilities) ~= 'table' then
    return nil, 0
  end
  local best, best_p = nil, -1
  for name, p in pairs(route.probabilities) do
    p = tonumber(p) or 0
    if name ~= '__none__' and p > best_p then
      best, best_p = name, p
    end
  end
  return best, math.max(best_p, 0)
end

--- Run the decoded call in the target window. Never throws at the user.
---@param decoded table
local function execute(decoded)
  local target_win, target_buf = panel.target()
  if not vim.api.nvim_win_is_valid(target_win) then
    panel.print('  error: no window to act on')
    return
  end
  local ctx = { target_win = target_win, target_buf = target_buf }
  local ok, result = pcall(function()
    local out
    vim.api.nvim_win_call(target_win, function()
      out = decoded.action.run(decoded.args or {}, ctx)
    end)
    return out
  end)
  if not ok then
    panel.print('  error: ' .. oneline(result))
  elseif type(result) == 'string' and result ~= '' then
    panel.print('  ok: ' .. oneline(result))
  else
    panel.print('  ok')
  end
end

---@param decoded table
---@param tier string
local function apply(decoded, tier)
  local cfg = config.get()
  if tier == 'confirm' or cfg.always_confirm then
    local prompt = string.format('Run %s?', format_call(decoded))
    vim.ui.select({ 'Run', 'Cancel' }, { prompt = prompt }, function(choice)
      if choice == 'Run' then
        execute(decoded)
      else
        panel.print('  cancelled')
      end
    end)
    return
  end
  execute(decoded)
end

--- Ask Jev for an action and carry it out.
---@param text string|nil
function M.ask(text)
  text = vim.trim(tostring(text or ''))
  if text == '' then
    return
  end

  local cfg = config.get()
  panel.print('you: ' .. text)

  local key = config.api_key()
  if not key then
    panel.print('  error: no API key — set api_key in setup() or export TYPESAFE_API_KEY')
    return
  end

  local actions = require('jev.actions')
  local ok_build, built = pcall(function()
    return require('jev.questions').build(actions.list(), text)
  end)
  if not ok_build or type(built) ~= 'table' or type(built.questions) ~= 'table' then
    panel.print('  error: could not build questions: ' .. oneline(built))
    return
  end

  M._seq = M._seq + 1
  local seq = M._seq
  local handle = panel.pending('  …')

  require('jev.client').post({
    api_key = key,
    url = cfg.url,
    timeout_ms = cfg.timeout_ms,
  }, {
    state = text,
    model = cfg.model,
    questions = built.questions,
  }, function(err, resp, ms)
    if seq ~= M._seq then
      -- Superseded by a newer question.
      panel.resolve(handle, {})
      return
    end
    if err then
      panel.resolve(handle, '  error: ' .. oneline(err))
      return
    end

    local answers = (type(resp) == 'table' and type(resp.answers) == 'table') and resp.answers or {}
    local ok_decode, decoded = pcall(function()
      return require('jev.decode').decode(actions.list(), answers, built.meta)
    end)
    if not ok_decode or type(decoded) ~= 'table' then
      panel.resolve(handle, '  error: could not decode the answer: ' .. oneline(decoded))
      return
    end

    local ok_policy, tier = pcall(function()
      return require('jev.policy').decide(decoded, { thresholds = cfg.thresholds })
    end)
    if not ok_policy then
      panel.resolve(handle, '  error: could not apply the policy: ' .. oneline(tier))
      return
    end

    if tier == 'none' or not decoded.name then
      local name, p = best_route(decoded, answers)
      if name then
        panel.resolve(
          handle,
          string.format('? no confident match (best: %s %d%%)', name, pct(p))
        )
      else
        panel.resolve(handle, '? no confident match')
      end
      return
    end

    if tier == 'incomplete' then
      local missing = decoded.missing or {}
      panel.resolve(handle, '? missing: ' .. table.concat(missing, ', '))
      return
    end

    decoded.action = decoded.action or actions.by_name(decoded.name)
    if not decoded.action or type(decoded.action.run) ~= 'function' then
      panel.resolve(handle, '  error: unknown action: ' .. tostring(decoded.name))
      return
    end

    panel.resolve(
      handle,
      string.format(
        '→ %s  %d%% · %dms',
        format_call(decoded),
        pct(decoded.confidence),
        math.floor((tonumber(ms) or 0) + 0.5)
      )
    )
    apply(decoded, tier)
  end)
end

---@param opts table|nil
---@return JevConfig
function M.setup(opts)
  return config.setup(opts)
end

function M.open()
  panel.open()
end

function M.close()
  panel.close()
end

function M.toggle()
  panel.toggle()
end

-- Re-exported so `require('jev').panel.lines()` works in tests and mappings.
M.panel = panel
M.config = config

-- Exposed for tests.
M._format_args = format_args
M._best_route = best_route

return M
