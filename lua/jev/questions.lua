--- An action catalog + one utterance -> the typed questions Jev answers.
---
--- Port of `src/core/questions.js` from sdras/jev-webmcp-extension (Apache 2.0),
--- against this plugin's flat `table<string, JevParam>` catalog instead of a
--- WebMCP tool's nested JSON Schema. The mapping is the original's:
---
---   which action?          -> one Choice over action name -> description
---   enum / const / oneOf   -> Choice over the allowed values
---   boolean                -> Noul
---   array of enum          -> one Noul per member
---   small integer range    -> Choice over the range
---   free text              -> Choice over spans of the user's own words
---   other numbers          -> Choice over numbers the user stated
---   optional anything      -> an extra "is it stated?" Noul, so defaults stand
---
--- Every question rides in one request; Jev answers them in parallel.
---
--- Instructions are copied verbatim from the source, including the `For the
--- "<action>" action:` prefix. The question key is never sent to the model
--- ("The key is not sent to the underlying model and is not used in
--- inference"), so all meaning lives in `instructions`.

local spans = require("jev.spans")

local M = {}

M.ROUTE = "__tool__"
M.NONE = "__none__"
M.NOT_STATED = "(not stated)"

-- JS: const RANGE_LIMIT = 24, used as `max - min <= RANGE_LIMIT`, i.e. up to 25
-- options (1..25 qualifies). The design brief's prose says `max-min+1 <= 24`;
-- the JS source wins, per "follow the JS literally".
local RANGE_LIMIT = 24

-- JS: clip = (text, max) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)
-- Counted in characters (JS counts UTF-16 code units; identical for ASCII).
local function clip(text, max)
  text = type(text) == "string" and text or tostring(text or "")
  if vim.fn.strchars(text) > max then
    return vim.fn.strcharpart(text, 0, max - 1) .. "…"
  end
  return text
end

--- JS `String(value)` for criteria keys: integers never grow a ".0".
---@param value any
---@return string
function M.str_value(value)
  if type(value) == "number" and value == math.floor(value) and math.abs(value) < 2 ^ 53 then
    return string.format("%d", value)
  end
  return tostring(value)
end

local function sorted_keys(map)
  local keys = {}
  for k in pairs(map) do
    keys[#keys + 1] = k
  end
  -- The JS walks JSON Schema `properties` in insertion order; a Lua map has
  -- none, so params are ordered by name. Only affects iteration order, never
  -- the question ids or their content.
  table.sort(keys)
  return keys
end

--- `enum` is `value -> description` where the description may be "".
--- The JS `enum` branch of closedSet() carries `description: null`, so an empty
--- description becomes JSON null here too.
local function options_of_enum(enum)
  local options = {}
  for _, value in ipairs(sorted_keys(enum or {})) do
    local description = enum[value]
    if type(description) ~= "string" or description == "" then
      description = vim.NIL
    end
    options[#options + 1] = { value = value, description = description }
  end
  return options
end

--- Flatten one action's params into the parameters Jev can fill.
---
--- Port of paramsOf(). The catalog is flat, so `path` is always a single key,
--- `label` is the param name, `container` is always nil and `localRequired`
--- always equals `required` — the nested-object/array walk of the original has
--- nothing to walk here.
---@param action JevAction
---@return table[]
function M.params_of(action)
  local out = {}
  local params = action.params or {}
  for _, name in ipairs(sorted_keys(params)) do
    local schema = params[name] or {}
    local param = {
      name = name,
      label = name,
      path = { name },
      required = schema.required == true,
      localRequired = schema.required == true,
      container = nil,
      schema = schema,
      default = schema.default,
    }
    local t = schema.type

    if schema.enum ~= nil and (t == "array" or t == "set") then
      -- array of enum -> one Noul per member. Beyond the four types the design
      -- brief lists, kept so the port covers questions.js's `set` branch.
      param.kind = "set"
      param.options = options_of_enum(schema.enum)
    elseif schema.enum ~= nil then
      -- closedSet(): a fixed list of values is a Choice whatever the type says.
      param.kind = "choice"
      param.options = options_of_enum(schema.enum)
    elseif t == "boolean" then
      param.kind = "flag"
    elseif t == "integer" or t == "number" then
      local min, max = schema.min, schema.max
      if t == "integer" and type(min) == "number" and type(max) == "number" and max - min <= RANGE_LIMIT then
        local range = {}
        for v = min, max do
          range[#range + 1] = { value = v, description = vim.NIL }
        end
        param.kind = "choice"
        param.options = range
      else
        param.kind = "number"
      end
    elseif t == "string" then
      param.kind = "span"
    else
      param.kind = "unfillable"
    end
    out[#out + 1] = param
  end
  return out
end

-- JS: `"${key}"${description}` with description = ` (${clip(desc, 300)})`.
-- An empty description is falsy in JS, so it adds no parentheses; "" is truthy
-- in Lua, hence the explicit ~= "" test.
local function about(param)
  local key = param.name or "value"
  local description = param.schema and param.schema.description
  if type(description) == "string" and description ~= "" then
    return '"' .. key .. '" (' .. clip(description, 300) .. ")"
  end
  return '"' .. key .. '"'
end

local function criteria_of(options)
  if #options == 0 then
    return vim.empty_dict() -- so JSON carries {} and not []
  end
  local criteria = {}
  for _, o in ipairs(options) do
    criteria[M.str_value(o.value)] = o.description == nil and vim.NIL or o.description
  end
  return criteria
end

--- Questions for one utterance against an action catalog, plus the `meta`
--- that decode() uses to turn the answers back into an action call.
---
--- `state` for the request is the utterance string itself, echoed in
--- `meta.state` so the caller does not have to keep it.
---@param actions JevAction[]
---@param utterance string
---@param opts { only: string[]? }?
---@return { questions: table<string, table>, meta: table }
function M.build(actions, utterance, opts)
  opts = opts or {}
  utterance = utterance or ""

  local active = {}
  for _, action in ipairs(actions or {}) do
    if not opts.only or vim.tbl_contains(opts.only, action.name) then
      active[#active + 1] = action
    end
  end

  local said = { spans = spans.spans(utterance), numbers = spans.numbers(utterance) }

  local route_criteria = {}
  for _, action in ipairs(active) do
    route_criteria[action.name] = clip(action.description or action.title or action.name, 600)
  end
  route_criteria[M.NONE] =
    "None of these: the request is conversation, unclear, unfinished, or needs something these actions do not do."

  local questions = {
    [M.ROUTE] = {
      type = "choice",
      instructions = "Which action does the user's request call for?",
      criteria = route_criteria,
    },
  }

  local plan = {}
  for _, action in ipairs(active) do
    local subject = 'the "' .. action.name .. '" action'
    local params = M.params_of(action)

    for _, param in ipairs(params) do
      local qid = action.name .. "::" .. param.label
      param.qid = qid

      -- Only non-required params get a "stated?" Noul, and `flag`/`set` never
      -- ask for one (the source calls askStated() from three branches only).
      local function ask_stated()
        if param.required then
          return
        end
        param.statedQid = qid .. "?"
        questions[param.statedQid] = {
          type = "noul",
          instructions = ("For %s: does the user's request state or clearly imply %s?"):format(subject, about(param)),
        }
      end

      if param.kind == "choice" then
        questions[qid] = {
          type = "choice",
          instructions = ("For %s: which option does the user's request indicate for %s?"):format(subject, about(param)),
          criteria = criteria_of(param.options),
        }
        ask_stated()
      elseif param.kind == "flag" then
        questions[qid] = {
          type = "noul",
          instructions = ("For %s: does the user's request call for %s?"):format(subject, about(param)),
        }
      elseif param.kind == "set" then
        param.members = {}
        for _, o in ipairs(param.options) do
          local value = M.str_value(o.value)
          local member_qid = qid .. "::" .. value
          questions[member_qid] = {
            type = "noul",
            instructions = ('For %s: does the user\'s request ask for "%s"? It is one option of %s.'):format(
              subject,
              value,
              about(param)
            ),
          }
          param.members[#param.members + 1] = { value = o.value, qid = member_qid }
        end
      elseif param.kind == "span" and #said.spans > 0 then
        local criteria = {}
        for _, s in ipairs(said.spans) do
          criteria[s] = vim.NIL
        end
        criteria[M.NOT_STATED] = "The request does not say this."
        questions[qid] = {
          type = "choice",
          instructions = ("For %s: which exact words of the user's request give %s?"):format(subject, about(param)),
          criteria = criteria,
        }
        ask_stated()
      elseif param.kind == "number" and #said.numbers > 0 then
        local criteria = {}
        for _, n in ipairs(said.numbers) do
          criteria[M.str_value(n.value)] = ('The user wrote "%s".'):format(n.text)
        end
        criteria[M.NOT_STATED] = "None of these numbers is this."
        questions[qid] = {
          type = "choice",
          instructions = ("For %s: which number in the user's request is %s?"):format(subject, about(param)),
          criteria = criteria,
        }
        ask_stated()
      else
        -- Nothing to ask: the default stands, or the user fills it in. Note
        -- that a span/number question with no candidates is OMITTED here, not
        -- emitted with a lone "(not stated)" option — that is what the source
        -- does, and decode() then reports the param missing if it is required.
        param.qid = nil
      end
    end

    plan[action.name] = { name = action.name, params = params }
  end

  return {
    questions = questions,
    meta = {
      state = utterance,
      utterance = utterance,
      spans = said.spans,
      numbers = said.numbers,
      plan = plan,
    },
  }
end

return M
