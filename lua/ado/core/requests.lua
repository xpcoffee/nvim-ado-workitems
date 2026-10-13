-- Turns a change plan's ops (core/plan.lua) into one write request per work
-- item: every change to an existing item goes to ADO as one JSON Patch, and
-- each create as one POST with its fields and parent. ADO applies a request
-- whole or not at all, so rules and alerts in ADO never see an item half
-- changed. Policy and order: docs/architecture.md#saving-views.
local transport = require("ado.core.transport")
local urls = require("ado.core.urls")
local workitem = require("ado.core.workitem")

local M = {}

-- request = { id, ops = { op... }, expect_rev } for an existing item, or
-- { create = op, ops = { op } } for a new one.
--
-- Requests on existing items come first, in the order of their first op.
-- Plan ops arrive sorted by plan.ORDER, so an item whose request removes a
-- link runs before one whose request only adds links: a parent freed in
-- this save is free before another item takes it. Creates come last, so
-- each new item's parent has had its own request, and its rev check,
-- before the create links to it.
function M.group(ops)
  local out, by_id, creates = {}, {}, {}
  for _, op in ipairs(ops) do
    if op.kind == "create" then
      table.insert(creates, { create = op, ops = { op } })
    else
      local req = by_id[op.id]
      if not req then
        req = { id = op.id, ops = {} }
        by_id[op.id] = req
        table.insert(out, req)
      end
      table.insert(req.ops, op)
      if req.expect_rev == nil then req.expect_rev = op.expect_rev end
    end
  end
  for _, req in ipairs(creates) do table.insert(out, req) end
  return out
end

-- The other items a request writes a link to: ADO stores a link on both
-- of its items.
function M.targets(req)
  local out, seen = {}, {}
  local function add(id)
    if id and id ~= req.id and not seen[id] then
      seen[id] = true
      table.insert(out, id)
    end
  end
  for _, op in ipairs(req.ops) do
    if op.kind == "set_parent" then
      add(op.from)
      add(op.to)
    elseif op.kind == "add_link" or op.kind == "remove_link" then
      add(op.target)
    elseif op.kind == "create" then
      add(op.parent)
    end
  end
  return out
end

local function relation(org, rel, target)
  return { op = "add", path = "/relations/-", value = { rel = rel, url = urls.work_item_api(org, target) } }
end

local function field(ref, value)
  return { op = "add", path = "/fields/" .. ref, value = value }
end

-- ADO merges an "add" to System.Tags into the tags the item has (checked
-- 2026-10-12), so an existing item's tags are replaced instead.
local function update_field(ref, value)
  return { op = ref == workitem.FIELD_REFS.tags and "replace" or "add", path = "/fields/" .. ref, value = value }
end

-- The JSON Patch for an existing item's request. raw is the item as read
-- just before, with relations: a relation is removed by its index in that
-- read, after a test op that it is still the relation the read found. rev
-- is the rev the plan was made from; the leading test op makes ADO refuse
-- the whole request if the item has changed since.
-- Returns patch, or nil and a "conflict" error when a link to remove is
-- no longer on the item.
function M.patch(req, raw, org, rev)
  local patch = { { op = "test", path = "/rev", value = rev } }
  local removals, additions = {}, {}
  local relations = (raw and type(raw.relations) == "table") and raw.relations or {}

  local function remove(rel, target)
    for i, r in ipairs(relations) do
      if r.rel == rel and workitem.relation_target(r) == target then
        table.insert(removals, { index = i - 1, url = r.url })
        return true
      end
    end
    return false
  end
  local function missing(rel, target)
    local name = rel == workitem.PARENT and "parent" or (rel:match("([^.]+)$") .. " link to")
    return transport.error("conflict", string.format(
      "#%d no longer has %s #%d in ADO; it changed remotely", req.id, name, target))
  end

  for _, op in ipairs(req.ops) do
    if op.kind == "update" or op.kind == "set_area" then
      table.insert(patch, update_field(op.field, op.to))
    elseif op.kind == "set_type" then
      table.insert(patch, update_field(workitem.FIELD_REFS.type, op.to))
      if op.state_to then table.insert(patch, update_field(workitem.FIELD_REFS.state, op.state_to)) end
    elseif op.kind == "remove_link" then
      if not remove(op.rel, op.target) then return nil, missing(op.rel, op.target) end
    elseif op.kind == "set_parent" then
      if not remove(workitem.PARENT, op.from) then return nil, missing(workitem.PARENT, op.from) end
      table.insert(additions, relation(org, workitem.PARENT, op.to))
    elseif op.kind == "add_link" then
      table.insert(additions, relation(org, op.rel, op.target))
    else
      return nil, transport.error("invalid", "no request for op kind " .. tostring(op.kind))
    end
  end
  -- Highest index first, so each removal leaves the indices still to
  -- remove where the read found them. A link change leaves the rev as it
  -- was, so the /rev test cannot tell whether the relations moved since
  -- the read; a test on each relation's url, exactly as read, can.
  table.sort(removals, function(a, b) return a.index > b.index end)
  for _, r in ipairs(removals) do
    table.insert(patch, { op = "test", path = "/relations/" .. r.index .. "/url", value = r.url })
    table.insert(patch, { op = "remove", path = "/relations/" .. r.index })
  end
  for _, a in ipairs(additions) do table.insert(patch, a) end
  return patch
end

-- The JSON Patch for a field edit made outside a save, such as from the
-- detail buffer: fields = { [ref] = value }, after a test that the item is
-- still at rev, so ADO refuses the whole patch if it changed since.
function M.fields_patch(fields, rev)
  local refs = {}
  for ref in pairs(fields) do table.insert(refs, ref) end
  table.sort(refs)
  local patch = { { op = "test", path = "/rev", value = rev } }
  for _, ref in ipairs(refs) do table.insert(patch, update_field(ref, fields[ref])) end
  return patch
end

-- The JSON Patch for a create: c = { title, area, tags, assignee | nil,
-- parent | nil }, as a create op holds them. The type goes in the URL.
function M.create_patch(c, org)
  local patch = {
    field(workitem.FIELD_REFS.title, c.title),
    field(workitem.FIELD_REFS.area, c.area),
  }
  if c.tags and c.tags ~= "" then table.insert(patch, field(workitem.FIELD_REFS.tags, c.tags)) end
  if c.assignee and c.assignee ~= "" then table.insert(patch, field(workitem.FIELD_REFS.assignee, c.assignee)) end
  if c.parent then table.insert(patch, relation(org, workitem.PARENT, c.parent)) end
  return patch
end

return M
