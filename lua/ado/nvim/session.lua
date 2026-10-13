-- The editor's one core session, built from config on first use, and the
-- project chooser that queries and state lookups need.
local config = require("ado.config")
local core_session = require("ado.core.session")
local progress = require("ado.nvim.progress")
local transport = require("ado.core.transport")
local write_guard = require("ado.core.write_guard")

local M = {}

local current
local muted = 0

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local function on_event(event)
  if event.kind == "catalog_loaded" then
    local msg = string.format("loaded %d work item types for %s (%d %s)", event.types, event.project,
      event.calls, event.calls == 1 and "call" or "calls")
    if #event.fallback > 0 then
      msg = msg .. "; states fetched per type for " .. table.concat(event.fallback, ", ")
    end
    progress.echo(msg)
  elseif event.kind == "unknown_types" then
    local quoted = {}
    for _, name in ipairs(event.unknown) do table.insert(quoted, "'" .. name .. "'") end
    notify(string.format("types configured for project %s that it does not have: %s; its types are %s",
      event.project, table.concat(quoted, ", "), table.concat(event.valid, ", ")), vim.log.levels.WARN)
  end
end

-- Every transport failure is reported once here, so call sites only decide
-- what to do next, except while errors are muted. A conflict is left to the
-- caller, which knows the rev it expected and how the user can recover.
local function notify_errors(t)
  local wrapped = {}
  for name, fn in pairs(t) do
    if type(fn) == "function" then
      wrapped[name] = function(params, cb)
        fn(params, function(err, result)
          if err and err.kind ~= "conflict" and muted == 0 then notify(err.message, vim.log.levels.ERROR) end
          cb(err, result)
        end)
      end
    end
  end
  return transport.validate(wrapped)
end

function M.get()
  if not current then
    local c = config.get()
    local t = c.transport or require("ado.nvim.az").new({ org = c.org })
    -- Order: transport, write guard, notifier, so refusals are notified and
    -- the guard sees raw errors. Callers of core Session methods must not
    -- notify transport errors again. See docs/architecture.md.
    if c.write_guard then t = write_guard.wrap(t, c.write_guard) end
    current = core_session.new({
      transport = notify_errors(t),
      org = c.org,
      projects = c.projects,
      project = c.project,
      query_top = c.default_query_top,
      open_categories = c.open_categories,
      default_types = c.default_types,
      on_event = on_event,
    })
  end
  return current
end

-- A save reports its failure in its own report, so it mutes the
-- notifications of transport failures while it applies; calls pair
-- mute_errors(true) with mute_errors(false).
function M.mute_errors(on)
  muted = math.max(0, muted + (on and 1 or -1))
end

-- Drops the session so the next get() rebuilds it from config.
function M.reset()
  current = nil
  muted = 0
end

-- Resolve a project (queries and state lookups need one): the configured
-- projects, else opts/env, else a one-time picker over the org's projects,
-- kept for the session.
function M.ensure_project(cb)
  local s = M.get()
  if s:default_project() then
    cb(true)
    return
  end
  s:list_projects(function(err, names)
    if err then cb(false) return end
    if #names == 0 then
      notify("no projects found in org", vim.log.levels.WARN)
      cb(false)
      return
    end
    vim.ui.select(names, { prompt = "ADO project" }, function(choice)
      if not choice then cb(false) return end
      s:set_project(choice)
      cb(true)
    end)
  end)
end

return M
