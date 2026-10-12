-- The type catalog: every work item type in the project with its states and
-- their state categories (RFC 0002). It defines "open" for every list in the
-- plugin: a state is open when its category is one of the open categories.
--
-- WIQL has no state-category condition, and one state name can be open for one
-- type and finished for another (a Bug's `Resolved` can be finished while an
-- Epic's is in progress), so the open condition is built per type.
local transport = require("ado.core.transport")

local M = {}

M.DEFAULT_OPEN_CATEGORIES = { "Proposed", "InProgress" }

local function lower(s)
  return type(s) == "string" and s:lower() or nil
end

local Catalog = {}
Catalog.__index = Catalog

-- type_list: { { name, states = { { name, category }... } }... }, as the
-- work_item_types operation returns it, every state with a category.
function M.new(type_list, open_categories)
  local open = {}
  for _, c in ipairs(open_categories or M.DEFAULT_OPEN_CATEGORIES) do open[lower(c)] = true end
  local self = setmetatable({ types = {}, by_name = {} }, Catalog)
  for _, t in ipairs(type_list) do
    local entry = { name = t.name, states = {}, open = {}, open_names = {} }
    for _, s in ipairs(t.states or {}) do
      table.insert(entry.states, { name = s.name, category = s.category })
      if open[lower(s.category)] then
        entry.open[lower(s.name)] = true
        table.insert(entry.open_names, s.name)
      end
    end
    table.insert(self.types, entry)
    self.by_name[lower(t.name)] = entry
  end
  return self
end

function Catalog:names()
  local out = {}
  for _, t in ipairs(self.types) do table.insert(out, t.name) end
  return out
end

-- State names of a type in ADO's order, or nil for a type not in the catalog.
function Catalog:states(wtype)
  local t = self.by_name[lower(wtype)]
  if not t then return nil end
  local out = {}
  for _, s in ipairs(t.states) do table.insert(out, s.name) end
  return out
end

function Catalog:is_open(wtype, state)
  local t = self.by_name[lower(wtype)]
  return t ~= nil and t.open[lower(state)] == true
end

-- The query condition (core/query.lua) matching items in an open state:
-- ([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active')) OR ...
-- Types with the same open states share one clause,
-- ([System.WorkItemType] IN ('Bug', 'Task') AND ...), which keeps the
-- condition short enough for a browser URL (core/urls.lua).
-- type_names limits it to those types; types with no open state are left out.
function Catalog:open_condition(type_names)
  local wanted
  if type_names then
    wanted = {}
    for _, n in ipairs(type_names) do wanted[lower(n)] = true end
  end
  local groups, by_states = {}, {}
  for _, t in ipairs(self.types) do
    if #t.open_names > 0 and (not wanted or wanted[lower(t.name)]) then
      local key = table.concat(t.open_names, "\0")
      local g = by_states[key]
      if not g then
        g = { types = {}, states = t.open_names }
        by_states[key] = g
        table.insert(groups, g)
      end
      table.insert(g.types, t.name)
    end
  end
  local clauses = {}
  for _, g in ipairs(groups) do
    local names = {}
    for _, n in ipairs(g.states) do table.insert(names, n) end
    local type_cond = #g.types == 1
      and { field = "System.WorkItemType", op = "=", value = g.types[1] }
      or { field = "System.WorkItemType", op = "IN", value = g.types }
    table.insert(clauses, { all = { type_cond, { field = "System.State", op = "IN", value = names } } })
  end
  if #clauses == 0 then
    -- No type has an open state, so the condition must match nothing; work
    -- item IDs start at 1.
    return { field = "System.Id", op = "<", value = 0 }
  end
  return { any = clauses }
end

local function missing_categories(t)
  if type(t.states) ~= "table" or #t.states == 0 then return true end
  for _, s in ipairs(t.states) do
    if s.category == nil then return true end
  end
  return false
end

-- Loads the catalog through the transport: one work_item_types call, plus one
-- work_item_type_states call for each type listed without state categories.
-- cb(err, catalog, info), info = { calls = n, fallback = { type name... } }.
function M.load(t, project, open_categories, cb)
  if not project then
    return cb(transport.error("invalid", "a project is required to load work item types"))
  end
  local info = { calls = 1, fallback = {} }
  t.work_item_types({ project = project }, function(err, list)
    if err then return cb(err) end
    list = list or {}
    local pending = {}
    for _, wt in ipairs(list) do
      if missing_categories(wt) then table.insert(pending, wt) end
    end

    local i = 0
    local function next_type()
      i = i + 1
      if i > #pending then return cb(nil, M.new(list, open_categories), info) end
      local wt = pending[i]
      info.calls = info.calls + 1
      table.insert(info.fallback, wt.name)
      t.work_item_type_states({ type = wt.name, project = project }, function(serr, states)
        if serr then return cb(serr) end
        for _, s in ipairs(states or {}) do
          if s.category == nil then
            return cb(transport.error("failed", string.format(
              "state '%s' of type %s has no state category", tostring(s.name), wt.name)))
          end
        end
        wt.states = states or {}
        next_type()
      end)
    end
    next_type()
  end)
end

return M
