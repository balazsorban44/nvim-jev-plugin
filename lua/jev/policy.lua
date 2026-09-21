--- What may happen to a predicted call. Confidence tells you whether to act;
--- the action's own hints tell you how careful to be.
---
--- Port of `src/core/policy.js` from sdras/jev-webmcp-extension (Apache 2.0).
--- The original follows Chrome's agent guidance: assume an action changes
--- state unless it says readOnlyHint, and keep a human in the loop for
--- everything else. The catalog's `readOnly` / `destructive` flags stand in for
--- WebMCP's `annotations.readOnlyHint` / `destructiveHint` +
--- `consequentialHint` (which collapse into one "always confirm" flag here).

local M = {}

--- Verbatim thresholds from policy.js.
M.DEFAULTS = { route = 0.5, auto = 0.8, confirm = 0.6 }

--- Decide what to do with a decoded call.
---
---   none        no action fits: hand back to the user
---   incomplete  a required argument has no value yet: the user fills it in
---   auto        read-only and confident: safe to run unprompted
---   ready       Enter runs it
---   confirm     Enter asks first (shaky, flagged, or consequential)
---
--- Order of evaluation is the source's, and it matters.
--- There is no live-typing mode in this plugin, so `live` defaults to true
--- (the original's default too); `opts.live = false` still demotes `auto` to
--- `ready`, which is what the reference test suite asserts.
---@param call JevDecoded|nil
---@param opts { live: boolean?, flagged: boolean?, thresholds: table? }?
---@return "none"|"incomplete"|"confirm"|"auto"|"ready"
function M.decide(call, opts)
  opts = opts or {}
  local thresholds = {
    route = M.DEFAULTS.route,
    auto = M.DEFAULTS.auto,
    confirm = M.DEFAULTS.confirm,
  }
  for key, value in pairs(opts.thresholds or {}) do
    if type(value) == "number" then
      thresholds[key] = value
    end
  end
  local live = opts.live == nil or opts.live == true
  local flagged = opts.flagged == true

  -- An action the user picked needs no route confidence; the rest still applies.
  if not call or not call.name or (not call.picked and (call.routeProbability or 0) < thresholds.route) then
    return "none"
  end
  if #(call.missing or {}) > 0 then
    return "incomplete"
  end
  local action = call.action or {}
  if flagged or action.destructive then
    return "confirm"
  end
  local confidence = call.confidence or 0
  if action.readOnly and live and confidence >= thresholds.auto then
    return "auto"
  end
  return confidence >= thresholds.confirm and "ready" or "confirm"
end

return M
