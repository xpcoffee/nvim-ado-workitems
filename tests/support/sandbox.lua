-- Sandboxed loader for core modules and the assertion helpers every spec gets.
-- Plain Lua: the helpers run inside the sandbox too, so nothing here may use vim.
local M = {}

-- Globals a core module has no reason to touch. `vim` is the rule (RFC 0001 R6.1); the
-- loaders and debug functions would let a module step around the sandbox.
local BLOCKED = {
  vim = true,
  package = true,
  dofile = true,
  loadfile = true,
  load = true,
  loadstring = true,
  debug = true,
  getfenv = true,
  setfenv = true,
}

local function module_path(root, name)
  local rel = (name:gsub("%.", "/")) .. ".lua"
  if name:match("^ado%.core%.") then
    return root .. "/lua/" .. rel
  -- Specs run in the same sandbox and load the fake transport and fixtures.
  elseif name:match("^tests%.") then
    return root .. "/" .. rel
  end
end

-- Returns a fresh environment with its own module cache, so state in one spec
-- file's modules cannot leak into the next.
function M.new(root, globals)
  local env = {}
  local loaded = {}

  local function sandbox_require(name)
    if loaded[name] ~= nil then return loaded[name] end
    local path = module_path(root, name)
    if not path then
      error("sandbox: require('" .. name .. "') is not allowed; only ado.core.* and,"
        .. " for specs, tests.* may be required", 2)
    end
    local chunk, err = loadfile(path, "t", env)
    if not chunk then error("sandbox: " .. err, 2) end
    local result = chunk(name)
    if result == nil then result = true end
    loaded[name] = result
    return result
  end

  for k, v in pairs(globals or {}) do env[k] = v end
  env.require = sandbox_require
  env._G = env
  setmetatable(env, {
    __index = function(_, k)
      if BLOCKED[k] then error("sandbox: core referenced global '" .. k .. "'", 2) end
      return _G[k]
    end,
  })

  return {
    env = env,
    require = sandbox_require,
    run_file = function(path)
      local chunk, err = loadfile(path, "t", env)
      if not chunk then error(err, 0) end
      return chunk()
    end,
  }
end

-- ── assertion helpers ───────────────────────────────────────────────────────

local function is_identifier(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function inspect(v, indent, seen)
  indent = indent or ""
  seen = seen or {}
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local keys = sorted_keys(v)
  if #keys == 0 then
    seen[v] = nil
    return "{}"
  end
  local inner = indent .. "  "
  local parts = {}
  for _, k in ipairs(keys) do
    local key = is_identifier(k) and k or ("[" .. inspect(k) .. "]")
    table.insert(parts, inner .. key .. " = " .. inspect(v[k], inner, seen))
  end
  seen[v] = nil
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end
M.inspect = inspect

-- Returns nil when equal, else the path of the first difference.
local function first_difference(a, b, path)
  if type(a) ~= "table" or type(b) ~= "table" then
    if a == b then return nil end
    return path
  end
  for _, k in ipairs(sorted_keys(a)) do
    local d = first_difference(a[k], b[k], path .. "." .. tostring(k))
    if d then return d end
  end
  for _, k in ipairs(sorted_keys(b)) do
    if a[k] == nil then return path .. "." .. tostring(k) end
  end
  return nil
end

function M.helpers()
  local h = {}

  function h.eq(actual, expected, message)
    local diff = first_difference(actual, expected, "value")
    if diff then
      error(string.format("%sdiffers at %s\nexpected: %s\nactual:   %s",
        message and (message .. ": ") or "", diff, inspect(expected), inspect(actual)), 2)
    end
  end

  function h.ok(value, message)
    if not value then error(message or "expected a truthy value", 2) end
  end

  function h.fails(fn, pattern)
    local ok, err = pcall(fn)
    if ok then error("expected an error" .. (pattern and (" matching '" .. pattern .. "'") or ""), 2) end
    if pattern and not tostring(err):find(pattern) then
      error(string.format("error did not match '%s': %s", pattern, tostring(err)), 2)
    end
    return err
  end

  -- For callback APIs on the fake transport: the test calls done() from its
  -- final callback; flushing runs any deferred callbacks first.
  function h.async(fake, fn)
    local done = false
    fn(function() done = true end)
    fake:flush()
    if not done then error("callback never ran, even after fake:flush()", 2) end
  end

  return h
end

return M
