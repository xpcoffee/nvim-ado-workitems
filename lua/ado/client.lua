-- The only module that shells out to `az`. All calls are async via vim.system;
-- callbacks are scheduled onto the main loop so callers may touch the nvim API
-- freely. Org (and project where required) are threaded per-call from config;
-- we never mutate the user's global `az devops configure` defaults.
local config = require("ado.config")

local M = {}

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
  end)
end

-- Map az's noisier failure stderr onto a single actionable line.
local function friendly_error(stderr)
  local s = (stderr or ""):lower()
  if s:find("az login") or s:find("run the login command")
      or s:find("refresh token") or s:find("aadsts") then
    return "auth expired - run `az login` (then `az devops login` if prompted)"
  end
  return (stderr ~= nil and stderr ~= "") and stderr or "az command failed"
end

local function finish(cb, ok, data, err)
  vim.schedule(function()
    cb(ok, data, err)
  end)
end

local function org_args()
  return { "--org", "https://dev.azure.com/" .. config.get().org }
end

-- args: full argv starting with "az". opts.raw returns stdout unparsed.
local function run(args, cb, opts)
  opts = opts or {}
  if vim.fn.executable("az") ~= 1 then
    notify("az CLI not found", vim.log.levels.ERROR)
    finish(cb, false, nil, "az not found")
    return
  end
  vim.system(args, { text = true }, function(res)
    if res.code ~= 0 then
      local err = friendly_error(res.stderr)
      notify(err, vim.log.levels.ERROR)
      finish(cb, false, nil, err)
      return
    end
    if opts.raw then
      finish(cb, true, res.stdout, nil)
      return
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout or "")
    if not ok then
      notify("failed to parse az output", vim.log.levels.ERROR)
      finish(cb, false, nil, "json decode failed")
      return
    end
    finish(cb, true, decoded, nil)
  end)
end
M.run = run

-- Work items are org-unique, so show/update need no project.
function M.show(id, cb)
  local args = { "az", "boards", "work-item", "show", "--id", tostring(id), "--output", "json" }
  vim.list_extend(args, org_args())
  run(args, cb)
end

function M.query(wiql, cb)
  local c = config.get()
  local args = { "az", "boards", "query", "--wiql", wiql, "--output", "json" }
  vim.list_extend(args, org_args())
  if c.project then
    vim.list_extend(args, { "--project", c.project })
  end
  run(args, cb)
end

-- fields: any of { title, state, assignee, iteration, tags, description }.
-- Prefer dedicated flags; only System.Tags lacks one. All changes go in one call.
function M.update(id, fields, cb)
  local args = { "az", "boards", "work-item", "update", "--id", tostring(id), "--output", "json" }
  if fields.title then vim.list_extend(args, { "--title", fields.title }) end
  if fields.state then vim.list_extend(args, { "--state", fields.state }) end
  if fields.assignee then vim.list_extend(args, { "--assigned-to", fields.assignee }) end
  if fields.iteration then vim.list_extend(args, { "--iteration", fields.iteration }) end
  if fields.description then vim.list_extend(args, { "--description", fields.description }) end
  if fields.tags then
    -- --fields takes space-separated field=value pairs; the value itself holds
    -- semicolons, so it must arrive as one argv element.
    vim.list_extend(args, { "--fields", "System.Tags=" .. fields.tags })
  end
  vim.list_extend(args, org_args())
  run(args, cb)
end

function M.add_comment(id, text, cb)
  local args = { "az", "boards", "work-item", "update", "--id", tostring(id),
    "--discussion", text, "--output", "json" }
  vim.list_extend(args, org_args())
  run(args, cb)
end

-- Resolve a project (queries and state lookups need one) via opts/env, else a
-- one-time picker over the org's projects, cached for the session.
function M.ensure_project(cb)
  if config.get().project then
    cb(true)
    return
  end
  local args = { "az", "devops", "project", "list", "--output", "json" }
  vim.list_extend(args, org_args())
  run(args, function(ok, data)
    if not ok then cb(false) return end
    local names = {}
    for _, p in ipairs((data and data.value) or {}) do
      table.insert(names, p.name)
    end
    if #names == 0 then
      notify("no projects found in org", vim.log.levels.WARN)
      cb(false)
      return
    end
    vim.ui.select(names, { prompt = "ADO project" }, function(choice)
      if not choice then cb(false) return end
      config.set_project(choice)
      cb(true)
    end)
  end)
end

-- Valid states for a work-item type, cached per type. Requires a project.
function M.states(wtype, cb)
  local cached = config.get_states(wtype)
  if cached then cb(true, cached) return end
  M.ensure_project(function(ok)
    if not ok then cb(false) return end
    local c = config.get()
    local args = { "az", "devops", "invoke",
      "--area", "wit", "--resource", "workitemtypestates",
      "--route-parameters", "project=" .. c.project, "type=" .. wtype,
      "--api-version", "6.0", "--output", "json" }
    vim.list_extend(args, org_args())
    run(args, function(ok2, data)
      if not ok2 then cb(false) return end
      local names = {}
      for _, s in ipairs((data and data.value) or {}) do
        table.insert(names, s.name)
      end
      config.cache_states(wtype, names)
      cb(true, names)
    end)
  end)
end

return M
