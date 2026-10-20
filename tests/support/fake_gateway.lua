-- An in-memory fake of ADO that implements the gateway contract in
-- lua/ado/core/gateway.lua. Plain Lua, so it loads inside the sandbox.
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
-- Comments come from seed.items[i].comments = { { id, text, format, author,
-- created, modified, version, deleted }... }. list_comments pages them
-- newest first by created date, as ADO does: the token is the created
-- date of the next page's first comment, and a page holds the comments
-- created at or before it, so two comments with the same date straddling
-- a page end both reappear (RFC 0003 R5). get_work_item reports
-- System.CommentCount. add_comment adds a comment newer than every other.
--
-- patch_work_item and create_work_item apply a JSON Patch whole or not at
-- all, as ADO does: a failed op, a failed "test" on /rev (a "conflict"), or
-- a state the type lacks leaves every item as it was. A relation is removed
-- by its index in the item's relations. Links are stored on both items and,
-- as in ADO (checked 2026-10-12), leave both revs unchanged; a parent link
-- keeps System.Parent in step. Adding a Related link that exists changes
-- nothing. Created items get IDs from 1000 up and their type's first state.
--
-- A seed item's project is s.project, else seed.projects[1]. A project's
-- types are seed.project_types[name], else seed.types.
local gateway = require("ado.core.gateway")
local workitem = require("ado.core.workitem")

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
      comments = {},
    }
    for _, c in ipairs(s.comments or {}) do
      local ident = identities[c.author]
      local who = { displayName = ident and ident.display_name or c.author, uniqueName = c.author }
      table.insert(items[s.id].comments, { id = c.id, workItemId = s.id, version = c.version or 1,
        text = c.text, format = c.format or "html", createdBy = who, createdDate = c.created,
        modifiedBy = who, modifiedDate = c.modified or c.created, isDeleted = c.deleted })
    end
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
    next_id = 1000,
  }, Fake)
  for _, op in ipairs(gateway.OPERATIONS) do
    local handler = Fake["op_" .. op]
    self[op] = function(params, cb) self:dispatch(op, handler, params or {}, cb) end
  end
  return self
end

function Fake:fail_on(op, n, err)
  self.failures[op] = self.failures[op] or {}
  self.failures[op][n] = err or gateway.error("failed", "fake failure on " .. op)
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
  if gateway.WRITES[op] then table.insert(self.writes, record) end

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
  return gateway.error("not_found", "work item " .. tostring(id) .. " does not exist")
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
  error("fake gateway: unsupported query operator " .. tostring(cond.op))
end

-- ── operations ───────────────────────────────────────────────────────────────

function Fake:op_list_projects()
  return nil, copy(self.seed.projects)
end

-- Like az boards query: only the SELECT fields, and no _links or relations.
function Fake:op_query(params)
  local spec = assert(params.spec, "fake gateway: query needs a spec")
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
  raw.comments = nil
  local count = 0
  for _, c in ipairs(it.comments or {}) do if not c.isDeleted then count = count + 1 end end
  raw.fields["System.CommentCount"] = count
  if not params.relations then raw.relations = nil end
  return nil, raw
end

function Fake:op_list_comments(params)
  local it = self.items[params.id]
  if not it then return not_found(params.id) end
  if not params.project then return gateway.error("invalid", "a project is required to list comments") end
  local all = {}
  for _, c in ipairs(it.comments or {}) do if not c.isDeleted then table.insert(all, c) end end
  table.sort(all, function(a, b)
    if a.createdDate ~= b.createdDate then return a.createdDate > b.createdDate end
    return a.id > b.id
  end)
  local start = 1
  if params.token then
    start = #all + 1
    for i, c in ipairs(all) do
      if c.createdDate <= params.token then
        start = i
        break
      end
    end
  end
  local top = params.top or 200
  local page = {}
  for i = start, math.min(#all, start + top - 1) do table.insert(page, copy(all[i])) end
  local after = all[start + top]
  return nil, { comments = page, total = #all, token = after and after.createdDate or nil }
end

-- As in ADO, an assignee is written as a unique name and read back as an
-- identity.
function Fake:identity_value(unique_name)
  for _, x in ipairs(self.seed.identities or {}) do
    if x.unique_name:lower() == tostring(unique_name):lower() then
      return nil, { displayName = x.display_name, uniqueName = x.unique_name }
    end
  end
  return gateway.error("failed", "unknown identity " .. tostring(unique_name))
end

-- ADO's message when a patch's test op fails (checked 2026-10-12).
local TEST_FAILED = "Test Operation for path %s failed, value %s was not equal to test value %s."

function Fake:check_state(fields)
  for _, t in ipairs(self:types_of(fields["System.TeamProject"])) do
    if t.name == fields["System.WorkItemType"] then
      for _, st in ipairs(t.states) do if st.name == fields["System.State"] then return nil end end
      return gateway.error("failed", string.format(
        "The field 'State' contains the value '%s' that is not in the list of supported values",
        tostring(fields["System.State"])))
    end
  end
end

-- Sets one field on fields. As in ADO, an assignee is written as a unique
-- name and read back as an identity, an empty value clears the field, and
-- "add" on System.Tags merges into the tags the item has (checked
-- 2026-10-12).
function Fake:set_field(fields, ref, value, op)
  if ref == "System.AssignedTo" and value ~= "" then
    local err
    err, value = self:identity_value(value)
    if err then return err end
  end
  if ref == "System.Tags" and op == "add" and fields[ref] and value ~= "" then
    value = fields[ref] .. "; " .. value
  end
  if value == "" then value = nil end
  fields[ref] = value
end

function Fake:op_add_comment(params)
  local it = self.items[params.id]
  if not it then return not_found(params.id) end
  self.comments[params.id] = self.comments[params.id] or {}
  table.insert(self.comments[params.id], params.text)
  local last_id = 0
  for _, c in ipairs(it.comments) do last_id = math.max(last_id, c.id) end
  -- Later than any seed date, and later than the comments added before.
  self.added_comments = (self.added_comments or 0) + 1
  local created = string.format("2099-01-01T%02d:%02d:00.0000000Z", math.floor(self.added_comments / 60),
    self.added_comments % 60)
  local who = { displayName = "Me Myself", uniqueName = self.seed.me }
  table.insert(it.comments, { id = last_id + 1, workItemId = it.id, version = 1, text = params.text,
    format = "html", createdBy = who, createdDate = created, modifiedBy = who, modifiedDate = created })
  it.rev = it.rev + 1
  return self:op_get_work_item({ id = params.id })
end

local function find_relation(it, rel, target_url)
  for i, r in ipairs(it.relations) do
    if r.rel == rel and r.url == target_url then return i end
  end
end

-- ADO refuses a second parent.
function Fake:link(it, rel, target)
  local other = self.items[target]
  if not other then return not_found(target) end
  if find_relation(it, rel, other.url) then return nil end
  local child = rel == workitem.PARENT and it or rel == workitem.CHILD and other or nil
  if child and child.fields["System.Parent"] then
    return gateway.error("failed", string.format(
      "TF201036: You cannot add a Parent link between work items %d and %d because a work item can have only one Parent link.",
      child.id, child == it and other.id or it.id))
  end
  table.insert(it.relations, relation(self.seed.org, rel, other.id))
  table.insert(other.relations, relation(self.seed.org, workitem.reverse_rel(rel), it.id))
  if child then child.fields["System.Parent"] = child == it and other.id or it.id end
end

-- Removes relation `index` (from 0) of `it`, and its other end.
function Fake:unlink(it, index)
  local r = it.relations[index + 1]
  if not r then
    return gateway.error("failed", string.format("#%d has no relation at index %d", it.id, index))
  end
  table.remove(it.relations, index + 1)
  local other = self.items[workitem.relation_target(r)]
  if other then
    local j = find_relation(other, workitem.reverse_rel(r.rel), it.url)
    if j then table.remove(other.relations, j) end
  end
  if r.rel == workitem.PARENT then it.fields["System.Parent"] = nil end
  if r.rel == workitem.CHILD and other then other.fields["System.Parent"] = nil end
end

-- Applies patch to item `id`; the caller restores the items on an error.
function Fake:apply_patch(id, patch, creating)
  local it = self.items[id]
  if not it then return not_found(id) end
  local fields_changed = false
  for _, p in ipairs(patch or {}) do
    local ref = type(p.path) == "string" and p.path:match("^/fields/(.+)$")
    local index = type(p.path) == "string" and p.path:match("^/relations/(%d+)$")
    local err
    local tested = type(p.path) == "string" and p.path:match("^/relations/(%d+)/url$")
    if p.op == "test" and p.path == "/rev" and not creating then
      if p.value ~= it.rev then
        return gateway.error("conflict", "VS403351: " .. TEST_FAILED:format(p.path, it.rev, tostring(p.value)))
      end
    elseif p.op == "test" and tested and not creating then
      local r = it.relations[tonumber(tested) + 1]
      if not r or r.url ~= p.value then
        return gateway.error("conflict", TEST_FAILED:format(p.path, r and r.url or "null", tostring(p.value)))
      end
    elseif ref and (p.op == "add" or p.op == "replace") then
      err = self:set_field(it.fields, ref, p.value, p.op)
      fields_changed = true
    elseif p.path == "/relations/-" and p.op == "add" then
      local target = type(p.value) == "table" and workitem.relation_target(p.value)
      if not target then return gateway.error("invalid", "fake gateway: relation needs a work item url") end
      err = self:link(it, p.value.rel, target)
    elseif index and p.op == "remove" and not creating then
      err = self:unlink(it, tonumber(index))
    else
      return gateway.error("invalid", string.format("fake gateway: unsupported patch op %s %s",
        tostring(p.op), tostring(p.path)))
    end
    if err then return err end
  end
  local err = self:check_state(it.fields)
  if err then return err end
  if fields_changed and not creating then it.rev = it.rev + 1 end
end

function Fake:op_patch_work_item(params)
  if not self.items[params.id] then return not_found(params.id) end
  local before = copy(self.items)
  local err = self:apply_patch(params.id, params.patch)
  if err then
    self.items = before
    return err
  end
  return self:op_get_work_item({ id = params.id, relations = true })
end

function Fake:op_create_work_item(params)
  local project = params.project or self.seed.projects[1]
  local initial
  for _, t in ipairs(self:types_of(project)) do
    if t.name == params.type then initial = t.states[1].name end
  end
  if not initial then
    return gateway.error("invalid", "work item type " .. tostring(params.type) .. " does not exist")
  end
  local before = copy(self.items)
  local id = self.next_id
  self.items[id] = {
    id = id,
    rev = 1,
    url = item_api_url(self.seed.org, id),
    fields = {
      ["System.Id"] = id,
      ["System.TeamProject"] = project,
      ["System.WorkItemType"] = params.type,
      ["System.State"] = initial,
      ["System.ChangedDate"] = "2026-10-12T12:00:00Z",
    },
    relations = {},
  }
  local err = self:apply_patch(id, params.patch, true)
  if err then
    self.items = before
    return err
  end
  self.next_id = id + 1
  return self:op_get_work_item({ id = id, relations = true })
end

-- Like ADO's people picker: identities with a word of the display name, or
-- the unique name, starting with the text, without regard to case.
function Fake:op_resolve_identity(params)
  local text = tostring(params.text or ""):lower()
  local out = {}
  for _, ident in ipairs(self.seed.identities or {}) do
    local hit = ident.unique_name:lower():sub(1, #text) == text or ident.display_name:lower():sub(1, #text) == text
    for word in ident.display_name:lower():gmatch("%S+") do
      if word:sub(1, #text) == text then hit = true end
    end
    if hit and text ~= "" then
      table.insert(out, { display_name = ident.display_name, unique_name = ident.unique_name, id = ident.id })
    end
  end
  return nil, out
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
    return gateway.error("failed", "area path " .. tostring(params.path) .. " does not exist")
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
      table.insert(states, { name = st.name, category = (not self.types_omit_categories) and st.category or nil,
        color = st.color })
    end
    table.insert(out, { name = t.name, isDisabled = false, color = t.color, states = states })
  end
  return nil, out
end

function Fake:op_work_item_type_states(params)
  for _, t in ipairs(self:types_of(params.project)) do
    if t.name == params.type then return nil, copy(t.states) end
  end
  return gateway.error("not_found", "work item type " .. tostring(params.type) .. " does not exist")
end

return Fake
