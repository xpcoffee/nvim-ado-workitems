-- Test runner. Runs under Neovim's LuaJIT:
--   nvim --headless -u NONE -l tests/run.lua [core]
-- Order: static scan of lua/ado/core, the core suite in the sandbox, then the
-- presentation suite with the real vim. Exits non-zero on any failure.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local only_core = (arg and arg[1]) == "core"

-- No test may reach `az`, pandoc or the network. These are replaced for the
-- whole run, so a spec that exercises the az transport injects `system`.
local function forbid(name)
  return function()
    error("tests must not start processes: " .. name .. " was called", 2)
  end
end
vim.system = forbid("vim.system")
vim.fn.system = forbid("vim.fn.system")
vim.fn.systemlist = forbid("vim.fn.systemlist")
vim.fn.jobstart = forbid("vim.fn.jobstart")
io.popen = forbid("io.popen")
os.execute = forbid("os.execute")

package.path = root .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(root)

local sandbox = dofile(root .. "/tests/support/sandbox.lua")

local passed, failed = 0, 0
local failures = {}

local function out(s)
  io.stdout:write(s .. "\n")
end

local function rel(path)
  return path:sub(#root + 2)
end

local function record(label, ok, err)
  if ok then
    passed = passed + 1
    out("ok    " .. label)
  else
    failed = failed + 1
    out("FAIL  " .. label)
    out("      " .. tostring(err):gsub("\n", "\n      "))
    table.insert(failures, label)
  end
end

-- Backstop for core code paths no test runs (RFC 0001 R6.1). It matches
-- comments and strings too, deliberately: core text never needs `vim.`.
local function static_scan()
  local patterns = {
    { "vim%.", "references vim" },
    { "require%s*%(?%s*[\"']ado%.nvim", "requires a presentation module" },
  }
  local hits = {}
  for _, path in ipairs(vim.fn.glob(root .. "/lua/ado/core/**/*.lua", false, true)) do
    local n = 0
    for line in io.lines(path) do
      n = n + 1
      for _, p in ipairs(patterns) do
        if line:find(p[1]) then
          table.insert(hits, string.format("%s:%d %s: %s", rel(path), n, p[2], line))
        end
      end
    end
  end
  record("static scan: lua/ado/core has no vim and no ado.nvim requires",
    #hits == 0, table.concat(hits, "\n"))
end

-- make_env(helpers) exposes the helpers to the spec: it returns a sandbox for
-- core specs, and sets real globals for presentation specs.
local function run_spec(path, make_env, run_in)
  local tests = {}
  local helpers = sandbox.helpers()
  helpers.test = function(name, fn) table.insert(tests, { name = name, fn = fn }) end
  local ok, err = pcall(function()
    run_in(make_env(helpers), path)
  end)
  if not ok then
    record(rel(path) .. ": load", false, err)
    return
  end
  for _, t in ipairs(tests) do
    local tok, terr = xpcall(t.fn, debug.traceback)
    record(rel(path) .. ": " .. t.name, tok, terr)
  end
end

local function specs(dir)
  local list = vim.fn.glob(root .. "/tests/" .. dir .. "/*_spec.lua", false, true)
  table.sort(list)
  return list
end

static_scan()

for _, path in ipairs(specs("core")) do
  run_spec(path, function(helpers)
    return sandbox.new(root, helpers)
  end, function(box, p)
    box.run_file(p)
  end)
end

if not only_core then
  for _, path in ipairs(specs("nvim")) do
    run_spec(path, function(helpers)
      for k, v in pairs(helpers) do _G[k] = v end
    end, function(_, p)
      dofile(p)
    end)
  end
end

out(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  out("failed:\n  " .. table.concat(failures, "\n  "))
  os.exit(1)
end
os.exit(0)
