---@brief Defaults and merge for jev.nvim.

local M = {}

---@class JevThresholds
---@field route number
---@field auto number
---@field confirm number

---@class JevConfig
---@field api_key string|nil    falls back to $TYPESAFE_API_KEY at request time
---@field model string
---@field url string
---@field timeout_ms integer
---@field width integer
---@field prompt string
---@field always_confirm boolean
---@field thresholds JevThresholds

---@type JevConfig
M.defaults = {
  api_key = nil,
  model = 'jev-latest',
  url = 'https://api.typesafe.ai/v1/systemone',
  timeout_ms = 15000,
  width = 44,
  prompt = 'jev> ',
  always_confirm = false,
  thresholds = { route = 0.5, auto = 0.8, confirm = 0.6 },
}

---@type JevConfig
M.options = vim.deepcopy(M.defaults)

--- Merge user options over the defaults.
---@param opts table|nil
---@return JevConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

---@return JevConfig
function M.get()
  return M.options
end

--- The API key to use, or nil. Never logged.
---@return string|nil
function M.api_key()
  local key = M.options.api_key
  if type(key) ~= 'string' or key == '' then
    key = vim.env.TYPESAFE_API_KEY or os.getenv('TYPESAFE_API_KEY')
  end
  if type(key) ~= 'string' or key == '' then
    return nil
  end
  return key
end

return M
