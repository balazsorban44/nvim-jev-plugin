--- Answers -> an action call your code can run, with a probability behind
--- every part of it.
---
--- Port of `src/core/decode.js` from sdras/jev-webmcp-extension (Apache 2.0).
---
--- Two things the original is emphatic about, kept here:
---  * the per-argument probability is `answer.probabilities[answer.choice]`,
---    the winning option's raw probability. decode.js never reads `confidence`.
---  * `confidence` is `min(routeProbability, every argument's probability)` —
---    "the least certain judgement behind the call: one wrong argument spoils
---    the result, so a product would punish long signatures."
---
--- Everything coming in here has been through `vim.json.decode`, so a JSON
--- null arrives as `vim.NIL` rather than nil; `unwrap()` below flattens both.

local questions = require("jev.questions")

local M = {}

local YES = 0.5

local function unwrap(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

local function certainty(noul)
  return math.max(noul, 1 - noul)
end

--- The Noul answer shape, verified against the TypeSafe API reference:
---   { "type": "noul", "noul": 1.0 }
--- `noul` is "The yes/no answer on a scale from 0 (no) to 1 (yes)" and **Noul
--- answers carry no `confidence`** — the quickstart response confirms it, and
--- decode.js reads `answers[qid]?.noul ?? 0` and nothing else.
---
--- Read defensively anyway, as the brief asks:
---  * number `noul`             -> used as-is (the documented shape)
---  * boolean `noul`            -> the side it names, scaled by `probability`
---                                 when one rides along (false @ p=0.9 means a
---                                 noul of 0.1, so certainty() still reads 0.9)
---  * only a `probability`      -> used as the noul
---  * anything else / missing   -> 0, exactly like the JS `?? 0`
local function noul_of(answer)
  if type(answer) ~= "table" then
    return 0
  end
  local n = unwrap(answer.noul)
  local p = unwrap(answer.probability)
  if type(n) == "number" then
    return n
  end
  if type(n) == "boolean" then
    if type(p) == "number" then
      return n and p or (1 - p)
    end
    return n and 1 or 0
  end
  if type(p) == "number" then
    return p
  end
  return 0
end

local function probability_of(probabilities, key)
  local map = unwrap(probabilities)
  if key == nil or type(map) ~= "table" then
    return nil
  end
  local p = unwrap(map[key])
  return type(p) == "number" and p or nil
end

--- topOf(): the `n` most probable options, most probable first.
local function top_of(probabilities, n)
  local map = unwrap(probabilities)
  local entries = {}
  if type(map) == "table" then
    for key, value in pairs(map) do
      local p = unwrap(value)
      if type(key) == "string" and type(p) == "number" then
        entries[#entries + 1] = { value = key, probability = p }
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.probability ~= b.probability then
      return a.probability > b.probability
    end
    return a.value < b.value -- pairs() has no order; break ties deterministically
  end)
  if n then
    for i = #entries, n + 1, -1 do
      entries[i] = nil
    end
  end
  return entries
end

local function set_path(target, path, value)
  local node = target
  for i, key in ipairs(path) do
    if i == #path then
      node[key] = value
      return
    end
    if node[key] == nil then
      node[key] = {}
    end
    node = node[key]
  end
end

local function decode_param(param, answers)
  local detail = {
    label = param.label,
    name = param.name,
    path = param.path,
    kind = param.kind,
    required = param.required,
    container = param.container,
    localRequired = param.localRequired,
  }

  local stated = 1
  if param.statedQid then
    stated = noul_of(answers[param.statedQid])
    detail.stated = stated >= YES
    detail.statedNoul = stated
  end
  local answer = param.qid and answers[param.qid] or nil

  if param.kind == "flag" then
    local noul = noul_of(answer)
    local on = noul >= YES
    detail.probability = certainty(noul)
    if on or param.required then
      detail.value = on
    else
      detail.omitted = true
    end
    return detail
  end

  if param.kind == "set" then
    local value, distribution = {}, {}
    -- JS Math.min() of no members is Infinity; math.huge behaves the same in
    -- the confidence min() below.
    local probability = math.huge
    for _, member in ipairs(param.members or {}) do
      local noul = noul_of(answers[member.qid])
      if noul >= YES then
        value[#value + 1] = member.value
      end
      probability = math.min(probability, certainty(noul))
      distribution[#distribution + 1] = { value = questions.str_value(member.value), probability = noul }
    end
    table.sort(distribution, function(a, b)
      if a.probability ~= b.probability then
        return a.probability > b.probability
      end
      return a.value < b.value
    end)
    detail.probability = probability
    detail.distribution = distribution
    if #value == 0 then
      if param.required then
        detail.missing = true
      else
        detail.omitted = true
      end
    else
      detail.value = value
    end
    return detail
  end

  if type(answer) ~= "table" then
    detail.probability = 1
    if param.required then
      detail.missing = true
    else
      detail.omitted = true
    end
    return detail
  end

  detail.distribution = top_of(answer.probabilities, 3)

  if stated < YES then
    detail.omitted = true
    detail.probability = 1 - stated
    return detail
  end

  local choice = unwrap(answer.choice)
  if choice ~= nil and type(choice) ~= "string" then
    choice = questions.str_value(choice)
  end

  if choice == questions.NOT_STATED then
    detail.probability = probability_of(answer.probabilities, questions.NOT_STATED) or 0
    if param.required then
      detail.missing = true
    else
      detail.omitted = true
    end
    return detail
  end

  -- Criteria keys are strings; hand the action the value its catalog declared.
  local declared = nil
  for _, option in ipairs(param.options or {}) do
    if questions.str_value(option.value) == choice then
      declared = option
      break
    end
  end
  local value
  if declared then
    value = declared.value
  elseif param.kind == "number" then
    value = choice and tonumber(choice) or nil
  else
    value = choice
  end
  -- A null/absent `choice` lands here with value nil and probability 0, which
  -- is what the JS does with `undefined` (the argument simply never gets set).
  detail.value = value
  detail.probability = math.min(stated, probability_of(answer.probabilities, choice) or 0)
  return detail
end

---@class JevDecoded
---@field name string|nil
---@field action JevAction|nil
---@field args table
---@field missing string[]
---@field routeProbability number
---@field confidence number    -- min(routeProbability, every arg probability)
---@field details table<string, table>  -- by param label
---@field routes { name: string|nil, probability: number }[]
---@field picked boolean

--- Decode Jev's answers into an action call.
---
--- `opts.pick` is an action the user chose over Jev's route; every action's
--- arguments were answered in the same request, so the call is ready without
--- asking again. The panel does not offer that yet, but the branch is the
--- source's and costs nothing.
---
--- DEVIATION from decode.js: `details` is a map keyed by param label rather
--- than an array, as the design brief's JevDecoded specifies. `missing` keeps
--- the source's array form (in param order).
---@param actions JevAction[]
---@param answers table<string, table>
---@param meta table                     -- the `meta` from questions.build()
---@param opts { pick: string? }?
---@return JevDecoded
function M.decode(actions, answers, meta, opts)
  opts = opts or {}
  answers = type(answers) == "table" and answers or {}
  meta = meta or {}
  local plan = meta.plan or {}

  local index = {}
  for _, action in ipairs(actions or {}) do
    index[action.name] = action
  end

  local route = answers[questions.ROUTE]
  route = type(route) == "table" and route or nil

  local pick = opts.pick
  local picked = pick ~= nil and plan[pick] ~= nil and index[pick] ~= nil
  local choice = nil
  if picked then
    choice = pick
  elseif route then
    choice = unwrap(route.choice)
    if choice ~= nil and type(choice) ~= "string" then
      choice = questions.str_value(choice)
    end
  end

  local routes = {}
  for i, r in ipairs(top_of(route and route.probabilities, nil)) do
    if i <= 3 or r.value == choice then
      routes[#routes + 1] = {
        -- `__none__` reports as no action at all, like the JS `value: null`.
        name = r.value ~= questions.NONE and r.value or nil,
        key = r.value,
        probability = r.probability,
      }
    end
  end

  local route_probability = (route and probability_of(route.probabilities, choice)) or 0

  if not choice or choice == questions.NONE or not plan[choice] or not index[choice] then
    -- DEVIATION: the JS returns this branch WITHOUT a `routeProbability` field
    -- (it only passes the value along as `confidence`), so `call.routeProbability`
    -- reads as undefined there. Filling both in keeps JevDecoded's shape honest
    -- and lets the panel say "no confident match (best: goto_line 41%)". It
    -- cannot change a decision: policy.decide() returns "none" on `name` first.
    return {
      name = nil,
      action = nil,
      args = {},
      details = {},
      missing = {},
      routes = routes,
      routeProbability = route_probability,
      confidence = route_probability,
      picked = false,
    }
  end

  local action = index[choice]
  local ordered, details = {}, {}
  for _, param in ipairs(plan[choice].params or {}) do
    local detail = decode_param(param, answers)
    ordered[#ordered + 1] = detail
    details[detail.label] = detail
  end

  -- An optional object or list item goes in whole or not at all. A flat
  -- catalog param never sets `container`, so this never fires; kept from the
  -- source so a nested catalog would behave the same.
  local broken = {}
  for _, d in ipairs(ordered) do
    if d.container and d.localRequired and (d.omitted or d.missing) then
      broken[d.container] = true
    end
  end
  for _, d in ipairs(ordered) do
    if d.container and broken[d.container] and not d.omitted then
      d.omitted = true
      d.missing = false
      d.value = nil
    end
  end

  local args, missing = {}, {}
  -- The user's pick settles the route, so only the arguments are left in doubt.
  local confidence = picked and 1 or route_probability
  for _, d in ipairs(ordered) do
    if not d.omitted and not d.missing then
      set_path(args, d.path, d.value)
    end
    if d.missing then
      missing[#missing + 1] = d.label
    end
    confidence = math.min(confidence, d.probability or 1)
  end

  return {
    name = action.name,
    action = action,
    args = args,
    details = details,
    missing = missing,
    routes = routes,
    routeProbability = route_probability,
    confidence = confidence,
    picked = picked,
  }
end

--- `split_window {direction=vertical}` — formatCall() in the panel's notation
--- (see the design brief's output format), args sorted so it never jitters.
---@param call JevDecoded|nil
---@return string
function M.format_call(call)
  if not call or not call.name then
    return ""
  end
  local keys = {}
  for k in pairs(call.args or {}) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = call.args[k]
    if type(v) == "table" then
      local items = {}
      for _, item in ipairs(v) do
        items[#items + 1] = questions.str_value(item)
      end
      v = "[" .. table.concat(items, ",") .. "]"
    else
      v = questions.str_value(v)
    end
    parts[#parts + 1] = ("%s=%s"):format(k, v)
  end
  if #parts == 0 then
    return call.name
  end
  return ("%s {%s}"):format(call.name, table.concat(parts, ", "))
end

return M
