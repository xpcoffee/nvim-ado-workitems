-- In-memory stand-in for ADO that implements the transport contract in
-- lua/ado/core/transport.lua. Plain Lua, so it loads inside the sandbox.
--
--   local fake = Fake.new(require("tests.fixtures.seed"))
--   fake.calls            every call, in order: { op, params }
--   fake.writes           write calls only, with failed = true if they failed
--   fake:fail_on(op, n, err)       the n-th call of op (counting from 1) fails
--   fake:edit_remotely(id, fields) another user's change: fields, rev + 1
--   fake.mode = "deferred"         callbacks wait for fake:flush()
--   fake.types_omit_categories     work_item_types lists states without
--                                  categories, as the per-type fallback expects
--
-- A seed item's project is s.project, else seed.projects[1]. A project's
-- types are seed.project_types[name], else seed.types.
local transport = require("ado.core.transport")

local Fake = {}
Fake.__index = Fake

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local function item_api_url(org, id)
  return string.format("https://dev.azure.com/%s/_apis/wit/workItems/%d", org, id)
end

-- Display names as az boards work-item show reports them.
local LINK_NAMES = {
  ["System.LinkTypes.Hierarchy-Reverse"] = "Parent",
  ["System.LinkTypes.Hierarchy-Forward"] = "Child",
  ["System.LinkTypes.Related"] = "Related",
}

local function relation(org, rel, target)
  return { rel = rel, url = item_api_url(org, target), attributes = { isLocked = false, name = LINK_NAMES[rel] } }
end

-- Seed rows become raw ADO items, so tests exercise normalisation too.
local function build_items(seed)
  local identities = {}
  for _, ident in ipairs(seed.identities or {}) do
    identities[ident.unique_name] = ident
  end
  local items = {}
  for _, s in ipairs(seed.items) do
    local ident = s.assignee and identities[s.assignee]
    items[s.id] = {
      id = s.id,
      rev = 1,
      url = item_api_url(seed.org, s.id),
      fields = {
        ["System.Id"] = s.id,
        ["System.TeamProject"] = s.project or seed.projects[1],
        ["System.WorkItemType"] = s.type,
        ["System.Title"] = s.title,
        ["System.State"] = s.state,
        ["System.AreaPath"] = s.area,
        ["System.IterationPath"] = s.iteration or seed.projects[1],
        ["System.AssignedTo"] = ident and { displayName = ident.display_name, uniqueName = ident.unique_name } or nil,
        ["System.Tags"] = s.tags,
        ["System.ChangedDate"] = s.changed,
        ["System.Description"] = s.description,
        ["System.Parent"] = s.parent,
      },
      relations = {},
      _links = { html = { href = string.format("https://dev.azure.com/%s/%s/_workitems/edit/%d",
        seed.org, seed.projects[1], s.id) } },
    }
  end
  for _, s in ipairs(seed.items) do
    if s.parent then
      table.insert(items[s.id].relations, relation(seed.org, "System.LinkTypes.Hierarchy-Reverse", s.parent))
      table.insert(items[s.parent].relations, relation(seed.org, "System.LinkTypes.Hierarchy-Forward", s.id))
    end
    for _, target in ipairs(s.related or {}) do
      table.insert(items[s.id].relations, relation(seed.org, "System.LinkTypes.Related", target))
    end
  end
  return items
end

function Fake.new(seed)
  local self = setmetatable({
    seed = copy(seed),
    items = build_items(seed),
    calls = {},
    writes = {},
    mode = "sync",
    queue = {},
    failures = {},
    counts = {},
    comments = {},
    types_omit_categories = false,
  }, Fake)
  for _, op in ipairs(transport.OPERATIONS) do
    local handler = Fake["op_" .. op]
    self[op] = function(params, cb) self:dispatch(op, handler, params or {}, cb) end
  end
  return self
end

function Fake:fail_on(op, n, err)
  self.failures[op] = self.failures[op] or {}
  self.failures[op][n] = err or transport.error("failed", "fake failure on " .. op)
end

function Fake:edit_remotely(id, fields)
  local it = assert(self.items[id], "no such item " .. tostring(id))
  for ref, value in pairs(fields) do it.fields[ref] = value end
  it.rev = it.rev + 1
end

function Fake:flush()
  while #self.queue > 0 do
    table.remove(self.queue, 1)()
  end
end

function Fake:dispatch(op, handler, params, cb)
  self.counts[op] = (self.counts[op] or 0) + 1
  local record = { op = op, params = copy(params) }
  table.insert(self.calls, record)
  if transport.WRITES[op] then table.insert(self.writes, record) end

  local err, result
  local planned = self.failures[op] and self.failures[op][self.counts[op]]
  if planned then
    err = planned
  else
    err, result = handler(self, params)
  end
  if err then record.failed = true end
  if self.mode == "deferred" then
    table.insert(self.queue, function() cb(err, result) end)
  else
    cb(err, result)
  end
end

local function not_found(id)
  return transport.error("not_found", "work item " .. tostring(id) .. " does not exist")
end

-- ── query evaluation ─────────────────────────────────────────────────────────

local function text_of(value)
  if type(value) == "table" then
    return (value.uniqueName or "") .. " " .. (value.displayName or "")
  end
  return value == nil and "" or tostring(value)
end

-- WIQL CONTAINS WORDS: every word of the search is a prefix of a word in the
-- field. HTML tags are dropped first, as ADO's index does.
local function contains_words(field_value, search)
  local haystack = {}
  for w in text_of(field_value):gsub("<[^>]*>", " "):lower():gmatch("[%w_]+") do
    table.insert(haystack, w)
  end
  for needle in tostring(search):lower():gmatch("[%w_]+") do
    local found = false
    for _, w in ipairs(haystack) do
      if w:sub(1, #needle) == needle then found = true break end
    end
    if not found then return false end
  end
  return true
end

function Fake:equals(field_value, value)
  if type(value) == "table" and value.macro == "Me" then
    return type(field_value) == "table" and field_value.uniqueName == self.seed.me
  end
  if type(field_value) == "table" then
    local v = tostring(value):lower()
    return (field_value.uniqueName or ""):lower() == v or (field_value.displayName or ""):lower() == v
  end
  if type(value) == "number" then return field_value == value end
  return text_of(field_value):lower() == tostring(value):lower()
end

function Fake:matches(it, cond)
  if cond == nil then return true end
  if cond.all then
    for _, c in ipairs(cond.all) do
      if not self:matches(it, c) then return false end
    end
    return true
  end
  if cond.any then
    for _, c in ipairs(cond.any) do
      if self:matches(it, c) then return true end
    end
    return false
  end
  local field_value = it.fields[cond.field]
  if cond.op == "=" then return self:equals(field_value, cond.value) end
  if cond.op == "<>" then return not self:equals(field_value, cond.value) end
  if cond.op == "<" then return field_value < cond.value end
  if cond.op == "IN" then
    for _, v in ipairs(cond.value) do
      if self:equals(field_value, v) then return true end
    end
    return false
  end
  if cond.op == "CONTAINS WORDS" then return contains_words(field_value, cond.value) end
  if cond.op == "UNDER" then
    local p, v = text_of(field_value):lower(), tostring(cond.value):lower()
    return p == v or p:sub(1, #v + 1) == v .. "\\"
  end
  -- On System.Tags, ADO matches CONTAINS against whole tags, not substrings
  -- (checked 2026-10-12); it is the only CONTAINS field the plugin queries.
  if cond.op == "CONTAINS" and cond.field == "System.Tags" then
    local wanted = tostring(cond.value):lower()
    for tag in text_of(field_value):gmatch("[^;]+") do
      if tag:match("^%s*(.-)%s*$"):lower() == wanted then return true end
    end
    return false
  end
  error("fake transport: unsupported query operator " .. tostring(cond.op))
end

-- ── operations ───────────────────────────────────────────────────────────────

function Fake:op_list_projects()
  return nil, copy(self.seed.projects)
end

-- Like az boards query: only the SELECT fields, and no _links or relations.
function Fake:op_query(params)
  local spec = assert(params.spec, "fake transport: query needs a spec")
  local hits = {}
  for _, it in pairs(self.items) do
    if self:matches(it, spec.where) then table.insert(hits, it) end
  end
  local order = spec.order_by or {}
  table.sort(hits, function(a, b)
    for _, o in ipairs(order) do
      local x, y = a.fields[o.field], b.fields[o.field]
      if type(x) ~= "number" or type(y) ~= "number" then x, y = text_of(x), text_of(y) end
      if x ~= y then
        if o.desc then return x > y end
        return x < y
      end
    end
    return a.id < b.id
  end)
  local out = {}
  for _, it in ipairs(hits) do
    local fields = {}
    for _, ref in ipairs(spec.select or {}) do fields[ref] = copy(it.fields[ref]) end
    table.insert(out, { id = it.id, rev = it.rev, url = it.url, fields = fields })
  end
  return nil, out
end

function Fake:op_get_work_item(params)
  local it = self.items[params.id]
  if not it then return not_found(params.id) end
  local raw = copy(it)
  if not params.relations then raw.relations = nil end
  return nil, raw
end

function Fake:op_update_fields(params)
  local it = self.items[params.id]
  if not it then return not_found(params.id) end
  for ref, value in pairs(params.fields or {}) do it.fields[ref] = value end
  it.rev = it.rev + 1
  return self:op_get_work_item({ id = params.id })
end

function Fake:op_add_comment(params)
  local it = self.items[params.id]
  if not it then return not_found(params.id) end
  self.comments[params.id] = self.comments[params.id] or {}
  table.insert(self.comments[params.id], params.text)
  it.rev = it.rev + 1
  return self:op_get_work_item({ id = params.id })
end

-- Seed areas are in the work item field form, P\Team\A; ADO's
-- classification nodes put an "Area" segment after the project.
local function node_path(field_path)
  local project, rest = field_path:match("^([^\\]+)(.*)$")
  return "\\" .. project .. "\\Area" .. rest
end

function Fake:op_area_children(params)
  local path = tostring(params.path or ""):lower()
  local found = path == ("\\" .. tostring(params.project) .. "\\area"):lower()
  local nodes = {}
  for _, a in ipairs(self.seed.areas or {}) do
    local node = node_path(a)
    if node:lower() == path then found = true end
    local parent, name = node:match("^(.*)\\([^\\]+)$")
    if parent:lower() == path then
      table.insert(nodes, { name = name, path = node, structureType = "area" })
    end
  end
  if not found then
    return transport.error("failed", "area path " .. tostring(params.path) .. " does not exist")
  end
  for _, n in ipairs(nodes) do
    n.hasChildren = false
    for _, a in ipairs(self.seed.areas) do
      if node_path(a):lower():sub(1, #n.path + 1) == n.path:lower() .. "\\" then n.hasChildren = true end
    end
  end
  return nil, nodes
end

function Fake:types_of(project)
  return (self.seed.project_types or {})[project] or self.seed.types
end

function Fake:op_work_item_types(params)
  local out = {}
  for _, t in ipairs(self:types_of(params.project)) do
    local states = {}
    for _, st in ipairs(t.states) do
      table.insert(states, { name = st.name, category = (not self.types_omit_categories) and st.category or nil })
    end
    table.insert(out, { name = t.name, isDisabled = false, states = states })
  end
  return nil, out
end

function Fake:op_work_item_type_states(params)
  for _, t in ipairs(self:types_of(params.project)) do
    if t.name == params.type then return nil, copy(t.states) end
  end
  return transport.error("not_found", "work item type " .. tostring(params.type) .. " does not exist")
end

return Fake
