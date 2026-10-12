-- The item view (RFC 0001 R3): one work item, its parent, its area, its
-- children, and its other links grouped by link type.
--
--   view    = { location, item, parent = item | nil, parent_unreadable = bool,
--               area = field path,
--               children = section, sections = { section... },
--               truncated = bool, catalogs = { [project] = catalog } }
--   section = { rel, name, items = { item... }, unreadable = n }
--   display = { view, location, expanded = { [id] = { item... } } }
--
-- A view is what was loaded; a display is one showing of it. Expansion
-- (R3.4) belongs to the display, so each new display of a location starts
-- collapsed (RFC 0001 section 4, Location).
--
--   row = { kind = "item", slot = "self" | "parent" | "child" | "link",
--           id, rev, type, state, assignee, tags, title, depth,
--           block_parent (child rows under an expanded row), rel (link rows) }
--       | { kind = "field", slot = "self", id, field, value } (the viewed
--           item's metadata, one line per field beneath its title)
--       | { kind = "area", slot = "area", path, name }
--       | { kind = "heading", slot = "parent" | "children" | "link", rel, label }
local location = require("ado.core.location")
local transport = require("ado.core.transport")
local workitem = require("ado.core.workitem")

local M = {}

M.HIERARCHY = "System.LinkTypes.Hierarchy"
M.DEFAULT_LINK_TYPES = { M.HIERARCHY, "System.LinkTypes.Related" }

-- Children and links in a stable order, so rows do not move between loads.
local BY_ID = { { field = "System.Id" } }

function M.related_spec(ids)
  return { select = workitem.ROW_FIELDS, where = { field = "System.Id", op = "IN", value = ids }, order_by = BY_ID }
end

function M.children_spec(id)
  return { select = workitem.ROW_FIELDS, where = { field = "System.Parent", op = "=", value = id }, order_by = BY_ID }
end

-- A link type names a family: "System.LinkTypes.Dependency" covers its
-- -Forward and -Reverse ends.
local function wanted(link_types, rel)
  for _, t in ipairs(link_types) do
    if rel == t or rel:sub(1, #t + 1) == t .. "-" then return true end
  end
  return false
end

-- Sections for the links in link_types, in that order, one per link end
-- in the order the item lists them.
local function link_sections(links, link_types)
  local sections, by_rel = {}, {}
  for _, t in ipairs(link_types) do
    for _, l in ipairs(links) do
      if wanted({ t }, l.rel) then
        local s = by_rel[l.rel]
        if not s then
          s = { rel = l.rel, name = l.name, ids = {} }
          by_rel[l.rel] = s
          table.insert(sections, s)
        end
        table.insert(s.ids, l.id)
      end
    end
  end
  return sections
end

local function load_catalogs(session, catalogs, items, cb)
  local projects, seen = {}, {}
  for _, it in ipairs(items) do
    if it.project ~= "" and not catalogs[it.project] and not seen[it.project] then
      seen[it.project] = true
      table.insert(projects, it.project)
    end
  end
  local function next_project(i)
    if i > #projects then return cb(nil) end
    session:catalog(projects[i], function(err, catalog)
      if err then return cb(err) end
      catalogs[projects[i]] = catalog
      next_project(i + 1)
    end)
  end
  next_project(1)
end

local function section_of(ids, by_id, rel, name)
  local s = { rel = rel, name = name, items = {}, unreadable = 0 }
  for _, id in ipairs(ids) do
    if by_id[id] then table.insert(s.items, by_id[id]) else s.unreadable = s.unreadable + 1 end
  end
  table.sort(s.items, function(a, b) return a.id < b.id end)
  return s
end

-- Loads a view with 2 calls: get_work_item with relations, then one query
-- for every linked item (skipped when there are none), plus 1 per project
-- whose catalog the session has not loaded. Children and links are fetched
-- in every state, so the all-states toggle needs no fetch (R3.8).
-- opts.link_types (default DEFAULT_LINK_TYPES) limits the link sections; the
-- parent and children always show (R3.1).
-- opts.on_progress(done, total, what), what = "item" | "links".
-- cb(err, view) runs once.
function M.load(session, loc, opts, cb)
  opts = opts or {}
  local link_types = opts.link_types or M.DEFAULT_LINK_TYPES
  local progress = opts.on_progress or function() end
  session:get_with_relations(loc.id, function(err, item)
    if err then return cb(err) end
    progress(1, 2, "item")
    local rel = item.relations
    local sections = link_sections(rel.links, link_types)
    local ids, seen = {}, {}
    local function add(id)
      if not seen[id] then
        seen[id] = true
        table.insert(ids, id)
      end
    end
    if rel.parent then add(rel.parent) end
    for _, id in ipairs(rel.children) do add(id) end
    for _, s in ipairs(sections) do
      for _, id in ipairs(s.ids) do add(id) end
    end

    local function build(items, truncated)
      local by_id = {}
      for _, it in ipairs(items) do by_id[it.id] = it end
      local view = {
        location = loc,
        item = item,
        parent = rel.parent and by_id[rel.parent] or nil,
        parent_unreadable = rel.parent ~= nil and by_id[rel.parent] == nil,
        area = item.area,
        children = section_of(rel.children, by_id, workitem.CHILD, "Children"),
        sections = {},
        truncated = truncated,
        catalogs = {},
      }
      for _, s in ipairs(sections) do
        table.insert(view.sections, section_of(s.ids, by_id, s.rel, s.name))
      end
      local all = { item }
      for _, it in ipairs(items) do table.insert(all, it) end
      load_catalogs(session, view.catalogs, all, function(cerr)
        if cerr then return cb(cerr) end
        cb(nil, view)
      end)
    end

    if #ids == 0 then
      progress(2, 2, "links")
      return build({}, false)
    end
    session:query(M.related_spec(ids), function(qerr, items, info)
      if qerr then return cb(qerr) end
      progress(2, 2, "links")
      build(items, info.truncated)
    end)
  end)
end

function M.is_open(view, item)
  local catalog = view.catalogs[item.project]
  return catalog ~= nil and catalog:is_open(item.type, item.state)
end

function M.display(view, loc)
  return { view = view, location = loc or view.location, expanded = {} }
end

local function visible(display, items)
  if display.location.all then return items end
  local out = {}
  for _, it in ipairs(items) do
    if M.is_open(display.view, it) then table.insert(out, it) end
  end
  return out
end

-- "Children: 2 open of 5", "Related: 1", "Children: none".
local function heading(display, section, shown)
  local total = #section.items
  local label = section.name .. ": "
  if total == 0 then
    label = label .. "none"
  elseif #shown == total then
    label = label .. total
  else
    label = label .. string.format("%d open of %d", #shown, total)
  end
  if section.unreadable > 0 then
    label = label .. string.format(", %d not readable", section.unreadable)
  end
  return label
end

local function item_row(item, slot, depth, extra)
  local r = workitem.row(item)
  r.slot, r.depth = slot, depth
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

-- Rows beneath expanded row `id`, at `depth`, and beneath their own
-- expanded rows in turn.
local function block_rows(display, id, depth, out)
  for _, it in ipairs(visible(display, display.expanded[id] or {})) do
    table.insert(out, item_row(it, "child", depth, { block_parent = id }))
    if display.expanded[it.id] then block_rows(display, it.id, depth + 1, out) end
  end
  return out
end

M.SELF_FIELDS = { "type", "state", "assignee", "tags" }

-- Every row of a display, in R3.1 order: the item and its fields, its parent,
-- its area, its children, then each link section.
function M.rows(display)
  local view = display.view
  local self_row = item_row(view.item, "self", 0)
  local out = { self_row }
  for _, f in ipairs(M.SELF_FIELDS) do
    table.insert(out, { kind = "field", slot = "self", id = self_row.id, field = f, value = self_row[f] or "" })
  end
  if view.parent then
    table.insert(out, item_row(view.parent, "parent", 0))
  else
    table.insert(out, { kind = "heading", slot = "parent",
      label = view.parent_unreadable and "Parent: not readable" or "Parent: none" })
  end
  table.insert(out, { kind = "area", slot = "area", path = view.area, name = view.area })
  local children = visible(display, view.children.items)
  table.insert(out, { kind = "heading", slot = "children", label = heading(display, view.children, children) })
  for _, it in ipairs(children) do
    table.insert(out, item_row(it, "child", 0))
    if display.expanded[it.id] then block_rows(display, it.id, 1, out) end
  end
  for _, s in ipairs(view.sections) do
    local shown = visible(display, s.items)
    table.insert(out, { kind = "heading", slot = "link", rel = s.rel, label = heading(display, s, shown) })
    for _, it in ipairs(shown) do table.insert(out, item_row(it, "link", 0, { rel = s.rel })) end
  end
  return out
end

function M.expandable(row)
  return row.kind == "item" and row.slot == "child"
end

-- Expands child row `row` with 1 call, the query for its children, plus a
-- catalog for a project the view has not met. cb(err, rows): the rows to
-- show beneath it, which may be empty when every child is filtered out;
-- info = { total = n } counts its children in every state.
function M.expand(session, display, row, cb)
  if not M.expandable(row) then
    return cb(transport.error("invalid", "only child rows expand"))
  end
  session:query(M.children_spec(row.id), function(err, items)
    if err then return cb(err) end
    load_catalogs(session, display.view.catalogs, items, function(cerr)
      if cerr then return cb(cerr) end
      display.expanded[row.id] = items
      cb(nil, block_rows(display, row.id, row.depth + 1, {}), { total = #items })
    end)
  end)
end

-- Collapses an expanded row and every expansion beneath it; no calls.
function M.collapse(display, id)
  local items = display.expanded[id]
  display.expanded[id] = nil
  for _, it in ipairs(items or {}) do M.collapse(display, it.id) end
end

-- The location selecting a row leads to (R3.2, R3.3): another item's view,
-- carrying the show-all toggle, or the area view with default filters. nil
-- for the item's own row and the headings.
function M.select(display, row, area_filters)
  if row.kind == "area" then return location.area(row.path, area_filters) end
  if row.kind == "item" and row.slot ~= "self" then
    return location.item(row.id, display.location.all)
  end
  return nil
end

return M
