-- A query list (RFC 0001 R9): the work items one fixed query finds in the
-- configured projects, under the location's filters. Its rows stand for
-- no relationship, so the change plan (core/plan.lua) treats them apart
-- from area view rows.
--
--   view = { location, projects = { name... }, items = { normalised item... },
--            rows = { row... }, truncated = bool, total = n,
--            catalogs = { [project] = catalog } or nil when the state
--            filter is not "open" }
--   row  = { kind = "item", id, rev, type, state, assignee, tags, title, ... }
--          (core/workitem.lua row)
local location = require("ado.core.location")
local query = require("ado.core.query")
local gateway = require("ado.core.gateway")
local urls = require("ado.core.urls")
local wiql = require("ado.core.wiql")
local workitem = require("ado.core.workitem")

local M = {}

local BROWSER_FIELDS = {
  "System.Id", "System.WorkItemType", "System.Title", "System.State",
  "System.AssignedTo", "System.Tags", "System.AreaPath",
}

-- projects: the project names the list covers. catalogs: { [project] =
-- catalog }, required when the state filter is "open". opts.open_types:
-- { [project] = { type... } } limits each project's open condition to
-- those types; opts.select: the fields.
function M.spec(loc, projects, catalogs, opts)
  opts = opts or {}
  local f = loc.filters
  local opens
  if f.state == "open" then
    opens = {}
    for i, name in ipairs(projects) do
      local wanted = f.types
      if opts.open_types then wanted = opts.open_types[name] or {} end
      opens[i] = catalogs[name]:open_condition(wanted)
    end
  end
  -- Each project's open condition goes in the scope, paired with its project.
  return query.list(query.filter_conditions(f), query.scope(projects, opens),
    opts.select or workitem.ROW_FIELDS)
end

-- Loads a view with 1 query, after the type catalog of each project the
-- session has not loaded yet when the state filter is "open" (1 call per
-- project).
-- opts.on_progress(done, total, what), what = "items".
-- cb(err, view).
function M.load(session, loc, opts, cb)
  opts = opts or {}
  local progress = opts.on_progress or function() end
  local projects = session:project_names()
  if #projects == 0 then
    return cb(gateway.error("invalid", "a project is required to list work items"))
  end
  local view = { location = loc, projects = projects }
  local function run(catalogs)
    view.catalogs = catalogs
    session:query(M.spec(loc, projects, catalogs), function(err, items, info)
      if err then return cb(err) end
      view.items, view.truncated, view.total = items, info.truncated, info.total
      view.rows = {}
      for _, it in ipairs(items) do table.insert(view.rows, workitem.row(it)) end
      progress(1, 1, "items")
      cb(nil, view)
    end)
  end
  if loc.filters.state ~= "open" then return run(nil) end
  session:catalogs_for_projects(function(err, list)
    if err then return cb(err) end
    local catalogs = {}
    for i, name in ipairs(projects) do catalogs[name] = list[i] end
    run(catalogs)
  end)
end

-- The location selecting a row leads to: the item's item view.
function M.select(_, row)
  return location.item(row.id)
end

-- The browser URL for a loaded view's query, or nil and an error of kind
-- "invalid" when ADO's web UI would reject its length. As in the area
-- view (docs/architecture.md#area-view), an open-state list that is not
-- truncated limits each project's open condition to the types it loaded.
function M.browser_url(org, view)
  local open_types
  if view.location.filters.state == "open" and not view.truncated then
    open_types = {}
    local seen = {}
    for _, it in ipairs(view.items) do
      local key = it.project .. "\0" .. it.type
      if not seen[key] then
        seen[key] = true
        open_types[it.project] = open_types[it.project] or {}
        table.insert(open_types[it.project], it.type)
      end
    end
  end
  local spec = M.spec(view.location, view.projects, view.catalogs,
    { select = BROWSER_FIELDS, open_types = open_types })
  local url = urls.query(org, view.projects[1], wiql.render(spec))
  if #url > urls.MAX_QUERY_URL then
    return nil, gateway.error("invalid", string.format(
      "the browser query URL is %d characters; ADO's web UI rejects more than about %d",
      #url, urls.MAX_QUERY_URL), { length = #url })
  end
  return url
end

return M
