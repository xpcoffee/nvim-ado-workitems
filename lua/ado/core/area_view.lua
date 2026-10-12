-- The area view (RFC 0001 R2): one area location's direct sub-areas, then its
-- work items under the location's filters.
--
--   view = { location, areas = { { name, path, has_children }... },
--            items = { normalised item... }, rows = { row... },
--            truncated = bool, total = n, catalog = the project's catalog or nil }
--   row  = { kind = "area", path, name }
--        | { kind = "item", id, rev, type, state, assignee, tags, title }
local area_path = require("ado.core.area_path")
local location = require("ado.core.location")
local transport = require("ado.core.transport")
local urls = require("ado.core.urls")
local wiql = require("ado.core.wiql")
local workitem = require("ado.core.workitem")

local M = {}

M.FIELDS = workitem.ROW_FIELDS

local BROWSER_FIELDS = {
  "System.Id", "System.WorkItemType", "System.Title", "System.State",
  "System.AssignedTo", "System.Tags", "System.AreaPath",
}

local function is_me(assignee)
  return type(assignee) == "string" and assignee:lower() == "@me"
end

-- catalog: the area's project catalog, required when the state filter is
-- "open". opts.open_types limits the open condition to those types.
function M.spec(loc, catalog, opts)
  opts = opts or {}
  local f = loc.filters
  local conds = {
    { field = "System.TeamProject", op = "IN", value = { area_path.project(loc.path) } },
    { field = "System.AreaPath", op = loc.sub and "UNDER" or "=", value = loc.path },
  }
  if f.state == "open" then
    table.insert(conds, catalog:open_condition(opts.open_types or f.types))
  else
    if type(f.state) == "table" then
      table.insert(conds, { field = "System.State", op = "IN", value = f.state })
    end
    if f.types then
      table.insert(conds, { field = "System.WorkItemType", op = "IN", value = f.types })
    end
  end
  if is_me(f.assignee) then
    table.insert(conds, { field = "System.AssignedTo", op = "=", value = { macro = "Me" } })
  elseif f.assignee then
    table.insert(conds, { field = "System.AssignedTo", op = "=", value = f.assignee })
  end
  if f.tag then
    table.insert(conds, { field = "System.Tags", op = "CONTAINS", value = f.tag })
  end
  return {
    select = opts.select or M.FIELDS,
    where = { all = conds },
    order_by = { { field = "System.ChangedDate", desc = true } },
  }
end

local function rows(view)
  local out = {}
  for _, a in ipairs(view.areas) do
    table.insert(out, { kind = "area", path = a.path, name = a.name })
  end
  for _, it in ipairs(view.items) do table.insert(out, workitem.row(it)) end
  return out
end

-- Loads a view with 2 calls, area_children and query, run together. An
-- open-state view also needs the project's catalog, which costs 1 more call
-- the first time the session needs that project.
-- opts.on_progress(done, total, what), what = "sub-areas" | "items".
-- cb(err, view) runs once; the first failure is the error.
function M.load(session, loc, opts, cb)
  opts = opts or {}
  local progress = opts.on_progress or function() end
  local view = { location = loc }
  local pending, finished, done = 2, false, 0

  local function step(err, what)
    if finished then return end
    if err then
      finished = true
      return cb(err)
    end
    done = done + 1
    progress(done, 2, what)
    pending = pending - 1
    if pending == 0 then
      finished = true
      view.rows = rows(view)
      cb(nil, view)
    end
  end

  session:area_children(loc.path, function(err, areas)
    if not err then
      table.sort(areas, function(a, b) return a.name:lower() < b.name:lower() end)
      view.areas = areas
    end
    step(err, "sub-areas")
  end)

  local function run_query(catalog)
    view.catalog = catalog
    session:query(M.spec(loc, catalog), function(err, items, info)
      if not err then
        view.items = items
        view.truncated = info.truncated
        view.total = info.total
      end
      step(err, "items")
    end)
  end
  if loc.filters.state == "open" then
    session:catalog(area_path.project(loc.path), function(err, catalog)
      if err then return step(err) end
      run_query(catalog)
    end)
  else
    run_query(nil)
  end
end

-- The location selecting a row leads to: a sub-area with this view's
-- filters (R2.3), or the item's item view (R2.7).
function M.select(view, row)
  if row.kind == "area" then return location.at(view.location, row.path) end
  return location.item(row.id)
end

-- The browser URL for a loaded view's query (R2.8), or nil and an error of
-- kind "invalid" when ADO's web UI would reject its length. Why the open
-- condition is limited to the loaded types: docs/architecture.md#area-view.
function M.browser_url(org, view)
  local open_types
  if view.location.filters.state == "open" and not view.truncated then
    local seen = {}
    open_types = {}
    for _, it in ipairs(view.items) do
      if not seen[it.type] then
        seen[it.type] = true
        table.insert(open_types, it.type)
      end
    end
  end
  local spec = M.spec(view.location, view.catalog, { select = BROWSER_FIELDS, open_types = open_types })
  local url = urls.query(org, area_path.project(view.location.path), wiql.render(spec))
  if #url > urls.MAX_QUERY_URL then
    return nil, transport.error("invalid", string.format(
      "the browser query URL is %d characters; ADO's web UI rejects more than about %d",
      #url, urls.MAX_QUERY_URL), { length = #url })
  end
  return url
end

return M
