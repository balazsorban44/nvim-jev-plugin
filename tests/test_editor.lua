-- Editor-side tests: the action catalog, the panel, and the ask() flow with a
-- fake client. No network, no API key, no Jev.
--
-- Agent A owns jev.questions / jev.decode / jev.policy. When they are not in the
-- tree yet (or cannot answer a smoke call), this file installs tiny stand-ins
-- that follow the same contract, so the editor side stays testable on its own.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local NOT_STATED = '(not stated)'
local ROUTE = '__tool__'
local NONE = '__none__'

-- ---------------------------------------------------------------------------
-- Stand-ins for the core modules, used only when the real ones are missing.
-- ---------------------------------------------------------------------------

local fake_questions = {
  build = function(actions, utterance)
    local questions, meta = {}, { utterance = utterance, params = {} }
    local criteria = {}
    for _, action in ipairs(actions) do
      criteria[action.name] = action.description
    end
    criteria[NONE] = 'None of these: the request is conversation, unclear, or unfinished.'
    questions[ROUTE] = {
      type = 'choice',
      instructions = "Which action does the user's request call for?",
      criteria = criteria,
    }
    for _, action in ipairs(actions) do
      for name, param in pairs(action.params or {}) do
        local qid = action.name .. '::' .. name
        meta.params[qid] = { action = action.name, param = name, kind = param.type }
        if param.type == 'boolean' then
          questions[qid] = { type = 'noul', instructions = qid }
        else
          local crit = {}
          if param.type == 'enum' then
            for value in pairs(param.enum or {}) do
              crit[value] = vim.NIL
            end
          else
            crit[NOT_STATED] = 'The request does not say this.'
          end
          questions[qid] = { type = 'choice', instructions = qid, criteria = crit }
          if not param.required then
            questions[qid .. '?'] = { type = 'noul', instructions = qid .. '?' }
          end
        end
      end
    end
    return { questions = questions, meta = meta }
  end,
}

local fake_decode = {
  decode = function(actions, answers, _meta)
    answers = answers or {}
    local route = answers[ROUTE] or {}
    local choice = route.choice
    local probabilities = route.probabilities or {}
    local route_probability = tonumber(probabilities[choice]) or 0

    local action
    for _, candidate in ipairs(actions) do
      if candidate.name == choice then
        action = candidate
      end
    end
    if not action or choice == NONE then
      return {
        name = nil,
        action = nil,
        args = {},
        missing = {},
        routeProbability = route_probability,
        confidence = route_probability,
        details = {},
      }
    end

    local args, missing, details = {}, {}, {}
    local confidence = route_probability
    local names = vim.tbl_keys(action.params or {})
    table.sort(names)
    for _, name in ipairs(names) do
      local param = action.params[name]
      local qid = action.name .. '::' .. name
      local answer = answers[qid]
      local stated_answer = answers[qid .. '?']
      local stated = stated_answer and (tonumber(stated_answer.noul) or 0) or 1

      if param.type == 'boolean' then
        local noul = answer and (tonumber(answer.noul) or 0) or 0
        local probability = math.max(noul, 1 - noul)
        if noul >= 0.5 or param.required then
          args[name] = noul >= 0.5
        end
        details[name] = { value = args[name], probability = probability }
        confidence = math.min(confidence, probability)
      elseif not answer then
        if param.required then
          missing[#missing + 1] = name
        end
      elseif stated < 0.5 then
        confidence = math.min(confidence, 1 - stated)
      elseif answer.choice == NOT_STATED then
        local probability = (answer.probabilities or {})[NOT_STATED] or 0
        if param.required then
          missing[#missing + 1] = name
        end
        confidence = math.min(confidence, probability)
      else
        local value = answer.choice
        if param.type == 'integer' then
          value = tonumber(value)
        end
        local picked = tonumber((answer.probabilities or {})[answer.choice]) or 0
        local probability = math.min(stated, picked)
        args[name] = value
        details[name] = { value = value, probability = probability, stated = stated >= 0.5 }
        confidence = math.min(confidence, probability)
      end
    end

    return {
      name = action.name,
      action = action,
      args = args,
      missing = missing,
      routeProbability = route_probability,
      confidence = confidence,
      details = details,
    }
  end,
}

local fake_policy = {
  decide = function(decoded, opts)
    local thresholds = (opts and opts.thresholds) or { route = 0.5, auto = 0.8, confirm = 0.6 }
    if not decoded or not decoded.name or (decoded.routeProbability or 0) < thresholds.route then
      return 'none'
    end
    if #(decoded.missing or {}) > 0 then
      return 'incomplete'
    end
    local action = decoded.action
    if action and action.destructive then
      return 'confirm'
    end
    if action and action.readOnly and (decoded.confidence or 0) >= thresholds.auto then
      return 'auto'
    end
    return (decoded.confidence or 0) >= thresholds.confirm and 'ready' or 'confirm'
  end,
}

--- Load the real module, or fall back to the stand-in.
---@param name string
---@return any|nil
local function real(name)
  local loaded, mod = pcall(require, name)
  if loaded and type(mod) == 'table' then
    return mod
  end
  return nil
end

local actions = require('jev.actions')

local core_ready = (function()
  local questions, decode = real('jev.questions'), real('jev.decode')
  if not questions or not decode or type(questions.build) ~= 'function' then
    return false
  end
  -- Smoke test: a half-finished core must not fail the editor tests.
  local built_ok, built = pcall(questions.build, actions.list(), 'split the window vertically')
  return built_ok and type(built) == 'table' and type(built.questions) == 'table'
end)()

local using = { core = core_ready and 'real' or 'stub', policy = 'real' }
if not core_ready then
  package.loaded['jev.questions'] = fake_questions
  package.loaded['jev.decode'] = fake_decode
end
if not real('jev.policy') or type(require('jev.policy').decide) ~= 'function' then
  package.loaded['jev.policy'] = fake_policy
  using.policy = 'stub'
end
print(string.format('     (questions/decode: %s, policy: %s)', using.core, using.policy))

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local jev = require('jev')
local panel = require('jev.panel')
local client = require('jev.client')

local real_post = client.post
local real_select = vim.ui.select

local last_request = nil
local finished = false

--- Replace client.post with one that answers from a canned table.
---@param resp table|nil
---@param err string|nil
local function stub_client(resp, err)
  client.post = function(opts, body, cb)
    last_request = { opts = opts, body = body }
    vim.schedule(function()
      cb(err, resp, 118)
      finished = true
    end)
  end
end

--- vim.ui.select is a headless hazard: the stock one reads stdin and kills the
--- process. Always replace it before anything can reach the confirm tier.
---@param answer string
---@return table log
local function stub_select(answer)
  local log = {}
  vim.ui.select = function(items, opts, on_choice)
    log[#log + 1] = { items = items, prompt = opts and opts.prompt }
    on_choice(answer)
  end
  return log
end

local function ask(text)
  finished = false
  jev.ask(text)
  vim.wait(2000, function()
    return finished
  end, 5)
  vim.wait(20)
end

local function reset()
  panel.close()
  pcall(vim.cmd, 'silent! tabonly')
  pcall(vim.cmd, 'silent! only')
  panel.clear()
  panel._state.target_win = nil
  panel._state.target_buf = nil
  vim.ui.select = real_select
  client.post = real_post
  last_request = nil
  jev.setup({ api_key = 'test-key-not-real' })
  vim.env.TYPESAFE_API_KEY = nil
end

--- The first transcript line containing `needle`, or nil.
---@param needle string
---@return string|nil
local function line_with(needle)
  for _, line in ipairs(panel.lines()) do
    if line:find(needle, 1, true) then
      return line
    end
  end
  return nil
end

local function answer_for(name, probability, extra)
  local probabilities = { [name] = probability, [NONE] = 1 - probability }
  local answers = {
    [ROUTE] = {
      type = 'choice',
      choice = name,
      confidence = probability,
      probabilities = probabilities,
    },
  }
  for qid, value in pairs(extra or {}) do
    answers[qid] = value
  end
  return {
    model = 'jev-1.13.0',
    answers = answers,
    usage = { input_tokens = 412, output_tokens = 61 },
  }
end

-- ---------------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------------

describe('actions', function()
  it('names are unique and non-empty', function()
    local seen = {}
    for _, action in ipairs(actions.list()) do
      ok(type(action.name) == 'string' and action.name ~= '', 'action has a name')
      ok(not seen[action.name], 'duplicate action name: ' .. tostring(action.name))
      seen[action.name] = true
    end
    ok(#actions.list() >= 19, 'the catalog has the documented actions')
  end)

  it('every action has a description, params and a run function', function()
    for _, action in ipairs(actions.list()) do
      ok(type(action.description) == 'string' and #action.description > 0, action.name .. ': description')
      ok(#action.description <= 600, action.name .. ': description under 600 chars')
      ok(type(action.params) == 'table', action.name .. ': params table')
      ok(type(action.run) == 'function', action.name .. ': run function')
      for pname, param in pairs(action.params) do
        ok(
          param.type == 'enum'
            or param.type == 'boolean'
            or param.type == 'integer'
            or param.type == 'string',
          action.name .. '.' .. pname .. ': known type'
        )
        ok(type(param.description) == 'string' and #param.description > 0, action.name .. '.' .. pname .. ': description')
        if param.type == 'enum' then
          ok(type(param.enum) == 'table' and next(param.enum) ~= nil, action.name .. '.' .. pname .. ': enum values')
        end
      end
    end
  end)

  it('by_name finds an action and rejects an unknown one', function()
    eq(actions.by_name('split_window').name, 'split_window')
    eq(actions.by_name('no_such_action'), nil)
    eq(actions.by_name(nil), nil)
  end)

  it('goto_line clamps past the end of the buffer', function()
    reset()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two', 'three' })
    vim.api.nvim_win_set_buf(win, buf)
    local ctx = { target_win = win, target_buf = buf }
    actions.by_name('goto_line').run({ line = 9999 }, ctx)
    eq(vim.api.nvim_win_get_cursor(win)[1], 3, 'clamped down to the last line')
    actions.by_name('goto_line').run({ line = -4 }, ctx)
    eq(vim.api.nvim_win_get_cursor(win)[1], 1, 'clamped up to the first line')
    actions.by_name('goto_line').run({ line = 2 }, ctx)
    eq(vim.api.nvim_win_get_cursor(win)[1], 2, 'an in-range line is left alone')
  end)

  it('toggle_option flips a window option and back', function()
    reset()
    local win = vim.api.nvim_get_current_win()
    local ctx = { target_win = win, target_buf = vim.api.nvim_win_get_buf(win) }
    local before = vim.wo[win].wrap
    actions.by_name('toggle_option').run({ option = 'wrap' }, ctx)
    eq(vim.wo[win].wrap, not before, 'wrap flipped')
    actions.by_name('toggle_option').run({ option = 'wrap' }, ctx)
    eq(vim.wo[win].wrap, before, 'wrap flipped back')
  end)

  it('close_window refuses to close the last window', function()
    reset()
    local win = vim.api.nvim_get_current_win()
    local err = throws(function()
      actions.by_name('close_window').run({}, { target_win = win })
    end, 'closing the last window should error')
    ok(err:find('last window', 1, true), 'error names the reason: ' .. err)
  end)
end)

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

describe('panel', function()
  it('opens on the right, keeps its width, and closes', function()
    reset()
    local before = #vim.api.nvim_tabpage_list_wins(0)
    panel.open()
    ok(panel.is_open(), 'panel window is open')
    eq(#vim.api.nvim_tabpage_list_wins(0), before + 1, 'one more window')
    eq(vim.api.nvim_win_get_width(panel._state.win), 50, 'configured width')
    ok(vim.wo[panel._state.win].winfixwidth, 'winfixwidth is set')
    eq(vim.bo[panel._state.buf].buftype, 'prompt', 'prompt buffer')
    eq(vim.bo[panel._state.buf].filetype, 'jev', 'filetype jev')
    panel.close()
    ok(not panel.is_open(), 'panel closed')
    eq(#vim.api.nvim_tabpage_list_wins(0), before, 'back to the original layout')
  end)

  it('keeps the transcript across a toggle', function()
    reset()
    panel.open()
    panel.print('you: hello')
    panel.toggle()
    ok(not panel.is_open(), 'toggled shut')
    panel.toggle()
    ok(panel.is_open(), 'toggled open')
    ok(line_with('you: hello'), 'history survived')
    panel.close()
  end)

  it('inserts output above the trailing prompt line', function()
    reset()
    panel.print('you: first')
    panel.print('  ok')
    local lines = panel.lines()
    eq(lines[1], 'you: first')
    eq(lines[2], '  ok')
    eq(lines[#lines], vim.fn.prompt_getprompt(panel.buf()), 'the prompt line stays last')
  end)

  it('resolve replaces the pending line in place', function()
    reset()
    panel.print('you: first')
    local handle = panel.pending('  …')
    panel.print('  a later line')
    panel.resolve(handle, '→ save_file  91% · 118ms')
    local lines = panel.lines()
    eq(lines[1], 'you: first')
    eq(lines[2], '→ save_file  91% · 118ms')
    eq(lines[3], '  a later line')
  end)

  it('falls back to another window when the target is gone', function()
    reset()
    vim.cmd('split')
    local doomed = vim.api.nvim_get_current_win()
    panel._state.target_win = doomed
    vim.api.nvim_win_close(doomed, true)
    local target = panel.target()
    ok(vim.api.nvim_win_is_valid(target), 'got a live window back')
    neq(target, doomed, 'not the closed one')
  end)
end)

-- ---------------------------------------------------------------------------
-- ask(): the whole flow with a fake client
-- ---------------------------------------------------------------------------

describe('ask', function()
  it('ignores empty input without touching the client', function()
    reset()
    stub_client(answer_for('save_file', 0.9))
    jev.ask('')
    jev.ask('   ')
    jev.ask(nil)
    eq(last_request, nil, 'no request went out')
    eq(panel.lines(), { vim.fn.prompt_getprompt(panel.buf()) }, 'nothing printed')
  end)

  it('sends state, model and questions in the documented shape', function()
    reset()
    stub_client(answer_for('save_file', 0.91))
    ask('save the file')
    ok(last_request, 'the client was called')
    eq(last_request.body.state, 'save the file', 'state is the utterance')
    eq(last_request.body.model, 'jev-latest', 'model from config')
    ok(type(last_request.body.questions) == 'table', 'questions is a map')
    ok(last_request.body.questions[ROUTE], 'the route question is present')
    eq(last_request.opts.url, 'https://api.typesafe.ai/v1/systemone')
    eq(last_request.opts.api_key, 'test-key-not-real')
    eq(last_request.opts.timeout_ms, 15000)
  end)

  it('runs split_window and a new window appears', function()
    reset()
    stub_client(answer_for('split_window', 0.92, {
      ['split_window::direction'] = {
        type = 'choice',
        choice = 'vertical',
        confidence = 0.95,
        probabilities = { vertical = 0.95, horizontal = 0.05 },
      },
    }))
    local before = #vim.api.nvim_tabpage_list_wins(0)
    ask('split the window vertically')
    eq(#vim.api.nvim_tabpage_list_wins(0), before + 1, 'a window was created')
    eq(panel.lines()[1], 'you: split the window vertically')
    local call = line_with('→ split_window')
    ok(call, 'the call line was printed')
    ok(call:find('{direction=vertical}', 1, true), 'args rendered: ' .. tostring(call))
    ok(call:find('92%', 1, true), 'confidence rendered: ' .. tostring(call))
    ok(call:find('118ms', 1, true), 'latency rendered: ' .. tostring(call))
    ok(line_with('  ok'), 'the result line was printed')
    ok(not line_with('  …'), 'the pending line was replaced')
  end)

  it('a destructive action goes through vim.ui.select and can be cancelled', function()
    reset()
    local log = stub_select('Cancel')
    stub_client(answer_for('reload_file', 0.99))
    ask('reload this file from disk')
    eq(#log, 1, 'the confirm prompt was shown once')
    eq(log[1].items, { 'Run', 'Cancel' }, 'the two choices')
    eq(log[1].prompt, 'Run reload_file?', 'the prompt names the call')
    ok(line_with('  cancelled'), 'the cancellation was recorded')
    ok(not line_with('  ok'), 'nothing ran')
  end)

  it('always_confirm asks even for a ready call, and Run executes it', function()
    reset()
    jev.setup({ api_key = 'test-key-not-real', always_confirm = true })
    local log = stub_select('Run')
    stub_client(answer_for('split_window', 0.92, {
      ['split_window::direction'] = {
        type = 'choice',
        choice = 'horizontal',
        confidence = 0.9,
        probabilities = { horizontal = 0.9, vertical = 0.1 },
      },
    }))
    local before = #vim.api.nvim_tabpage_list_wins(0)
    ask('split this')
    eq(#log, 1, 'asked first')
    eq(log[1].prompt, 'Run split_window {direction=horizontal}?')
    eq(#vim.api.nvim_tabpage_list_wins(0), before + 1, 'then ran')
  end)

  it('prints a readable line when no action matches', function()
    reset()
    stub_client({
      model = 'jev-1.13.0',
      answers = {
        [ROUTE] = {
          type = 'choice',
          choice = NONE,
          confidence = 0.4,
          probabilities = { [NONE] = 0.59, goto_line = 0.41 },
        },
      },
      usage = { input_tokens = 400, output_tokens = 40 },
    })
    ask('what is the weather like')
    local line = line_with('? no confident match')
    ok(line, 'the none line was printed')
    ok(line:find('best: goto_line 41%', 1, true), 'the runner-up is named: ' .. tostring(line))
  end)

  it('reports a required argument it could not fill', function()
    reset()
    stub_client(answer_for('open_file', 0.95))
    ask('open that thing')
    local line = line_with('? missing:')
    ok(line, 'the incomplete line was printed')
    ok(line:find('path', 1, true), 'the parameter is named: ' .. tostring(line))
  end)

  it('prints a readable line when the API key is missing', function()
    reset()
    jev.setup({ api_key = nil })
    vim.env.TYPESAFE_API_KEY = nil
    local called = false
    client.post = function()
      called = true
    end
    jev.ask('save the file')
    eq(called, false, 'no request was attempted')
    local line = line_with('no API key')
    ok(line, 'the missing-key line was printed')
    eq(line, '  error: no API key — set api_key in setup() or export TYPESAFE_API_KEY')
  end)

  it('surfaces a transport error without throwing', function()
    reset()
    stub_client(nil, 'could not start curl: curl not found on PATH')
    ask('save the file')
    eq(line_with('  error:'), '  error: could not start curl: curl not found on PATH')
  end)

  it('drops a stale response when a newer question supersedes it', function()
    reset()
    local pending = {}
    client.post = function(_, body, cb)
      pending[#pending + 1] = function()
        cb(nil, answer_for('save_file', 0.95), 42)
      end
      last_request = { body = body }
    end
    jev.ask('first question')
    jev.ask('second question')
    pending[1]() -- the stale one lands last
    pending[2]()
    local count = 0
    for _, line in ipairs(panel.lines()) do
      if line:find('→ save_file', 1, true) then
        count = count + 1
      end
    end
    eq(count, 1, 'only the newest response was shown')
    ok(not line_with('  …'), 'both pending lines were cleaned up')
  end)

  it('catches an error thrown by an action and prints it', function()
    reset()
    local action = actions.by_name('open_file')
    local original = action.run
    action.run = function()
      error('E484: Cannot open file /nope', 0)
    end
    stub_client(answer_for('open_file', 0.95, {
      ['open_file::path'] = {
        type = 'choice',
        choice = '/nope',
        confidence = 0.9,
        probabilities = { ['/nope'] = 0.9, ['(not stated)'] = 0.1 },
      },
    }))
    ask('open /nope')
    action.run = original
    local line = line_with('  error:')
    ok(line, 'an error line was printed')
    ok(line:find('Cannot open file', 1, true), 'the message came through: ' .. tostring(line))
  end)
end)

-- ---------------------------------------------------------------------------
-- Commands, config and docs
-- ---------------------------------------------------------------------------

describe('plugin', function()
  it('registers the user commands', function()
    -- Under `-u NONE` the plugin/ directory is never sourced; do it by hand.
    vim.g.loaded_jev = nil
    vim.cmd('runtime! plugin/jev.lua')
    local commands = vim.api.nvim_get_commands({})
    ok(commands.Jev, ':Jev exists')
    ok(commands.JevToggle, ':JevToggle exists')
    ok(commands.JevAsk, ':JevAsk exists')
    eq(commands.JevAsk.nargs, '*', ':JevAsk takes text')
  end)

  it('setup merges over the defaults without losing the rest', function()
    local config = require('jev.config')
    config.setup({ width = 60, thresholds = { auto = 0.9 } })
    eq(config.get().width, 60, 'overridden')
    eq(config.get().model, 'jev-latest', 'default kept')
    eq(config.get().thresholds.auto, 0.9, 'nested override')
    eq(config.get().thresholds.route, 0.5, 'nested default kept')
    config.setup({})
    eq(config.get().width, 50, 'setup starts from the defaults again')
  end)

  it('reads the API key from $TYPESAFE_API_KEY when setup has none', function()
    local config = require('jev.config')
    config.setup({})
    vim.env.TYPESAFE_API_KEY = nil
    eq(config.api_key(), nil, 'no key anywhere')
    vim.env.TYPESAFE_API_KEY = 'from-the-environment'
    eq(config.api_key(), 'from-the-environment', 'picked up from the environment')
    config.setup({ api_key = 'from-setup' })
    eq(config.api_key(), 'from-setup', 'setup wins')
    vim.env.TYPESAFE_API_KEY = nil
    config.setup({})
  end)

  it('checkhealth runs without erroring', function()
    local health = require('jev.health')
    local ok_check, err = pcall(health.check)
    ok(ok_check, 'health.check() ran: ' .. tostring(err))
  end)

  it('the help file builds its tags', function()
    ok(vim.uv.fs_stat(root .. '/doc/jev.txt'), 'doc/jev.txt exists')
    local ok_tags, err = pcall(vim.cmd, 'helptags ' .. vim.fn.fnameescape(root .. '/doc'))
    ok(ok_tags, 'helptags succeeded: ' .. tostring(err))
    ok(vim.uv.fs_stat(root .. '/doc/tags'), 'doc/tags was written')
  end)
end)

describe('client', function()
  it('splits curl -w status off the body', function()
    local body, status = client._split_status('{"ok":true}\n200')
    eq(body, '{"ok":true}')
    eq(status, 200)
    local empty, code = client._split_status('\n401')
    eq(empty, '')
    eq(code, 401)
  end)

  it('reads detail in both documented shapes', function()
    eq(client._detail_of({ detail = 'missing field questions' }), 'missing field questions')
    eq(client._detail_of({ detail = { error_type = 'max_tokens_exceeded' } }), 'max_tokens_exceeded')
    eq(client._detail_of({ error = { message = 'nope' } }), 'nope')
    eq(client._detail_of({}), '')
  end)

  it('reports a missing curl instead of throwing', function()
    local done, message = false, nil
    client.post = real_post
    client.post(
      { url = 'http://127.0.0.1:1/never', timeout_ms = 1000, api_key = 'x' },
      { state = 'hi', model = 'jev-latest', questions = {} },
      function(err)
        message = err
        done = true
      end
    )
    vim.wait(3000, function()
      return done
    end, 10)
    ok(done, 'the callback fired')
    ok(type(message) == 'string' and message ~= '', 'an error string came back: ' .. tostring(message))
  end)
end)

-- ---------------------------------------------------------------------------
-- The catalog at size: grouping, descriptions, and the request it produces
-- ---------------------------------------------------------------------------

--- A scratch buffer in the current window, plus the ctx an action is handed.
---@param lines string[]
---@return integer win, integer buf, JevCtx ctx
local function scratch(lines)
  reset()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  return win, buf, { target_win = win, target_buf = buf }
end

--- Call one action directly, the way |jev.ask()| would.
local function run(name, args, ctx)
  local action = actions.by_name(name)
  ok(action, 'no such action: ' .. tostring(name))
  return action.run(args or {}, ctx)
end

describe('catalog shape', function()
  it('is a real catalog, grouped by category', function()
    local list = actions.list()
    ok(#list >= 90, 'the catalog is worth routing over: ' .. #list)
    local grouped = 0
    local seen = {}
    for _, group in ipairs(actions.categories()) do
      ok(type(group.name) == 'string' and group.name ~= '', 'category has a name')
      ok(not seen[group.name], 'category listed once: ' .. group.name)
      seen[group.name] = true
      ok(#group.actions > 0, group.name .. ' is not empty')
      grouped = grouped + #group.actions
    end
    eq(grouped, #list, 'every action lands in exactly one category')
    for _, action in ipairs(list) do
      ok(type(action.category) == 'string' and action.category ~= '', action.name .. ': category')
      ok(seen[action.category], action.name .. ': category is one of the groups')
    end
  end)

  it('descriptions are distinct, and tight enough to ride in every request', function()
    local by_description = {}
    for _, action in ipairs(actions.list()) do
      ok(#action.description <= 160, action.name .. ': description is ' .. #action.description .. ' chars')
      local clash = by_description[action.description]
      ok(not clash, ('%s and %s share a description'):format(tostring(clash), action.name))
      by_description[action.description] = action.name
    end
  end)

  it('every enum option is a non-empty name', function()
    for _, action in ipairs(actions.list()) do
      for name, param in pairs(action.params) do
        if param.type == 'enum' then
          local count = 0
          for value in pairs(param.enum) do
            ok(type(value) == 'string' and value ~= '', action.name .. '.' .. name .. ': option name')
            count = count + 1
          end
          ok(count > 0, action.name .. '.' .. name .. ': has options')
          ok(count <= 255, action.name .. '.' .. name .. ': at most 255 options')
        end
      end
    end
  end)

  it('a long utterance against the whole catalog stays inside one request', function()
    local build = require('jev.questions').build
    local utterance = 'please replace the old helper name with a new helper name in this whole '
      .. 'buffer and then sort the lines and save everything to disk right now'
    local words = 0
    for _ in utterance:gmatch('%S+') do
      words = words + 1
    end
    ok(words >= 25, 'a long utterance: ' .. words .. ' words')

    local built = build(actions.list(), utterance)
    local body = vim.json.encode({ state = utterance, model = 'jev-latest', questions = built.questions })

    local route = built.questions['__tool__']
    local route_options = vim.tbl_count(route.criteria)
    eq(route_options, #actions.list() + 1, 'every action, plus __none__')
    ok(route_options <= 255, 'the route Choice has ' .. route_options .. ' options (max 255)')

    local biggest, biggest_id = 0, ''
    for id, question in pairs(built.questions) do
      local size = #vim.json.encode({ instructions = question.instructions, criteria = question.criteria })
      if size > biggest then
        biggest, biggest_id = size, id
      end
    end
    -- 32k tokens for `state` plus the longest question; bytes are the cheap proxy.
    ok(biggest <= 32 * 1024, ('the longest question (%s) is %d bytes'):format(biggest_id, biggest))
    ok(#body <= 200 * 1024, 'the whole request is ' .. #body .. ' bytes')

    print(
      ('     (request %d bytes · %d questions · %d route options · longest question %d bytes)'):format(
        #body,
        vim.tbl_count(built.questions),
        route_options,
        biggest
      )
    )
  end)
end)

-- ---------------------------------------------------------------------------
-- A sample of the new actions, in the headless editor
-- ---------------------------------------------------------------------------

describe('actions at work', function()
  it('move_line_down and move_line_up swap a line with its neighbour', function()
    local win, buf, ctx = scratch({ 'one', 'two', 'three' })
    eq(run('move_line_down', {}, ctx), 'line 2')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'two', 'one', 'three' })
    eq(vim.api.nvim_win_get_cursor(win)[1], 2, 'the cursor followed the line')
    eq(run('move_line_up', {}, ctx), 'line 1')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'one', 'two', 'three' })
    local err = throws(function()
      run('move_line_up', {}, ctx)
    end, 'moving the first line up should error')
    ok(err:find('first line', 1, true), err)
  end)

  it('duplicate_line pastes a copy below', function()
    local win, buf, ctx = scratch({ 'alpha', 'beta' })
    eq(run('duplicate_line', {}, ctx), 'duplicated line 1')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'alpha', 'alpha', 'beta' })
    eq(vim.api.nvim_win_get_cursor(win)[1], 2)
  end)

  it('sort_lines sorts, reverses and drops duplicates', function()
    local _, buf, ctx = scratch({ 'pear', 'apple', 'fig', 'apple' })
    local said = run('sort_lines', { order = 'ascending', unique = true }, ctx)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'apple', 'fig', 'pear' })
    ok(said:find('duplicate', 1, true), 'it says what it dropped: ' .. said)
    eq(run('sort_lines', { order = 'descending' }, ctx), 'sorted descending')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'pear', 'fig', 'apple' })
  end)

  it('trim_trailing_whitespace only touches the lines that need it', function()
    local _, buf, ctx = scratch({ 'clean', 'trailing   ', 'tabbed\t', '' })
    eq(run('trim_trailing_whitespace', {}, ctx), 'trimmed 2 lines')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'clean', 'trailing', 'tabbed', '' })
    eq(run('trim_trailing_whitespace', {}, ctx), 'trimmed 0 lines', 'a second pass changes nothing')
  end)

  it('uppercase_line shouts the current line', function()
    local _, buf, ctx = scratch({ 'quiet line', 'untouched' })
    eq(run('uppercase_line', {}, ctx), 'uppercased line 1')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'QUIET LINE', 'untouched' })
    eq(run('lowercase_line', {}, ctx), 'lowercased line 1')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'quiet line', 'untouched' })
  end)

  it('toggle_comment comments a line out and back in', function()
    local _, buf, ctx = scratch({ 'local x = 1' })
    vim.bo[buf].filetype = 'lua'
    run('toggle_comment', {}, ctx)
    eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { '-- local x = 1' })
    run('toggle_comment', {}, ctx)
    eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { 'local x = 1' })
  end)

  it('select_word puts the word under the cursor in visual mode', function()
    local win, buf, ctx = scratch({ 'hello world' })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    eq(run('select_word', {}, ctx), 'word selected')
    eq(vim.fn.mode(), 'v', 'visual mode')
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
    eq(vim.api.nvim_buf_get_mark(buf, '<')[2], 0, 'selection starts at the word')
    eq(vim.fn.getpos("'>")[3], 5, 'and ends at its last character')
  end)

  it('goto_percent lands part of the way through the file', function()
    local win, _, ctx = scratch(vim.split(string.rep('x\n', 100):sub(1, -2), '\n', { plain = true }))
    eq(run('goto_percent', { percent = 50 }, ctx), '50% — line 50')
    eq(vim.api.nvim_win_get_cursor(win)[1], 50)
    run('goto_percent', { percent = 0 }, ctx)
    eq(vim.api.nvim_win_get_cursor(win)[1], 1, 'clamped to the first line')
    run('goto_percent', { percent = 100 }, ctx)
    eq(vim.api.nvim_win_get_cursor(win)[1], 100, 'the last line')
    eq(run('goto_bottom', {}, ctx), 'line 100')
    eq(run('goto_top', {}, ctx), 'line 1')
  end)

  it('folding closes, opens and levels the folds', function()
    local win, _, ctx = scratch({ 'a', 'b', 'c', 'd', 'e' })
    vim.wo[win].foldmethod = 'manual'
    vim.cmd('1,3fold')
    eq(run('unfold_all', {}, ctx), 'unfolded')
    eq(vim.fn.foldclosed(1), -1, 'the fold is open')
    eq(run('fold_all', {}, ctx), 'folded')
    eq(vim.fn.foldclosed(1), 1, 'the fold is closed')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    eq(run('toggle_fold', {}, ctx), 'fold open')
    eq(vim.fn.foldclosed(1), -1)
    eq(run('set_fold_level', { level = 0 }, ctx), 'fold level 0')
    eq(vim.wo[win].foldlevel, 0)
    local err = throws(function()
      vim.api.nvim_win_set_cursor(win, { 5, 0 })
      run('toggle_fold', {}, ctx)
    end, 'a line with no fold should error')
    ok(err:find('no fold', 1, true), err)
  end)

  it('set_tab_width and set_shiftwidth land on the buffer', function()
    local _, buf, ctx = scratch({ 'indent me' })
    eq(run('set_tab_width', { width = 4 }, ctx), 'tab width 4')
    eq(vim.bo[buf].tabstop, 4)
    eq(vim.bo[buf].softtabstop, 4)
    eq(run('set_tab_width', { width = 99 }, ctx), 'tab width 8', 'clamped to the declared range')
    eq(run('set_shiftwidth', { width = 2 }, ctx), 'shiftwidth 2')
    eq(vim.bo[buf].shiftwidth, 2)
  end)

  it('quickfix_open and quickfix_close open and shut the list', function()
    reset()
    local ctx = { target_win = vim.api.nvim_get_current_win() }
    vim.fn.setqflist({ { filename = 'x.lua', lnum = 1, text = 'something' } })
    local before = #vim.api.nvim_tabpage_list_wins(0)
    eq(run('quickfix_open', {}, ctx), '1 entries')
    eq(#vim.api.nvim_tabpage_list_wins(0), before + 1, 'the quickfix window appeared')
    eq(run('quickfix_close', {}, ctx), 'quickfix closed')
    eq(#vim.api.nvim_tabpage_list_wins(0), before, 'and went away again')
    vim.fn.setqflist({})
    local err = throws(function()
      run('quickfix_next', {}, ctx)
    end, 'an empty quickfix list should error')
    ok(err:find('empty', 1, true), err)
  end)

  it('the tab actions open, move between and close tab pages', function()
    reset()
    eq(#vim.api.nvim_list_tabpages(), 1, 'one tab to start with')
    run('new_tab')
    run('new_tab')
    eq(#vim.api.nvim_list_tabpages(), 3)
    eq(run('goto_tab', { number = 1 }), 'tab 1')
    local err = throws(function()
      run('move_tab', { direction = 'left' })
    end, 'the first tab cannot move left')
    ok(err:find('first tab', 1, true), err)
    run('move_tab', { direction = 'right' })
    eq(vim.fn.tabpagenr(), 2, 'it moved one place right')
    eq(run('next_tab'), 'tab 3')
    eq(run('previous_tab'), 'tab 2')
    run('close_tab')
    eq(#vim.api.nvim_list_tabpages(), 2)
    run('tab_only')
    eq(#vim.api.nvim_list_tabpages(), 1)
  end)

  it('resize_window sizes the current split', function()
    reset()
    vim.cmd('split')
    local win = vim.api.nvim_get_current_win()
    local ctx = { target_win = win, target_buf = vim.api.nvim_win_get_buf(win) }
    eq(run('resize_window', { dimension = 'height', size = 5 }, ctx), 'height 5')
    eq(vim.api.nvim_win_get_height(win), 5)
    run('equalize_windows', {}, ctx)
    neq(vim.api.nvim_win_get_height(win), 5, 'equalize undid it')
    vim.cmd('only')
  end)

  it('replace_in_buffer asks first, then rewrites the buffer', function()
    local _, buf = scratch({ 'foo one', 'two foo', 'three' })
    local log = stub_select('Run')
    stub_client(answer_for('replace_in_buffer', 0.96, {
      ['replace_in_buffer::find'] = {
        type = 'choice',
        choice = 'foo',
        probabilities = { foo = 0.95, ['(not stated)'] = 0.05 },
      },
      ['replace_in_buffer::replacement'] = {
        type = 'choice',
        choice = 'bar',
        probabilities = { bar = 0.93, ['(not stated)'] = 0.07 },
      },
    }))
    ask('replace foo with bar in the whole buffer')
    eq(#log, 1, 'a destructive action asked first')
    ok(log[1].prompt:find('replace_in_buffer', 1, true), 'the prompt names the call: ' .. log[1].prompt)
    eq(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      { 'bar one', 'two bar', 'three' },
      'every occurrence was replaced'
    )
    ok(line_with('replaced 2 on 2 lines'), 'the count was reported')
  end)

  it('replace_in_line only touches the current line, and is undoable', function()
    local _, buf, ctx = scratch({ 'foo foo', 'foo' })
    eq(run('replace_in_line', { find = 'foo', replacement = 'bar' }, ctx), 'replaced 2 on line 1')
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'bar bar', 'foo' })
    eq(actions.by_name('replace_in_line').destructive, nil, 'an undoable edit is not destructive')
  end)
end)

-- ---------------------------------------------------------------------------
-- :JevActions and the generated README block
-- ---------------------------------------------------------------------------

describe('catalog listing', function()
  it('registers :JevActions', function()
    vim.g.loaded_jev = nil
    vim.cmd('runtime! plugin/jev.lua')
    ok(vim.api.nvim_get_commands({}).JevActions, ':JevActions exists')
  end)

  it('actions_lines() lists every action under its category', function()
    local lines = jev.actions_lines()
    local text = table.concat(lines, '\n')
    ok(text:find('%d+ actions in %d+ categories'), 'the header counts the catalog')
    for _, group in ipairs(actions.categories()) do
      ok(text:find('\n' .. group.name .. ' (' .. #group.actions .. ')', 1, true), 'heading for ' .. group.name)
    end
    for _, action in ipairs(actions.list()) do
      ok(text:find(' ' .. action.name .. ' ', 1, true), 'lists ' .. action.name)
    end
    ok(text:find('[destructive]', 1, true), 'destructive actions are flagged')
    ok(text:find('[read-only]', 1, true), 'read-only actions are flagged')
  end)

  it('show_actions() opens a scratch buffer with the catalog', function()
    reset()
    local buf = jev.show_actions()
    ok(vim.api.nvim_buf_is_valid(buf), 'a buffer came back')
    eq(vim.bo[buf].buftype, 'nofile')
    eq(vim.bo[buf].modifiable, false)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), jev.actions_lines())
    pcall(vim.cmd, 'silent! tabclose')
    reset()
  end)

  it('the README actions block matches scripts/gen_actions_md.lua', function()
    local readme = table.concat(vim.fn.readfile(root .. '/README.md'), '\n')
    local block = readme:match('<!%-%- actions:start %-%->\n(.-)\n<!%-%- actions:end %-%->')
    ok(block, 'README.md carries the actions:start/actions:end markers')
    local generated = dofile(root .. '/scripts/gen_actions_md.lua')
    ok(
      block == generated,
      'the README block is stale — regenerate it with: nvim -l scripts/gen_actions_md.lua'
    )
  end)
end)

reset()
