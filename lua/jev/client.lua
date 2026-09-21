---@brief Async POST to TypeSafe's System One endpoint, via `curl` and |vim.system()|.
---
--- No retries: a panel that drops a request is better than one that queues them.
--- `M.post` is a plain module field so tests can swap in a fake.

local uv = vim.uv or vim.loop

local M = {}

--- Human-readable first halves of the error string, by HTTP status.
local REASONS = {
  [400] = 'TypeSafe rejected the request.',
  [401] = 'TypeSafe did not accept that API key.',
  [403] = 'TypeSafe refused that API key.',
  [404] = 'TypeSafe has no such endpoint.',
  [422] = 'TypeSafe rejected the questions.',
  [429] = 'Rate limited by TypeSafe. Slow down for a moment.',
  [529] = 'TypeSafe is overloaded. Try again shortly.',
}

--- Split curl's `-w "\n%{http_code}"` tail off the response body.
---@param stdout string
---@return string body, integer|nil status
local function split_status(stdout)
  stdout = stdout or ''
  local head, tail = stdout:match('^(.*)\n([^\n]*)$')
  if not head then
    return '', tonumber((stdout:gsub('%s+$', '')))
  end
  return head, tonumber((tail:gsub('%s+$', '')))
end

--- Pull a readable `detail` out of an error body, whatever shape it took.
---@param decoded any
---@return string
local function detail_of(decoded)
  if type(decoded) ~= 'table' then
    return ''
  end
  local detail = decoded.detail
  if type(detail) == 'string' then
    return detail
  end
  if type(detail) == 'table' then
    local kind = detail.error_type or detail.message
    if type(kind) == 'string' then
      return kind
    end
  end
  if type(decoded.error) == 'table' and type(decoded.error.message) == 'string' then
    return decoded.error.message
  end
  if type(decoded.message) == 'string' then
    return decoded.message
  end
  return ''
end

--- Trim to one line so it fits a narrow panel.
---@param s string
---@param n integer|nil
---@return string
local function oneline(s, n)
  s = tostring(s or ''):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  n = n or 200
  if #s > n then
    s = s:sub(1, n) .. '…'
  end
  return s
end

--- POST `body` and call `cb(err, resp, ms)` on the main loop.
---@param opts table  {api_key, url, timeout_ms}
---@param body table  {state, model, questions}
---@param cb fun(err: string|nil, resp: table|nil, ms: number)
function M.post(opts, body, cb)
  opts = opts or {}
  local url = opts.url or require('jev.config').defaults.url
  local timeout_ms = tonumber(opts.timeout_ms) or 15000
  local started = uv.hrtime()

  local function finish(err, resp)
    local ms = (uv.hrtime() - started) / 1e6
    vim.schedule(function()
      cb(err, resp, ms)
    end)
  end

  local ok_encode, payload = pcall(vim.json.encode, body)
  if not ok_encode then
    finish('could not encode the request: ' .. oneline(payload))
    return
  end

  local args = {
    'curl',
    '-sS',
    '-X',
    'POST',
    '-m',
    tostring(math.max(1, math.floor(timeout_ms / 1000))),
    '-H',
    'Content-Type: application/json',
    '-H',
    'Accept: application/json',
    '--data-binary',
    '@-',
    '-w',
    '\n%{http_code}',
  }
  if opts.api_key and opts.api_key ~= '' then
    table.insert(args, '-H')
    table.insert(args, 'Authorization: Bearer ' .. opts.api_key)
  end
  table.insert(args, url)

  -- vim.system() raises synchronously when curl is not on PATH.
  local ok_spawn, spawn_err = pcall(vim.system, args, {
    text = true,
    stdin = payload,
    timeout = timeout_ms,
  }, function(obj)
    if obj.code ~= 0 then
      if obj.signal and obj.signal ~= 0 or obj.code == 124 then
        finish(string.format('request timed out after %dms', timeout_ms))
      else
        finish(string.format('curl exited %d: %s', obj.code, oneline(obj.stderr)))
      end
      return
    end

    local raw, status = split_status(obj.stdout)
    local ok_decode, decoded = pcall(vim.json.decode, raw)

    if not status or status < 200 or status >= 300 then
      local reason = REASONS[status] or string.format('TypeSafe returned %s.', tostring(status))
      local detail = ok_decode and detail_of(decoded) or ''
      if detail == '' then
        detail = oneline(raw, 120)
      end
      finish(detail ~= '' and (reason .. ' ' .. detail) or reason)
      return
    end

    if not ok_decode or type(decoded) ~= 'table' then
      finish('invalid JSON from TypeSafe: ' .. oneline(raw, 120))
      return
    end

    finish(nil, decoded)
  end)

  if not ok_spawn then
    local msg = oneline(spawn_err)
    if msg:find('ENOENT', 1, true) then
      msg = 'curl not found on PATH'
    end
    finish('could not start curl: ' .. msg)
  end
end

-- Exposed for tests.
M._split_status = split_status
M._detail_of = detail_of

return M
