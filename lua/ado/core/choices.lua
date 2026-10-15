-- The values a type or state cell may take (plan 0002 UX3.1 to UX3.3), by
-- the rules the save applies (core/plan.lua, "column edits"), so a menu or
-- picker never offers a value the save would refuse.
--
--   cell   = { column = "type" | "state", type = the type written on the
--              line now, state = the state written on it, snapshot_type = the type it was loaded with (nil
--              for a new line), project, new = true for a line with no
--              loaded row }
--   lookup = { catalog = function(project) -> type catalog or nil,
--              types = function(project) -> the configured types or nil }
--   item   = { word, menu, color = six hex digits or nil }
--   reason = { kind, message, project }, kind one of "not_enum",
--            "no_types", "no_catalog", "unknown_type", "new_state",
--            "none_shared"
local M = {}

M.COLUMNS = { type = true, state = true }

local function lower(s)
  return type(s) == "string" and s:lower() or nil
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find(list, name)
  for _, x in ipairs(list or {}) do
    if lower(x) == lower(name) then return x end
  end
end

-- The save's rejection for a type set in a project without configured
-- types (R8.6), shared so the menu and the save say the same.
function M.no_types(project, catalog)
  local choices = catalog and string.format(", choosing from the types %s has: %s", project,
    table.concat(catalog:names(), ", ")) or ""
  return string.format("project %s has no types configured, so a row cannot be created as or changed to a"
    .. " type in it; add them in setup(), for example projects = { { name = \"%s\", types = { ... } } }%s",
    tostring(project), tostring(project), choices)
end

-- The save's rejection for a new line with a state (R5.18).
M.NEW_STATE = "a new item starts in its type's initial state; leave the state column empty,"
  .. " and change it after saving"

-- The type whose states the save checks a state against: the type written
-- on the line when the save would change the row to it, else the loaded one.
function M.effective_type(cell, lookup)
  local typed = trim(cell.type)
  local allowed = lookup.types(cell.project)
  local catalog = lookup.catalog(cell.project)
  if typed ~= "" and lower(typed) ~= lower(cell.snapshot_type) then
    local canonical = find(allowed, typed)
    if canonical and catalog and catalog:states(canonical) then return canonical end
  end
  return cell.snapshot_type
end

local function type_items(cell, lookup)
  local allowed = lookup.types(cell.project)
  local catalog = lookup.catalog(cell.project)
  if not allowed then
    return nil, { kind = "no_types", project = cell.project, message = M.no_types(cell.project, catalog) }
  end
  if not catalog then return nil, { kind = "no_catalog", project = cell.project } end
  local items = {}
  for _, name in ipairs(allowed) do
    -- A configured type the catalog lacks has no known states, so the save
    -- would refuse it; the session warns about it when the catalog loads.
    local states = catalog:states(name)
    if states then
      -- The save keeps the row's state on a type change, so a type without
      -- that state needs a new state in the same save (R5.22).
      local state = trim(cell.state)
      local hint = not cell.new and state ~= "" and not find(states, state) and "no state " .. state or ""
      table.insert(items, { word = name, menu = hint, color = catalog:type_color(name) })
    end
  end
  return items
end

local function state_items(cell, lookup)
  if cell.new then return nil, { kind = "new_state", project = cell.project, message = M.NEW_STATE } end
  local catalog = lookup.catalog(cell.project)
  if not catalog then return nil, { kind = "no_catalog", project = cell.project } end
  local wtype = M.effective_type(cell, lookup)
  local entries = wtype and catalog:state_entries(wtype)
  if not entries then
    return nil, { kind = "unknown_type", project = cell.project, message = string.format(
      "the states of type %s in project %s are not known", tostring(wtype), tostring(cell.project)) }
  end
  local items = {}
  for _, s in ipairs(entries) do table.insert(items, { word = s.name, menu = s.category or "", color = s.color }) end
  return items, nil, wtype
end

-- Keeps the items of `items` whose word is also in `other`, in their order;
-- a menu text the two disagree on is dropped.
local function intersect(items, other)
  local by = {}
  for _, it in ipairs(other) do by[lower(it.word)] = it end
  local out = {}
  for _, it in ipairs(items) do
    local o = by[lower(it.word)]
    if o then table.insert(out, { word = it.word, menu = o.menu == it.menu and it.menu or "", color = it.color }) end
  end
  return out
end

-- The values every cell of `cells` may take, all of one column: items, or
-- nil and a reason. For several state cells, only the states every cell's
-- type has.
function M.for_cells(cells, lookup)
  local column = cells[1] and cells[1].column
  if not M.COLUMNS[column] then
    return nil, { kind = "not_enum", message = "only a type or state cell has a list of values" }
  end
  local items
  local types_seen, type_order = {}, {}
  for _, cell in ipairs(cells) do
    local these, reason, wtype
    if column == "type" then
      these, reason = type_items(cell, lookup)
    else
      these, reason, wtype = state_items(cell, lookup)
    end
    if not these then return nil, reason end
    if wtype and not types_seen[lower(wtype)] then
      types_seen[lower(wtype)] = true
      table.insert(type_order, wtype)
    end
    items = items and intersect(items, these) or these
  end
  if #items == 0 then
    local message = column == "state"
      and string.format("the selected rows' types (%s) have no state in common", table.concat(type_order, ", "))
      or "the selected rows' projects have no configured type in common"
    return nil, { kind = "none_shared", message = message }
  end
  return items
end

-- One cell, with its project's catalog and configured types given directly.
function M.for_cell(column, row, catalog, project_types)
  local cell = {}
  for k, v in pairs(row) do cell[k] = v end
  cell.column = column
  return M.for_cells({ cell }, {
    catalog = function() return catalog end,
    types = function() return project_types end,
  })
end

-- The items to show for `base`, the cell text before the cursor: those that
-- start with it, ignoring case, unless it is already a whole value or
-- matches none, when every item shows so another can be picked.
function M.filter(items, base)
  base = lower(trim(base))
  if base == "" then return items end
  local out = {}
  for _, it in ipairs(items) do
    if lower(it.word) == base then return items end
    if lower(it.word):sub(1, #base) == base then table.insert(out, it) end
  end
  return #out > 0 and out or items
end

return M
