-- Headless test runner for jev.nvim. No plenary, no dependencies.
--
--   nvim --headless --clean -u NONE -l tests/run.lua < /dev/null
--
-- `< /dev/null` matters: the stock vim.ui.select reads stdin and will kill a
-- headless process outright. Tests that reach it must monkeypatch it.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path

local passed, failed = 0, 0
local group = nil

---@param name string
---@param fn fun()
function _G.describe(name, fn)
  local previous = group
  group = previous and (previous .. ' › ' .. name) or name
  local ok, err = pcall(fn)
  group = previous
  if not ok then
    failed = failed + 1
    io.stderr:write(string.format('FAIL %s (while describing)\n  %s\n', name, tostring(err)))
  end
end

---@param name string
---@param fn fun()
function _G.it(name, fn)
  local full = group and (group .. ' › ' .. name) or name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('ok   ' .. full)
  else
    failed = failed + 1
    io.stderr:write(string.format('FAIL %s\n  %s\n', full, tostring(err)))
  end
end

--- Deep equality assertion.
function _G.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    error(
      string.format(
        '%s\n    got  = %s\n    want = %s',
        msg or 'values differ',
        vim.inspect(got),
        vim.inspect(want)
      ),
      2
    )
  end
end

--- Truthiness assertion.
function _G.ok(value, msg)
  if not value then
    error(msg or 'expected a truthy value', 2)
  end
end

--- Inequality assertion.
function _G.neq(got, unwanted, msg)
  if vim.deep_equal(got, unwanted) then
    error(string.format('%s (both %s)', msg or 'values should differ', vim.inspect(got)), 2)
  end
end

--- Float comparison.
function _G.near(got, want, tolerance, msg)
  tolerance = tolerance or 1e-6
  if type(got) ~= 'number' or math.abs(got - want) > tolerance then
    error(string.format('%s (got=%s want=%s)', msg or 'not near', tostring(got), tostring(want)), 2)
  end
end

--- Assert that `fn` errors, and return the message.
function _G.throws(fn, msg)
  local succeeded, err = pcall(fn)
  if succeeded then
    error(msg or 'expected an error', 2)
  end
  return tostring(err)
end

local files = {
  'tests/test_core.lua',
  'tests/test_editor.lua',
}

for _, rel in ipairs(files) do
  local path = root .. '/' .. rel
  if vim.uv.fs_stat(path) then
    local ok_load, err = pcall(dofile, path)
    if not ok_load then
      failed = failed + 1
      io.stderr:write(string.format('FAIL %s (while loading)\n  %s\n', rel, tostring(err)))
    end
  else
    print('skip ' .. rel .. ' (not present)')
  end
end

print(string.format('\n%d passed, %d failed', passed, failed))
if failed > 0 then
  vim.cmd('cquit 1')
else
  os.exit(0)
end
