-- Print the README's action catalog section, grouped by category.
--
--   nvim -l scripts/gen_actions_md.lua
--
-- The output goes between the `<!-- actions:start -->` / `<!-- actions:end -->`
-- markers in README.md; tests/test_editor.lua fails when the two drift apart.
-- The file also `return`s the markdown, so a test can `dofile()` it.

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local root = vim.fn.fnamemodify(here, ':h')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local actions = require('jev.actions')

---@param s string
---@return string
local function cell(s)
  return (tostring(s):gsub('|', '\\|'))
end

--- `direction: vertical \| horizontal`, `count?: 1..20`, `path`.
---@param action JevAction
---@return string
local function arguments(action)
  local names = {}
  for name in pairs(action.params or {}) do
    names[#names + 1] = name
  end
  if #names == 0 then
    return '–'
  end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    local param = action.params[name]
    local label = '`' .. name .. (param.required and '' or '?') .. '`'
    local detail = nil
    if param.type == 'enum' then
      local values = {}
      for value in pairs(param.enum or {}) do
        values[#values + 1] = value
      end
      table.sort(values)
      if #values <= 4 then
        detail = table.concat(values, ' \\| ')
      else
        detail = #values .. ' options'
      end
    elseif param.type == 'integer' then
      if param.min and param.max then
        detail = param.min .. '..' .. param.max
      else
        detail = 'number'
      end
    elseif param.type == 'boolean' then
      detail = 'yes/no'
    end
    parts[#parts + 1] = detail and (label .. ' ' .. detail) or label
  end
  return table.concat(parts, ', ')
end

---@param action JevAction
---@return string
local function notes(action)
  if action.destructive then
    return 'destructive'
  end
  if action.readOnly then
    return 'read-only'
  end
  return ''
end

---@return string
local function render()
  local groups = actions.categories()
  local out = {}
  local function put(line)
    out[#out + 1] = line
  end

  put(('%d actions in %d categories. Regenerate this block with'):format(#actions.list(), #groups))
  put('`nvim -l scripts/gen_actions_md.lua`.')
  put('')
  for _, group in ipairs(groups) do
    local header = '<details>\n<summary><b>%s</b> — %d actions</summary>\n'
    put(header:format(group.name, #group.actions))
    put('| Action | Arguments | What it does | Flags |')
    put('| --- | --- | --- | --- |')
    for _, action in ipairs(group.actions) do
      put(
        ('| `%s` | %s | %s | %s |'):format(
          action.name,
          arguments(action),
          cell(action.description),
          notes(action)
        )
      )
    end
    put('\n</details>\n')
  end
  -- No trailing newline: the README block is compared byte for byte.
  return (table.concat(out, '\n'):gsub('%s+$', ''))
end

local markdown = render()

if arg and arg[0] and tostring(arg[0]):match('gen_actions_md%.lua$') then
  io.write(markdown, '\n')
end

return markdown
