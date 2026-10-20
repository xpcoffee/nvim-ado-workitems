-- One session per editor: the gateway, org, the projects lists cover, and
-- a type catalog per project. Presentation code calls the core through these
-- methods; every callback is cb(err, result).
local area_path = require("ado.core.area_path")
local location = require("ado.core.location")
local people = require("ado.core.people")
local query = require("ado.core.query")
local query_view = require("ado.core.query_view")
local requests = require("ado.core.requests")
local gateway = require("ado.core.gateway")
local types = require("ado.core.types")
local workitem = require("ado.core.workitem")

local M = {}

local Session = {}
Session.__index = Session

local function check_projects(projects)
  if projects == nil then return end
  if type(projects) ~= "table" then error("projects must be a list", 3) end
  for i, p in ipairs(projects) do
    if type(p) ~= "table" or type(p.name) ~= "string" or p.name == "" then
      error("projects[" .. i .. "] needs a name", 3)
    end
    if p.types ~= nil and type(p.types) ~= "table" then
      error("projects[" .. i .. "].types must be a list of type names", 3)
    end
  end
end

-- opts: gateway (required), org, projects ({ { name, types }... }, the
-- projects lists cover) or, when projects is nil, project (the one project,
-- nil until chosen), query_top, open_categories (default
-- types.DEFAULT_OPEN_CATEGORIES), default_types (the types of new lines,
-- { area, children }; core/plan.lua has the default), on_event (function(event), told
-- { kind = "catalog_loaded", project, types, calls, fallback } and, when the
-- project's configured types name types its catalog lacks,
-- { kind = "unknown_types", project, unknown = { name... }, valid = { name... } }).
function M.new(opts)
  gateway.validate(opts.gateway)
  local projects = opts.projects or nil
  check_projects(projects)
  return setmetatable({
    gateway = opts.gateway,
    org = opts.org,
    projects = projects,
    project = opts.project,
    query_top = opts.query_top or 200,
    open_categories = opts.open_categories or types.DEFAULT_OPEN_CATEGORIES,
    default_types = opts.default_types,
    on_event = opts.on_event or function() end,
    -- project name -> { catalog = c } or { waiters = { cb... } } while loading
    catalogs = {},
  }, Session)
end

-- Only used without configured projects, where the one project is chosen
-- after the session starts.
function Session:set_project(name)
  self.project = name
end

-- The projects lists cover: the configured ones, else the one chosen
-- project with no configured types, else none.
function Session:project_list()
  if self.projects then return self.projects end
  if self.project then return { { name = self.project } } end
  return {}
end

function Session:project_names()
  local names = {}
  for _, p in ipairs(self:project_list()) do table.insert(names, p.name) end
  return names
end

function Session:default_project()
  local first = self:project_list()[1]
  return first and first.name
end

function Session:normalise(raw)
  return workitem.normalise(raw, self.org)
end

function Session:list_projects(cb)
  self.gateway.list_projects({}, cb)
end

-- az boards query has no --top, so the result is capped here at query_top.
-- cb(err, items, info): info.truncated is true when the cap dropped items.
-- az itself stops fetching items once it holds 1,000, checking only between
-- batches (azext_devops boards/work_item.py), so info.total is a lower bound
-- once it reaches 1,000.
function Session:query(spec, cb)
  local params = query.request(spec)
  params.project = self:default_project()
  self.gateway.query(params, function(err, raws)
    if err then return cb(err) end
    raws = raws or {}
    local items = {}
    for i, raw in ipairs(raws) do
      if i > self.query_top then break end
      table.insert(items, self:normalise(raw))
    end
    cb(nil, items, { total = #raws, truncated = #raws > self.query_top })
  end)
end

-- The direct sub-areas of an area path (field form), as
-- { { name, path (field form), has_children }... }.
function Session:area_children(path, cb)
  self.gateway.area_children({ project = area_path.project(path), path = area_path.to_node(path) },
    function(err, nodes)
      if err then return cb(err) end
      local out = {}
      for _, n in ipairs(nodes or {}) do
        table.insert(out, { name = n.name, path = area_path.from_node(n.path), has_children = n.hasChildren == true })
      end
      cb(nil, out)
    end)
end

function Session:get(id, cb)
  self.gateway.get_work_item({ id = id }, function(err, raw)
    if err then return cb(err) end
    cb(nil, self:normalise(raw))
  end)
end

-- The item with item.relations = workitem.relations(raw): its parent,
-- children and other work item links.
function Session:get_with_relations(id, cb)
  self.gateway.get_work_item({ id = id, relations = true }, function(err, raw)
    if err then return cb(err) end
    local item = self:normalise(raw)
    item.relations = workitem.relations(raw)
    cb(nil, item)
  end)
end

-- cb(nil) when ADO still holds the rev `item` was loaded at, else a
-- "conflict" error: the revision guard (RFC 0001 R5.14).
function Session:check_rev(item, cb)
  self.gateway.get_work_item({ id = item.id }, function(err, raw)
    if err then return cb(err) end
    if raw.rev ~= item.rev then
      return cb(gateway.error("conflict",
        string.format("#%s changed remotely (rev %s -> %s)", item.id, tostring(item.rev), tostring(raw.rev)),
        { expected_rev = item.rev, actual_rev = raw.rev }))
    end
    cb(nil)
  end)
end

-- changes: friendly names from workitem.FIELD_REFS, e.g. { state = "Active" },
-- sent as one patch that ADO applies only if it still holds the rev `item`
-- was loaded at, so a concurrent edit made elsewhere is not overwritten.
-- After a remote change, cb gets a "conflict" error with expected_rev and,
-- when ADO's message names it, actual_rev.
function Session:update_if_unchanged(item, changes, cb)
  local patch = requests.fields_patch(workitem.to_fields(changes), item.rev)
  self:patch(item.id, patch, function(err, updated)
    if err and err.kind == "conflict" then
      -- ADO's message: "Test Operation for path /rev failed, value 2 was
      -- not equal to test value 1."
      local actual = tonumber(tostring(err.message):match("value (%d+) was not equal"))
      return cb(gateway.error("conflict", string.format("#%s changed remotely (rev %s -> %s)",
        item.id, tostring(item.rev), actual and tostring(actual) or "?"),
        { expected_rev = item.rev, actual_rev = actual }))
    end
    cb(err, updated)
  end)
end

-- Sends a JSON Patch (core/requests.lua) to item `id` as one write.
function Session:patch(id, patch, cb)
  self.gateway.patch_work_item({ id = id, patch = patch }, function(err, raw)
    if err then return cb(err) end
    cb(nil, self:normalise(raw))
  end)
end

-- fields = { type, title, area (field form), tags, assignee (a unique
-- name) | nil, parent | nil }, sent as one write; the project is the
-- area's. ADO gives the item its type's initial state.
function Session:create(fields, cb)
  self.gateway.create_work_item({ project = area_path.project(fields.area), type = fields.type,
    patch = requests.create_patch(fields, self.org) }, function(err, raw)
    if err then return cb(err) end
    cb(nil, self:normalise(raw))
  end)
end

-- The identities whose name or email starts with text:
-- { { display_name, unique_name, mail, id }... }. opts.quiet: the caller
-- reports a failure itself, so the presentation layer's notifier skips it.
function Session:resolve_identity(text, cb, opts)
  self.gateway.resolve_identity({ text = text, quiet = opts and opts.quiet or nil }, cb)
end

-- The session's people search (core/people.lua), made on first use, so
-- its cache and recent picks last as long as the session.
function Session:people()
  self.people_search = self.people_search or people.new(self)
  return self.people_search
end

-- One page of item id's comments, newest first, after the page whose
-- continuation token is token (nil: the first page). Quiet: the item
-- buffer reports a failed page in its footer line (RFC 0003 C4.7).
-- cb(err, { comments = { raw... }, total, token }).
function Session:list_comments(id, project, token, top, cb)
  self.gateway.list_comments({ id = id, project = project, top = top, token = token, quiet = true }, cb)
end

function Session:add_comment(id, text, cb)
  self.gateway.add_comment({ id = id, text = text }, function(err, raw)
    if err then return cb(err) end
    cb(nil, self:normalise(raw))
  end)
end

-- The configured types of project that its catalog does not have.
local function unknown_types(projects, project, catalog)
  local out = {}
  for _, p in ipairs(projects) do
    if p.name == project then
      for _, name in ipairs(p.types or {}) do
        if not catalog:states(name) then table.insert(out, name) end
      end
    end
  end
  return out
end

-- The type catalog of one project, loaded on first use and kept for the
-- session. Callers that ask while the load is in flight wait for it instead
-- of starting another. A failed load is not cached, so the next call retries.
function Session:catalog(project, cb)
  if not project then
    return cb(gateway.error("invalid", "a project is required to load work item types"))
  end
  local entry = self.catalogs[project]
  -- A cache hit calls back before catalog() returns.
  if entry and entry.catalog then return cb(nil, entry.catalog) end
  if entry then
    table.insert(entry.waiters, cb)
    return
  end
  entry = { waiters = { cb } }
  self.catalogs[project] = entry
  types.load(self.gateway, project, self.open_categories, function(err, catalog, info)
    local waiters = entry.waiters
    if err then
      self.catalogs[project] = nil
    else
      self.catalogs[project] = { catalog = catalog }
      self.on_event({ kind = "catalog_loaded", project = project, types = #catalog.types,
        calls = info.calls, fallback = info.fallback })
      -- Warned here rather than at setup(), because only the catalog knows
      -- the project's types; a cached catalog loads once, so this warns once.
      local unknown = unknown_types(self:project_list(), project, catalog)
      if #unknown > 0 then
        self.on_event({ kind = "unknown_types", project = project, unknown = unknown, valid = catalog:names() })
      end
    end
    for _, w in ipairs(waiters) do w(err, catalog) end
  end)
end

-- The project's catalog when it is already loaded, else nil; never calls.
function Session:cached_catalog(project)
  local entry = project and self.catalogs[project]
  return entry and entry.catalog or nil
end

-- The catalog of every project in project_list(), in that order, loaded one
-- project at a time.
function Session:catalogs_for_projects(cb)
  local names = self:project_names()
  if #names == 0 then
    return cb(gateway.error("invalid", "a project is required to load work item types"))
  end
  local out = {}
  local function next_project(i)
    if i > #names then return cb(nil, out) end
    self:catalog(names[i], function(err, catalog)
      if err then return cb(err) end
      out[i] = catalog
      next_project(i + 1)
    end)
  end
  next_project(1)
end

-- The query condition for lists: the projects in project_list(), and with
-- open = true, each item's state open by its own project's catalog.
function Session:scope(open, cb)
  local names = self:project_names()
  if not open then return cb(nil, query.scope(names)) end
  self:catalogs_for_projects(function(err, catalogs)
    if err then return cb(err) end
    local opens = {}
    for i, c in ipairs(catalogs) do opens[i] = c:open_condition() end
    cb(nil, query.scope(names, opens))
  end)
end

-- Valid state names for a type in a project (default_project() when nil),
-- from that project's catalog.
function Session:states(wtype, project, cb)
  project = (project ~= nil and project ~= "") and project or self:default_project()
  self:catalog(project, function(err, catalog)
    if err then return cb(err) end
    local names = catalog:states(wtype)
    if not names then
      return cb(gateway.error("not_found", string.format(
        "work item type %s is not in the catalog of project %s", tostring(wtype), tostring(project))))
    end
    cb(nil, names)
  end)
end

-- Items assigned to the current user, in an open state (RFC 0002 R1.1):
-- the rows of the "mine" query list with its default filters.
-- cb(err, items, info) as for query().
function Session:my_items(cb)
  query_view.load(self, location.query("mine"), {}, function(err, view)
    if err then return cb(err) end
    cb(nil, view.items, { total = view.total, truncated = view.truncated })
  end)
end

-- Text search over title and description. Open states only unless
-- opts.all_states (RFC 0002 R1.4); that form needs no catalog.
function Session:search(text, opts, cb)
  self:scope(not (opts and opts.all_states), function(err, scope)
    if err then return cb(err) end
    self:query(query.text_search(text, scope), cb)
  end)
end

return M
