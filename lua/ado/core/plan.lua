-- The change plan (RFC 0001 R5): what a save would send to ADO, computed
-- from the rows of every modified view, never from buffer text (R6.2).
-- A row's position stands for a relationship: its area path in an area
-- view, and in an item view a parent, child or other link to the viewed
-- item. Deleting a row removes that relationship, pasting adds one, and
-- deleting and pasting the same item in one save moves it (R5 table).
--
--   view = { key = buffer name, kind = "area" | "item",
--            state_filter = "open" | "all" | { state name... },
--            snapshot = { row... },   rows displayed at the last load
--            current  = { row... } }  rows read from the buffer now
--     area views add rel = area path (field form), filters = the location's
--            filters (core/location.lua), for R5.13
--     item views add rel = item id, item = { id, rev, area, project, parent },
--            link_names = { [rel] = display name },
--            known = { links = { [rel] = { id... } } }, every link loaded,
--            including those the state filter hides
--   snapshot row = a core view row (area_view.lua, item_view.lua) plus
--            row_id and line
--   current row  = { row_id | nil, line, kind, title, state, type, assignee,
--            tags (items), name (areas), label (headings), field, value
--            (fields), origin = { key, row } | nil }; origin is set for a
--            row ID this view did not load (a row pasted from another
--            view), from the row ID registry; a row whose snapshot or origin
--            row has slot "self" holds only its title
--
--   plan = { ops = { op... }, notes = { note... }, rejections = { rejection... } }
--   op   = { kind, id, expect_rev, views = { key... }, ... } where kind is
--            "update"     field, name, from, to; an assignee update adds
--                         to_label, a tags update added and removed
--            "set_type"   field, name = "type", from, to, and state_from,
--                         state_to when the same call sets the state (R5.22)
--            "set_area"   field, name = "area", from, to, title
--            "remove_link", "add_link"  rel, target, name (az link name),
--                         title, target_title
--            "set_parent" from, to (parent ids), title
--            "create"     type, title, area, project, tags, parent | nil,
--                         assignee | nil, assignee_label, copy_of | nil, line
--   note = { kind = "warning" | "no_change", id, views, rule, message }
--   rejection = { id | nil, line | nil, views, rule, message }
local area_path = require("ado.core.area_path")
local item_view = require("ado.core.item_view")
local workitem = require("ado.core.workitem")

local M = {}

-- The columns a row edit can change, in the order their ops run on one item.
M.EDITABLE = { "title", "type", "state", "assignee", "tags" }

-- Default types for new lines (R5.18; plan 0001 section 8).
M.DEFAULT_TYPES = { area = "Task", children = "Task" }

-- Ops run in this order: link removals first, so a move frees an item's
-- parent before another paste could give it one, and creates last.
M.ORDER = { "remove_link", "set_parent", "add_link", "set_area", "set_type", "update", "create" }

local LAST_SELF_FIELD = item_view.SELF_FIELDS[#item_view.SELF_FIELDS]

-- Deep enough for any real hierarchy; stops a corrupt cycle in ADO data
-- from looping.
local MAX_ANCESTORS = 100

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(s)
  return type(s) == "string" and s:lower() or s
end

local function find(list, value)
  for _, x in ipairs(list or {}) do
    if lower(x) == lower(value) then return x end
  end
end

local function add_unique(list, v)
  for _, x in ipairs(list) do if x == v then return end end
  table.insert(list, v)
end

local function sorted_keys(...)
  local seen, out = {}, {}
  for _, t in ipairs({ ... }) do
    for k in pairs(t) do
      if not seen[k] then
        seen[k] = true
        table.insert(out, k)
      end
    end
  end
  table.sort(out)
  return out
end

local function contains(list, v)
  for _, x in ipairs(list or {}) do if x == v then return true end end
  return false
end

local function same_area(a, b)
  return lower(area_path.normalise(a)) == lower(area_path.normalise(b))
end

local function same_text(a, b)
  return lower(trim(a)) == lower(trim(b))
end

-- "b; A; a" -> "A; b": ADO keeps tags as a set, compared without regard
-- to case, so order and repeats carry no meaning.
local function norm_tags(s)
  local out, seen = {}, {}
  for tag in (s or ""):gmatch("[^;]+") do
    local t = trim(tag)
    if t ~= "" and not seen[t:lower()] then
      seen[t:lower()] = true
      table.insert(out, t)
    end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

local function tags_text(s)
  return table.concat(norm_tags(s), "; ")
end

-- The tags in `b` and not in `a`, without regard to case.
local function tags_missing(a, b)
  local have, out = {}, {}
  for _, t in ipairs(norm_tags(a)) do have[t:lower()] = true end
  for _, t in ipairs(norm_tags(b)) do
    if not have[t:lower()] then table.insert(out, t) end
  end
  return out
end

local function identity_label(x)
  if x.unique_name and x.unique_name ~= "" then return x.display_name .. " <" .. x.unique_name .. ">" end
  return x.display_name
end

-- The one identity an assignee text names (R5.19), or nil and why not.
-- found: what resolve_identity returned for text. A text equal to one
-- identity's name or email picks it even when it starts other names too.
function M.choose_identity(found, text)
  local exact = {}
  for _, x in ipairs(found) do
    if same_text(x.display_name, text) or same_text(x.unique_name, text) or (x.mail and same_text(x.mail, text)) then
      table.insert(exact, x)
    end
  end
  if #exact == 1 then return exact[1] end
  if #found == 1 then return found[1] end
  if #found == 0 then
    return nil, string.format("no ADO identity matches '%s'; type a name or email that matches one person", text)
  end
  local names = {}
  for i, x in ipairs(found) do
    if i <= 5 then table.insert(names, identity_label(x)) end
  end
  return nil, string.format("'%s' matches %d identities (%s%s); type more of the name, or the email", text,
    #found, table.concat(names, ", "), #found > 5 and ", ..." or "")
end

local function where(view, line, id)
  local at = line and ("line " .. line) or "a line"
  if id then at = "#" .. id .. " (" .. at .. ")" end
  return at .. " in " .. view.key
end

local function view_project(view)
  if view.kind == "area" then return area_path.project(view.rel) end
  return view.item and view.item.project
end

-- ── where each row stands ────────────────────────────────────────────────────
--
-- Regions of an item view, in R3.1 order: "self" (the item's own lines),
-- "parent", "arearow" (the area row, read-only), "children", and
-- "link:<rel>" per link section. An area view is one region, "area". The
-- fixed rows (the item's own lines, the area row, headings, sub-area rows)
-- mark where each region starts, so a row belongs to the region of the
-- fixed row above it.

local function is_fixed(view, s)
  if view.kind == "area" then return s.kind == "area" end
  return s.kind ~= "item" or s.slot == "self"
end

local function region_after(s)
  if s.kind == "item" then return "self" end
  if s.kind == "field" then return s.field == LAST_SELF_FIELD and "parent" or "self" end
  if s.kind == "area" then return "arearow" end
  if s.slot == "parent" then return "parent" end
  if s.slot == "children" then return "children" end
  return "link:" .. s.rel
end

local function snapshot_region(view, s)
  if view.kind == "area" then return "area" end
  if s.slot == "parent" then return "parent" end
  if s.slot == "child" then return "children" end
  return "link:" .. tostring(s.rel)
end

local function blank(c)
  for _, f in ipairs({ "title", "type", "state", "assignee", "tags" }) do
    if trim(c[f]) ~= "" then return false end
  end
  return true
end

-- Sorts one view's current rows by where they stand:
--   fixed     = { { c, s }... }  the fixed rows, as loaded
--   rows      = { r... }, r = { c, s (snapshot or origin row), own, region,
--               in_place, origin_key }; in_place when the row stands where
--               it was loaded
--   new_lines = { { c, region }... }
--   removed   = { s... }        snapshot item rows no longer in place
-- reject(view, line, id, rule, message) is told about rows that cannot be
-- matched, and fixed rows that were deleted or moved.
local function classify(view, reject)
  local snap, fixed_order = {}, {}
  for _, s in ipairs(view.snapshot) do
    snap[s.row_id] = s
    if is_fixed(view, s) then table.insert(fixed_order, s.row_id) end
  end
  local out = { fixed = {}, rows = {}, new_lines = {}, removed = {} }
  local region = view.kind == "area" and "area" or "self"
  local seen_fixed, fixed_seq, in_place = {}, {}, {}

  for _, c in ipairs(view.current) do
    local s = c.row_id and snap[c.row_id]
    if not c.row_id then
      if not blank(c) then table.insert(out.new_lines, { c = c, region = region }) end
    elseif s and is_fixed(view, s) and not seen_fixed[c.row_id] then
      seen_fixed[c.row_id] = true
      table.insert(fixed_seq, c.row_id)
      table.insert(out.fixed, { c = c, s = s })
      if view.kind == "item" then region = region_after(s) end
    else
      local origin = s or (c.origin and c.origin.row)
      if not origin then
        reject(view, c.line, nil, "R5.1", "this row's ID is not known, so it cannot be matched to a work item;"
          .. " it may come from a view that reloaded since it was copied. Delete the line, or reload")
      elseif origin.kind ~= "item" then
        reject(view, c.line, nil, "R5", "only work item rows can be pasted; sub-area rows, headings, the area row"
          .. " and the item's field lines cannot. Delete the line, or reload")
      else
        local r = { c = c, s = origin, own = s ~= nil, region = region,
          origin_key = s and view.key or c.origin.key }
        if s and not is_fixed(view, s) and not in_place[c.row_id] and snapshot_region(view, s) == region then
          in_place[c.row_id] = true
          r.in_place = true
        end
        table.insert(out.rows, r)
      end
    end
  end

  local fixed_message = view.kind == "area"
    and "sub-area rows are read-only; undo, or reload"
    or "the item's own lines, the area row and the headings mark where each relationship's rows go,"
      .. " so they cannot be deleted or moved; undo, or reload"
  for _, rid in ipairs(fixed_order) do
    if not seen_fixed[rid] then
      reject(view, snap[rid].line, nil, view.kind == "area" and "R5.16" or "R5",
        "this line was deleted: " .. fixed_message)
    end
  end
  if view.kind == "item" then
    local expected = {}
    for _, rid in ipairs(fixed_order) do
      if seen_fixed[rid] then table.insert(expected, rid) end
    end
    for i, rid in ipairs(fixed_seq) do
      if expected[i] ~= rid then
        reject(view, out.fixed[i].c.line, nil, "R5", "this line was moved: " .. fixed_message)
        break
      end
    end
  end

  for _, s in ipairs(view.snapshot) do
    if s.kind == "item" and not is_fixed(view, s) and not in_place[s.row_id] then
      table.insert(out.removed, s)
    end
  end
  return out
end

-- The items that would become a new parent: the viewed item of an item
-- view with rows pasted into its children, and every item pasted into a
-- parent row.
local function new_parents(views)
  local out, seen = {}, {}
  local function add(id)
    if not seen[id] then
      seen[id] = true
      table.insert(out, id)
    end
  end
  for _, view in ipairs(views) do
    if view.kind == "item" then
      for _, r in ipairs(classify(view, function() end).rows) do
        if not r.in_place then
          if r.region == "children" then add(view.rel) end
          if r.region == "parent" then add(r.s.id) end
        end
      end
    end
  end
  return out
end

-- The parent of every item row the views hold, as loaded: id -> parent
-- id, or false for none. Rows come from queries that select System.Parent,
-- and an item view's own item from its relations, so a row without a
-- parent has none.
local function known_parents(views)
  local parents = {}
  local function note(row)
    if row and row.kind == "item" and row.id then
      if row.parent then
        parents[row.id] = row.parent
      elseif parents[row.id] == nil then
        parents[row.id] = false
      end
    end
  end
  for _, view in ipairs(views) do
    if view.item then note({ kind = "item", id = view.item.id, parent = view.item.parent }) end
    for _, s in ipairs(view.snapshot) do note(s) end
    for _, c in ipairs(view.current) do note(c.origin and c.origin.row) end
  end
  return parents
end

-- Every assignee text the views hold that differs from the row it edits,
-- or that a new line holds, once each without regard to case.
local function assignee_texts(views)
  local out, seen = {}, {}
  local function add(text)
    text = trim(text)
    if text ~= "" and not seen[text:lower()] then
      seen[text:lower()] = true
      table.insert(out, text)
    end
  end
  for _, view in ipairs(views) do
    local snap = {}
    for _, s in ipairs(view.snapshot) do snap[s.row_id] = s end
    for _, c in ipairs(view.current) do
      local s = c.row_id and (snap[c.row_id] or (c.origin and c.origin.row))
      if c.kind == "item" and c.assignee ~= nil then
        if not s or trim(c.assignee) ~= trim(s.assignee) then add(c.assignee) end
      elseif c.kind == "field" and c.field == "assignee" and s and s.kind == "field" then
        if trim(c.value) ~= trim(s.value) then add(c.value) end
      end
    end
  end
  return out
end

-- Loads what compute() needs, so compute() makes no transport call:
--   catalogs = { [project] = catalog }   state checks (R5.7), and the types
--              a rejection lists when a project has no configured types
--   types    = { [project] = { name... } } the configured types (R5.21)
--   default_types = { area, children }   (R5.18)
--   parents  = { [id] = parent id | false } the ancestors of every new
--              parent, for the cycle check (R5.12): one get_work_item per
--              level the loaded rows do not already show
--   identities = { [lower text] = { identity... } } the identities each
--              edited assignee text matches (R5.19): one resolve_identity
--              per distinct text
-- Catalogs are cached by the session, so without assignee edits this is
-- usually 0 calls.
-- cb(err, prepared).
function M.prepare(views, session, cb)
  local projects, seen = {}, {}
  local function add_project(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      table.insert(projects, p)
    end
  end
  for _, v in ipairs(views) do
    add_project(view_project(v))
    for _, r in ipairs(v.snapshot) do
      if r.kind == "item" then add_project(r.project) end
    end
    for _, c in ipairs(v.current) do
      if c.origin and c.origin.row.kind == "item" then add_project(c.origin.row.project) end
    end
  end
  local prepared = { catalogs = {}, types = {}, parents = known_parents(views), identities = {},
    default_types = session.default_types or M.DEFAULT_TYPES }
  for _, p in ipairs(session:project_list()) do
    if p.types then prepared.types[p.name] = p.types end
  end

  local pending = new_parents(views)
  local function ancestors(i, id, depth)
    if i > #pending then return cb(nil, prepared) end
    if not id or depth > MAX_ANCESTORS then return ancestors(i + 1, pending[i + 1], 0) end
    local known = prepared.parents[id]
    if known ~= nil then return ancestors(i, known or nil, depth + 1) end
    session:get_with_relations(id, function(err, item)
      if err then return cb(err) end
      prepared.parents[id] = item.relations.parent or false
      ancestors(i, item.relations.parent, depth + 1)
    end)
  end

  local texts = assignee_texts(views)
  local function identities(i)
    if i > #texts then return ancestors(1, pending[1], 0) end
    session:resolve_identity(texts[i], function(err, found)
      if err then return cb(err) end
      prepared.identities[texts[i]:lower()] = found
      identities(i + 1)
    end)
  end

  local function next_project(i)
    if i > #projects then return identities(1) end
    session:catalog(projects[i], function(err, catalog)
      if err then return cb(err) end
      prepared.catalogs[projects[i]] = catalog
      next_project(i + 1)
    end)
  end
  next_project(1)
end

-- Why `view` would not show an item with values `v` at `slot` once it
-- reloads (R5.13), or nil when it would. v = { type, state, assignee,
-- assignee_unique, tags, assignee_changed }. me = the display names of rows
-- an @Me view shows, which are the user's own.
local function hidden_by(view, slot, v, catalog, me)
  if view.kind == "item" and slot ~= "child" and slot ~= "link" then return nil end
  local f = view.state_filter
  if f == "open" and catalog and not catalog:is_open(v.type, v.state) then
    return "the view's state filter hides " .. v.state
  end
  if type(f) == "table" then
    local shown = false
    for _, st in ipairs(f) do if same_text(st, v.state) then shown = true end end
    if not shown then return "the view's state filter hides " .. v.state end
  end
  local filters = view.kind == "area" and view.filters or {}
  if filters.types then
    local shown = false
    for _, t in ipairs(filters.types) do if same_text(t, v.type) then shown = true end end
    if not shown then return "the view's type filter hides " .. v.type end
  end
  local who = filters.assignee
  if who then
    if trim(v.assignee) == "" then return "the view's assignee filter hides unassigned items" end
    if lower(who) == "@me" then
      if not me[lower(v.assignee)] and (v.assignee_changed or next(me) ~= nil) then
        return "the view's assignee filter (@Me) hides items assigned to " .. v.assignee
      end
    elseif not (same_text(who, v.assignee) or same_text(who, v.assignee_unique)) then
      return string.format("the view's assignee filter (%s) hides items assigned to %s", who, v.assignee)
    end
  end
  if filters.tag then
    local has = false
    for _, t in ipairs(norm_tags(v.tags)) do if same_text(t, filters.tag) then has = true end end
    if not has then return string.format("the view's tag filter hides items without the tag '%s'", filters.tag) end
  end
  return nil
end

-- A link seen from either end, as one key: a -Reverse link is keyed by its
-- -Forward end, and a link without ends by the lower ID first.
local function link_key(a, rel, b)
  if rel:sub(-8) == "-Reverse" then a, rel, b = b, workitem.reverse_rel(rel), a end
  if rel:sub(-8) ~= "-Forward" and a > b then a, b = b, a end
  return a .. " " .. rel .. " " .. b
end

-- prepared: from M.prepare. Makes no transport calls, so a rejected plan
-- has made no writes.
function M.compute(views, prepared)
  prepared = prepared or {}
  local catalogs = prepared.catalogs or {}
  local configured_types = prepared.types or {}
  local default_types = prepared.default_types or M.DEFAULT_TYPES
  local plan = { ops = {}, notes = {}, rejections = {} }
  local buckets = {}
  for _, kind in ipairs(M.ORDER) do buckets[kind] = {} end

  local function reject(view, line, id, rule, message)
    table.insert(plan.rejections, { id = id, line = line, views = { view.key }, rule = rule,
      message = where(view, line, id) .. ": " .. message })
  end
  local function reject_item(id, keys, rule, message)
    table.insert(plan.rejections, { id = id, views = keys, rule = rule, message = message })
  end
  local function note(kind, id, keys, rule, message)
    table.insert(plan.notes, { kind = kind, id = id, views = keys, rule = rule, message = message })
  end

  -- Why a row cannot set a type in a project with no configured types
  -- (R8.6): the plan cannot tell a typo from a type the user wants.
  local function no_types(project)
    local catalog = catalogs[project]
    local choices = catalog and string.format(", choosing from the types %s has: %s", project,
      table.concat(catalog:names(), ", ")) or ""
    return string.format("project %s has no types configured, so a row cannot be created as or changed to a"
      .. " type in it; add them in setup(), for example projects = { { name = \"%s\", types = { ... } } }%s",
      tostring(project), tostring(project), choices)
  end

  local function identity_for(text)
    local found = (prepared.identities or {})[lower(text)]
    if not found then return nil, string.format("'%s' was not looked up; save again", text) end
    return M.choose_identity(found, text)
  end

  -- Items this save puts in a view they were not shown in, for R5.13:
  -- moves and new links { id, view, slot }, and copies and creates
  -- { op, view, slot, values }.
  local arrivals = {}

  -- id -> { row = first row seen, revs = { [rev] = { key... } },
  --         shown = { { view, row }... } (snapshot rows of the saved views) }
  local items = {}
  local function know(view_key, row, shown_in)
    local it = items[row.id] or { row = row, revs = {}, shown = {} }
    items[row.id] = it
    if row.rev then
      it.revs[row.rev] = it.revs[row.rev] or {}
      add_unique(it.revs[row.rev], view_key)
    end
    if shown_in then table.insert(it.shown, { view = shown_in, row = row }) end
  end
  local function title_of(id)
    return items[id] and items[id].row.title
  end

  -- id -> field -> { values = { [value] = { keys, lines } }, order = { value... } }
  local edits = {}
  local function edit(view, line, id, field, value)
    edits[id] = edits[id] or {}
    local e = edits[id][field] or { values = {}, order = {} }
    edits[id][field] = e
    if not e.values[value] then
      e.values[value] = { keys = {}, lines = {} }
      table.insert(e.order, value)
    end
    add_unique(e.values[value].keys, view.key)
    table.insert(e.values[value].lines, { key = view.key, line = line })
  end

  -- An edited column's value as the plan compares it: tags as a sorted set.
  local function column_value(field, text)
    if field == "tags" then return tags_text(text) end
    return trim(text)
  end
  -- Tags compare without regard to case, as ADO matches them.
  local function edited(field, text, loaded)
    local a, b = column_value(field, text), column_value(field, loaded)
    if field == "tags" then return lower(a) ~= lower(b) end
    return a ~= b
  end

  -- The column edits on one item row, against the row it shows.
  local function column_diffs(view, c, s)
    local diffs = {}
    if s.slot == "self" then
      if c.type ~= nil then
        reject(view, c.line, s.id, "R5", "this row was copied from an item's own title line, which holds only"
          .. " the title; put it back as it was copied, or reload")
      elseif trim(c.title) ~= trim(s.title) then
        diffs.title = trim(c.title)
      end
      return diffs
    end
    if c.type == nil then
      reject(view, c.line, s.id, "R5",
        "the row needs its four │ separators (type │ state │ title │ assignee │ tags); restore them, or reload")
      return diffs
    end
    for _, f in ipairs(M.EDITABLE) do
      if edited(f, c[f], s[f]) then diffs[f] = column_value(f, c[f]) end
    end
    return diffs
  end

  local sorted = {}
  for vi, view in ipairs(views) do
    for _, s in ipairs(view.snapshot) do
      if s.kind == "item" then know(view.key, s, view) end
    end
    local out = classify(view, reject)
    sorted[vi] = out

    for _, f in ipairs(out.fixed) do
      local c, s = f.c, f.s
      if s.kind == "item" then
        if c.kind ~= "item" then
          reject(view, c.line, s.id, "R5", "this line no longer reads as the item's title; undo the change, or reload")
        elseif trim(c.title) ~= trim(s.title) then
          edit(view, c.line, s.id, "title", trim(c.title))
        end
      elseif c.kind ~= s.kind then
        reject(view, c.line, s.id, "R5",
          "this line no longer reads as a " .. s.kind .. " row; undo the change, or reload")
      elseif s.kind == "area" then
        if trim(c.name) ~= trim(s.name) then
          reject(view, c.line, nil, "R5.16", "area rows are read-only")
        end
      elseif s.kind == "heading" then
        if trim(c.label) ~= trim(s.label) then
          reject(view, c.line, nil, "R5", "headings are read-only")
        end
      elseif c.field ~= s.field then
        reject(view, c.line, s.id, "R5", "field names are read-only")
      elseif edited(s.field, c.value, s.value) then
        edit(view, c.line, s.id, s.field, column_value(s.field, c.value))
      end
    end

    for _, r in ipairs(out.rows) do
      if not r.own then know(r.origin_key, r.s) end
      if r.c.kind ~= "item" then
        reject(view, r.c.line, r.s.id, "R5",
          "this line no longer reads as a work item row; undo the change, or reload")
        r.diffs = {}
      else
        r.diffs = column_diffs(view, r.c, r.s)
      end
      if r.in_place then
        for _, f in ipairs(M.EDITABLE) do
          if r.diffs[f] then edit(view, r.c.line, r.s.id, f, r.diffs[f]) end
        end
      end
    end
  end

  -- A pasted row that stays the same item (a move, or a new link) carries
  -- its title and state edits to that item.
  local function settle(view, r)
    for _, f in ipairs(M.EDITABLE) do
      if r.diffs[f] then edit(view, r.c.line, r.s.id, f, r.diffs[f]) end
    end
  end

  -- Descendant rows pasted with the expanded row above them (R5.8), keyed
  -- by view key and the ID of that row: { { view, r }..., copied = bool }.
  local carried = {}

  local function copy(view, r, area, parent)
    local s = r.s
    if r.diffs.state then
      reject(view, r.c.line, s.id, "R5.6",
        "a copy starts in its type's initial state; put the state back, and change it after saving")
    end
    for _, f in ipairs({ "type", "assignee", "tags" }) do
      if r.diffs[f] then
        reject(view, r.c.line, s.id, "R5.6", string.format("a copy takes the original's type and tags and no"
          .. " assignee; put the %s back, and change it after saving", f))
      end
    end
    local title = r.diffs.title or s.title
    if title == "" then reject(view, r.c.line, s.id, "R5.17", "a title cannot be empty") end
    local project = area_path.project(area)
    local allowed = configured_types[project]
    if not allowed then
      reject(view, r.c.line, s.id, "R8.6", no_types(project))
    elseif not find(allowed, s.type) then
      reject(view, r.c.line, s.id, "R5.6", string.format("a copy keeps the original's type, and %s is not one"
        .. " of the types of project %s: %s", tostring(s.type), project, table.concat(allowed, ", ")))
    end
    local op = { kind = "create", copy_of = s.id, type = s.type, title = title,
      tags = s.tags or "", area = area, parent = parent, project = project,
      views = { view.key }, line = r.c.line }
    table.insert(buckets.create, op)
    table.insert(arrivals, { op = op, view = view, slot = view.kind == "area" and "area" or "child",
      values = { type = s.type, tags = s.tags or "", assignee = "" } })
    local block = carried[view.key .. "#" .. s.id]
    if block then
      block.copied = true
      for _, d in ipairs(block) do
        note("warning", d.r.s.id, { view.key }, "R5.8", string.format(
          "#%d is shown under #%d but is not copied with it: a copy has no children, so the row goes on reload",
          d.r.s.id, s.id))
      end
    end
  end

  -- ── collect the relationship changes ──────────────────────────────────────
  local area_rem, area_add = {}, {}
  -- hier_rem[child][parent] = { key... }; hier_add[child] = { { parent,
  -- view, r, source = "children" | "parent" }... }
  local hier_rem, hier_add, current_parent = {}, {}, {}
  local link_changes, link_order = {}, {}

  local function link_change(kind, view, a, rel, b, row)
    local key = link_key(a, rel, b)
    if not link_changes[key] then
      link_changes[key] = { rem = {}, add = {} }
      table.insert(link_order, key)
    end
    table.insert(link_changes[key][kind], { view = view, id = a, rel = rel, target = b, row = row })
  end

  local function hier_removal(child, parent, view)
    current_parent[child] = parent
    hier_rem[child] = hier_rem[child] or {}
    hier_rem[child][parent] = hier_rem[child][parent] or {}
    add_unique(hier_rem[child][parent], view.key)
  end

  local function hier_addition(child, parent, view, r, source, loaded_parent)
    if current_parent[child] == nil then current_parent[child] = loaded_parent or false end
    hier_add[child] = hier_add[child] or {}
    table.insert(hier_add[child], { parent = parent, view = view, r = r, source = source })
  end

  for vi, view in ipairs(views) do
    local out = sorted[vi]
    local removed_rows = {}
    for _, s in ipairs(out.removed) do removed_rows[s.row_id] = true end

    -- The snapshot row of the expanded row that descendant row s sits under.
    local function block_row(s)
      for i = s.line - 1, 1, -1 do
        local above = view.snapshot[i]
        if above and above.kind == "item" and above.slot == "child" and above.id == s.block_parent then
          return above
        end
      end
    end

    for _, s in ipairs(out.removed) do
      local region = snapshot_region(view, s)
      if region == "area" then
        area_rem[s.id] = area_rem[s.id] or {}
        table.insert(area_rem[s.id], view)
      elseif region == "parent" then
        hier_removal(view.rel, s.id, view)
      elseif region == "children" then
        local top = s.block_parent and block_row(s)
        if top and removed_rows[top.row_id] then
          note("no_change", s.id, { view.key }, "R5.8", string.format(
            "#%d stays a child of #%d: it went with #%d as one block", s.id, s.block_parent, s.block_parent))
        else
          hier_removal(s.id, s.block_parent or view.rel, view)
        end
      else
        link_change("rem", view, view.rel, s.rel, s.id, s)
      end
    end

    local pasted_children = {}
    for _, r in ipairs(out.rows) do
      if not r.in_place and r.region == "children" then
        pasted_children[r.origin_key .. "#" .. r.s.id] = true
      end
    end

    for _, r in ipairs(out.rows) do
      if not r.in_place then
        local s = r.s
        if r.region == "area" then
          area_add[s.id] = area_add[s.id] or {}
          table.insert(area_add[s.id], { view = view, r = r })
        elseif r.region == "self" then
          reject(view, r.c.line, s.id, "R5", "rows cannot be pasted among the item's own lines;"
            .. " move the line under the parent row, the Children heading or a link heading")
        elseif r.region == "arearow" then
          reject(view, r.c.line, s.id, "R5.11", "rows cannot be pasted on the area row: only area views change"
            .. " an item's area; paste it into an area view, or under a heading")
        elseif r.region == "parent" then
          hier_addition(view.rel, s.id, view, r, "parent", view.item.parent)
        elseif r.region == "children" then
          if s.block_parent and pasted_children[r.origin_key .. "#" .. s.block_parent] then
            local k = view.key .. "#" .. s.block_parent
            carried[k] = carried[k] or {}
            table.insert(carried[k], { view = view, r = r })
          else
            hier_addition(s.id, view.rel, view, r, "children", s.parent)
          end
        elseif s.id == view.rel then
          reject(view, r.c.line, s.id, "R5", "an item cannot be linked to itself; delete the line")
        else
          link_change("add", view, view.rel, r.region:sub(#"link:" + 1), s.id, r)
        end
      end
    end
  end

  -- ── area paths (R5 table, area view column; R5.4, R5.6, R5.10) ─────────────
  local function cut_twice(id, adds)
    local keys = {}
    for _, a in ipairs(adds) do add_unique(keys, a.view.key) end
    reject_item(id, keys, "R5.10", string.format(
      "#%d was cut once and pasted into %d places (%s); which paste is the move would be arbitrary."
      .. " Keep one paste, or undo the cut", id, #adds, table.concat(keys, ", ")))
  end

  for _, id in ipairs(sorted_keys(area_rem, area_add)) do
    local rem, add = area_rem[id] or {}, area_add[id] or {}
    if #add == 0 then
      for _, v in ipairs(rem) do
        note("no_change", id, { v.key }, "R5.4", string.format(
          "#%d deleted from %s only: no change, because every work item needs an area path;"
          .. " paste it into another area view to move it", id, v.key))
      end
    elseif #rem > 0 and #add > 1 then
      cut_twice(id, add)
    elseif #rem > 0 then
      local a = add[1]
      settle(a.view, a.r)
      table.insert(arrivals, { id = id, view = a.view, slot = "area" })
      if not same_area(a.r.s.area, a.view.rel) then
        local keys = {}
        for _, v in ipairs(rem) do add_unique(keys, v.key) end
        add_unique(keys, a.view.key)
        table.insert(buckets.set_area, { kind = "set_area", id = id, field = workitem.FIELD_REFS.area,
          name = "area", from = a.r.s.area, to = area_path.normalise(a.view.rel), title = a.r.s.title,
          views = keys })
      end
    else
      for _, a in ipairs(add) do copy(a.view, a.r, area_path.normalise(a.view.rel), a.r.s.parent) end
    end
  end

  -- ── parents (R5 table, child list and parent row columns; R5.9, R5.10) ─────
  local new_parent = {}
  for _, child in ipairs(sorted_keys(hier_rem, hier_add)) do
    local removed = sorted_keys(hier_rem[child] or {})
    local adds = hier_add[child] or {}
    local keys = {}
    for _, p in ipairs(removed) do
      for _, k in ipairs(hier_rem[child][p]) do add_unique(keys, k) end
    end
    for _, a in ipairs(adds) do add_unique(keys, a.view.key) end
    if #removed > 1 then
      reject_item(child, keys, "R5.10", string.format(
        "the views disagree on the parent of #%d (#%s); reload them before saving", child,
        table.concat(removed, ", #")))
    elseif #adds == 0 then
      table.insert(buckets.remove_link, { kind = "remove_link", id = child, rel = workitem.PARENT,
        target = removed[1], title = title_of(child), target_title = title_of(removed[1]), views = keys })
      new_parent[child] = false
    elseif #removed == 1 then
      if #adds > 1 then
        cut_twice(child, adds)
      else
        settle(adds[1].view, adds[1].r)
        if adds[1].source == "children" then
          table.insert(arrivals, { id = child, view = adds[1].view, slot = "child" })
        end
        if adds[1].parent ~= removed[1] then
          table.insert(buckets.set_parent, { kind = "set_parent", id = child, from = removed[1],
            to = adds[1].parent, title = title_of(child), views = keys })
          new_parent[child] = adds[1].parent
        end
      end
    elseif current_parent[child] then
      for _, a in ipairs(adds) do
        if a.source == "children" then
          copy(a.view, a.r, a.r.s.area, a.parent)
        else
          reject(a.view, a.r.c.line, child, "R5.9", string.format(
            "#%d already has parent #%d, and ADO allows one parent per item; delete the parent row too to"
            .. " change it", child, current_parent[child]))
        end
      end
    elseif #adds > 1 then
      local parents = {}
      for _, a in ipairs(adds) do table.insert(parents, "#" .. a.parent) end
      reject_item(child, keys, "R5.9", string.format(
        "#%d would get %d parents (%s), and ADO allows one parent per item", child, #adds,
        table.concat(parents, ", ")))
    else
      local a = adds[1]
      settle(a.view, a.r)
      if a.source == "children" then table.insert(arrivals, { id = child, view = a.view, slot = "child" }) end
      table.insert(buckets.add_link, { kind = "add_link", id = child, rel = workitem.PARENT, target = a.parent,
        title = title_of(child), target_title = title_of(a.parent), views = keys })
      new_parent[child] = a.parent
    end
  end

  -- Rows that moved with their block keep their edits, as the block does.
  for _, block in pairs(carried) do
    if not block.copied then
      for _, d in ipairs(block) do settle(d.view, d.r) end
    end
  end

  -- ── other links (R5 table, other links column) ──────────────────────────────
  for _, key in ipairs(link_order) do
    local ch = link_changes[key]
    for _, a in ipairs(ch.add) do settle(a.view, a.row) end
    if #ch.rem > 0 and #ch.add == 0 then
      local x = ch.rem[1]
      local keys = {}
      for _, e in ipairs(ch.rem) do add_unique(keys, e.view.key) end
      table.insert(buckets.remove_link, { kind = "remove_link", id = x.id, rel = x.rel, target = x.target,
        name = x.view.link_names and x.view.link_names[x.rel], title = title_of(x.id),
        target_title = x.row.title, views = keys })
    elseif #ch.add > 0 and #ch.rem == 0 then
      local x = ch.add[1]
      local known = x.view.known and x.view.known.links and x.view.known.links[x.rel]
      if contains(known, x.target) then
        note("no_change", x.target, { x.view.key }, "R5", string.format(
          "#%d is already linked to #%d; the state filter may hide its row", x.target, x.id))
      else
        local keys = {}
        for _, e in ipairs(ch.add) do
          add_unique(keys, e.view.key)
          table.insert(arrivals, { id = x.target, view = e.view, slot = "link" })
        end
        table.insert(buckets.add_link, { kind = "add_link", id = x.id, rel = x.rel, target = x.target,
          name = x.view.link_names and x.view.link_names[x.rel], title = title_of(x.id),
          target_title = x.row.s.title, views = keys })
      end
    end
  end

  -- ── new lines (R5 table, last row; R5.18) ───────────────────────────────────
  for vi, view in ipairs(views) do
    for _, n in ipairs(sorted[vi].new_lines) do
      local c = n.c
      local function bad(rule, message) reject(view, c.line, nil, rule, message) end
      local area, parent, default
      if n.region == "area" then
        area, default = area_path.normalise(view.rel), default_types.area
      elseif n.region == "children" then
        area, parent, default = view.item.area, view.rel, default_types.children
      end
      if not area then
        if n.region == "parent" then
          bad("R5", "a new line cannot be a parent; paste an existing item's row here instead")
        elseif n.region:sub(1, 5) == "link:" then
          bad("R5", "a new line cannot be linked; create it under Children or in an area view, then paste"
            .. " its row here")
        else
          bad("R5", "new lines go under the Children heading, or in an area view")
        end
      else
        local valid = true
        local function invalid(rule, message)
          bad(rule, message)
          valid = false
        end
        if trim(c.title) == "" then invalid("R5.17", "a new line needs a title") end
        if trim(c.state) ~= "" then
          invalid("R5.18", "a new item starts in its type's initial state; leave the state column empty,"
            .. " and change it after saving")
        end
        local who
        if trim(c.assignee) ~= "" then
          local problem
          who, problem = identity_for(trim(c.assignee))
          if not who then invalid("R5.19", problem) end
        end
        local project = area_path.project(area)
        local wanted = trim(c.type) ~= "" and trim(c.type) or default
        local allowed = configured_types[project]
        local canonical = find(allowed, wanted)
        if not allowed then
          invalid("R8.6", no_types(project))
        elseif not canonical then
          invalid("R5.18", string.format("'%s' is not one of the types of project %s: %s", wanted, project,
            table.concat(allowed, ", ")))
        end
        if valid then
          local op = { kind = "create", type = canonical, title = trim(c.title), tags = tags_text(c.tags),
            area = area, parent = parent, project = project, views = { view.key }, line = c.line,
            assignee = who and who.unique_name, assignee_label = who and identity_label(who) }
          table.insert(buckets.create, op)
          table.insert(arrivals, { op = op, view = view, slot = n.region == "area" and "area" or "child",
            values = { type = canonical, tags = op.tags, assignee = who and who.display_name or "",
              assignee_unique = who and who.unique_name } })
        end
      end
    end
  end

  -- ── cycles (R5.12) ──────────────────────────────────────────────────────────
  local parents = {}
  for id, p in pairs(prepared.parents or known_parents(views)) do parents[id] = p end
  for child, p in pairs(new_parent) do parents[child] = p end
  for _, child in ipairs(sorted_keys(new_parent)) do
    local q = new_parent[child]
    local x, depth, problem = q, 0, nil
    while x and depth <= MAX_ANCESTORS do
      if x == child then
        problem = string.format("putting #%d under #%d would make #%d its own ancestor", child, q, child)
        break
      end
      if parents[x] == nil then
        problem = string.format("the ancestors of #%d could not be read, so a cycle cannot be ruled out;"
          .. " reload and save again", x)
        break
      end
      x, depth = parents[x], depth + 1
    end
    if problem then
      local keys = {}
      for _, a in ipairs(hier_add[child] or {}) do add_unique(keys, a.view.key) end
      reject_item(child, keys, "R5.12", problem)
      for _, kind in ipairs({ "set_parent", "add_link" }) do
        local kept = {}
        for _, op in ipairs(buckets[kind]) do
          local moves_child = op.id == child and (op.kind == "set_parent" or op.rel == workitem.PARENT)
          if not moves_child then table.insert(kept, op) end
        end
        buckets[kind] = kept
      end
    end
  end

  -- ── column edits (R5.7, R5.10, R5.17, R5.19 to R5.22) ───────────────────────
  -- final[id]: the item's type, state, assignee and tags once the plan has
  -- run, for items with a field op; R5.13 reads it below.
  local final = {}
  local function states_of(row, wtype)
    local catalog = catalogs[row.project]
    return catalog and catalog:states(wtype)
  end
  for _, id in ipairs(sorted_keys(edits)) do
    local row = items[id].row
    -- field -> { value, keys, reject(rule, message) } for each field edited
    -- to one value; conflicting values reject (R5.10).
    local wanted = {}
    for _, field in ipairs(M.EDITABLE) do
      local e = edits[id][field]
      if e and #e.order > 1 then
        local parts, keys = {}, {}
        for _, value in ipairs(e.order) do
          table.insert(parts, string.format("'%s' in %s", value, table.concat(e.values[value].keys, ", ")))
          for _, k in ipairs(e.values[value].keys) do add_unique(keys, k) end
        end
        reject_item(id, keys, "R5.10", string.format("#%d has conflicting %s edits: %s", id, field,
          table.concat(parts, " and ")))
      elseif e then
        local value = e.order[1]
        local keys = e.values[value].keys
        local first = e.values[value].lines[1]
        wanted[field] = { value = value, keys = keys, reject = function(rule, message)
          table.insert(plan.rejections, { id = id, line = first.line, views = keys, rule = rule,
            message = "#" .. id .. " (line " .. first.line .. ") in " .. first.key .. ": " .. message })
        end }
      end
    end
    local v = { type = row.type, state = row.state, assignee = row.assignee or "",
      assignee_unique = row.assignee_unique, tags = row.tags or "" }
    local changed = false
    local function update(field, to, extra)
      local op = { kind = "update", id = id, field = workitem.FIELD_REFS[field], name = field, from = row[field],
        to = to, views = wanted[field].keys }
      for k, x in pairs(extra or {}) do op[k] = x end
      table.insert(buckets.update, op)
      changed = true
    end

    local w = wanted.title
    if w then
      if w.value == "" then w.reject("R5.17", "a title cannot be empty") else update("title", w.value) end
    end

    -- The type (R5.21): only a configured type of the item's project, so a
    -- typo cannot change it.
    local new_type
    w = wanted.type
    if w then
      local allowed = configured_types[row.project]
      local canonical = find(allowed, w.value)
      if not allowed then
        w.reject("R8.6", no_types(row.project))
      elseif not canonical then
        note("no_change", id, w.keys, "R5.21", string.format(
          "#%d type '%s' is not one of the types of project %s (%s), so the type stays %s", id, w.value,
          tostring(row.project), table.concat(allowed, ", "), tostring(row.type)))
      elseif lower(canonical) == lower(row.type) then
        note("no_change", id, w.keys, "R5.21", string.format("#%d type '%s' is its current type, %s", id,
          w.value, row.type))
      else
        new_type = canonical
      end
    end

    -- The state (R5.7), checked against the new type when the type changes.
    local new_state
    local state_ok = true
    w = wanted.state
    if w then
      local wtype = new_type or row.type
      local states = states_of(row, wtype)
      local canonical = find(states, w.value)
      if not states then
        w.reject("R5.7", string.format("the states of type %s in project %s are not known", tostring(wtype),
          tostring(row.project)))
        state_ok = false
      elseif not canonical then
        w.reject(new_type and "R5.22" or "R5.7", string.format("'%s' is not a state of %s; its states are %s",
          w.value, wtype, table.concat(states, ", ")))
        state_ok = false
      elseif canonical == row.state then
        if not new_type then
          note("no_change", id, w.keys, "R5.7",
            string.format("#%d state '%s' is its current state, %s", id, w.value, canonical))
        end
      else
        new_state = canonical
      end
    end

    -- A type change keeps the state, so that state must be valid for the
    -- new type, unless the row sets one that is (R5.22). Type and state go
    -- in one call: neither order of two calls works when each value is
    -- valid only with the other.
    if new_type and state_ok then
      local states = states_of(row, new_type)
      local wt = wanted.type
      if not states then
        wt.reject("R5.22", string.format("the states of type %s in project %s are not known", new_type,
          tostring(row.project)))
      elseif not new_state and not find(states, row.state) then
        wt.reject("R5.22", string.format("%s has no state '%s', the state #%d is in; set the state column to"
          .. " one of %s in the same save", new_type, tostring(row.state), id, table.concat(states, ", ")))
      else
        local keys = {}
        for _, k in ipairs(wt.keys) do add_unique(keys, k) end
        for _, k in ipairs(wanted.state and wanted.state.keys or {}) do add_unique(keys, k) end
        table.insert(buckets.set_type, { kind = "set_type", id = id, field = workitem.FIELD_REFS.type,
          name = "type", from = row.type, to = new_type, state_from = new_state and row.state,
          state_to = new_state, views = keys })
        changed = true
        v.type, v.state = new_type, new_state or row.state
      end
    elseif new_state then
      update("state", new_state)
      v.state = new_state
    end

    w = wanted.assignee
    if w then
      if w.value == "" then
        update("assignee", "", { to_label = "none" })
        v.assignee, v.assignee_unique, v.assignee_changed = "", nil, true
      else
        local who, problem = identity_for(w.value)
        if not who then
          w.reject("R5.19", problem)
        elseif same_text(who.display_name, row.assignee)
            and (row.assignee_unique == nil or same_text(who.unique_name, row.assignee_unique)) then
          note("no_change", id, w.keys, "R5.19", string.format("#%d is already assigned to %s", id,
            identity_label(who)))
        else
          update("assignee", who.unique_name, { to_label = identity_label(who) })
          v.assignee, v.assignee_unique, v.assignee_changed = who.display_name, who.unique_name, true
        end
      end
    end

    w = wanted.tags
    if w then
      update("tags", w.value, { added = tags_missing(row.tags, w.value), removed = tags_missing(w.value, row.tags) })
      v.tags = w.value
    end

    if changed then final[id] = v end
  end

  -- ── items the destination view will hide (R5.13) ────────────────────────────
  -- Each view in the save that will show an item the plan changes, or that
  -- an item arrives in, is checked against its filters with the item's
  -- values after the save.
  local me = {}
  for _, view in ipairs(views) do
    if view.kind == "area" and view.filters and lower(view.filters.assignee) == "@me" then
      for _, sr in ipairs(view.snapshot) do
        if sr.kind == "item" and trim(sr.assignee) ~= "" then me[lower(sr.assignee)] = true end
      end
    end
  end
  local warned = {}
  -- subject names the item in the message: "#12", or a copy or create.
  local function warn(id, view, subject, reason)
    local key = subject .. " " .. view.key
    if warned[key] then return end
    warned[key] = true
    note("warning", id, { view.key }, "R5.13", string.format("%s will not appear in %s after reload: %s",
      subject, view.key, reason))
  end
  local function check(id, view, slot)
    local it = items[id]
    if not it then return end
    local v = final[id] or { type = it.row.type, state = it.row.state, assignee = it.row.assignee or "",
      assignee_unique = it.row.assignee_unique, tags = it.row.tags or "" }
    local reason = hidden_by(view, slot, v, catalogs[it.row.project], me)
    if reason then warn(id, view, "#" .. id, reason) end
  end
  for vi, view in ipairs(views) do
    for _, r in ipairs(sorted[vi].rows) do
      if r.in_place and final[r.s.id] then check(r.s.id, view, r.s.slot or "area") end
    end
  end
  for _, a in ipairs(arrivals) do
    if a.op then
      local states = states_of({ project = a.op.project }, a.values.type)
      local v = { type = a.values.type, state = states and states[1] or "", tags = a.values.tags,
        assignee = a.values.assignee, assignee_unique = a.values.assignee_unique }
      local subject = a.op.copy_of and ("the copy of #" .. a.op.copy_of)
        or string.format("new %s '%s'", a.op.type, a.op.title)
      local reason = states and hidden_by(a.view, a.slot, v, catalogs[a.op.project], me)
      if reason then warn(a.op.copy_of, a.view, subject, reason) end
    else
      check(a.id, a.view, a.slot)
    end
  end

  -- ── the revision guard's expected revs (R5.14) ──────────────────────────────
  local inconsistent = {}
  for _, kind in ipairs(M.ORDER) do
    for _, op in ipairs(buckets[kind]) do
      local it = op.kind ~= "create" and items[op.id]
      local revs = it and sorted_keys(it.revs) or {}
      if #revs > 1 then
        if not inconsistent[op.id] then
          inconsistent[op.id] = true
          local keys = {}
          for _, rev in ipairs(revs) do
            for _, k in ipairs(it.revs[rev]) do add_unique(keys, k) end
          end
          reject_item(op.id, keys, "R5.14", string.format(
            "#%d was loaded at different revisions in %s; reload those views before saving",
            op.id, table.concat(keys, ", ")))
        end
      else
        op.expect_rev = revs[1]
        table.insert(plan.ops, op)
      end
    end
  end
  return plan
end

function M.applicable(plan)
  return #plan.rejections == 0 and #plan.ops > 0
end

return M
