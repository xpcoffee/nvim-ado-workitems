-- Plain-text summaries of a change plan before it is applied (RFC 0001
-- R5.3, R7.2) and of the result after (R5.15), so any presentation layer
-- can show them. Each line is { text, kind }, kind one of "title",
-- "heading", "change", "removal", "copy", "type", "warning", "note",
-- "rejection".
local plan_mod = require("ado.core.plan")
local workitem = require("ado.core.workitem")

local M = {}

local function quote(v)
  return "'" .. tostring(v) .. "'"
end

local function item(id, title)
  if title == nil then return "#" .. id end
  return "#" .. id .. " " .. quote(title)
end

local function plural(n, one, many)
  return string.format("%d %s", n, n == 1 and one or (many or one .. "s"))
end

local function link_label(op)
  return op.name or op.rel:match("([^.]+)$")
end

-- created: the new item's ID, once apply has made it.
function M.op_text(op, created)
  if op.kind == "set_area" then
    return string.format("%s area: %s -> %s", item(op.id, op.title), op.from, op.to)
  elseif op.kind == "set_parent" then
    return string.format("%s parent: #%d -> #%d", item(op.id, op.title), op.from, op.to)
  elseif op.kind == "remove_link" or op.kind == "add_link" then
    local verb = op.kind == "remove_link" and "remove" or "add"
    if op.rel == workitem.PARENT then
      return string.format("%s: %s parent %s", item(op.id, op.title), verb, item(op.target, op.target_title))
    end
    return string.format("#%d: %s %s link to %s", op.id, verb, link_label(op), item(op.target, op.target_title))
  elseif op.kind == "create" then
    local what = op.copy_of and string.format("copy of #%d %s (%s)", op.copy_of, quote(op.title), op.type)
      or string.format("new %s %s", op.type, quote(op.title))
    local text = string.format("%s in %s, %s", what, op.area, op.parent and ("parent #" .. op.parent) or "no parent")
    if op.assignee_label then text = text .. ", assigned to " .. op.assignee_label end
    if op.tags and op.tags ~= "" and not op.copy_of then text = text .. ", tags " .. quote(op.tags) end
    if created then text = text .. " -> #" .. created end
    return text
  elseif op.kind == "set_type" then
    local text = string.format("#%d type: %s -> %s", op.id, op.from, op.to)
    if op.state_to then text = text .. string.format(", state: %s -> %s", op.state_from, op.state_to) end
    return text
  elseif op.name == "title" then
    return string.format("#%d title: %s -> %s", op.id, quote(op.from), quote(op.to))
  elseif op.name == "assignee" then
    local from = (op.from == nil or op.from == "") and "none" or quote(op.from)
    return string.format("#%d assignee: %s -> %s", op.id, from, op.to_label == "none" and "none" or quote(op.to_label))
  elseif op.name == "description" then
    return string.format("#%d description changed: %s added, %s removed", op.id,
      plural(op.added or 0, "line"), plural(op.removed or 0, "line"))
  elseif op.name == "tags" and op.added then
    local parts = {}
    for _, change in ipairs({ { "added", op.added }, { "removed", op.removed } }) do
      local tags = {}
      for _, t in ipairs(change[2]) do table.insert(tags, quote(t)) end
      if #tags > 0 then table.insert(parts, change[1] .. " " .. table.concat(tags, ", ")) end
    end
    if #parts == 0 then table.insert(parts, "same tags") end
    return string.format("#%d tags: %s", op.id, table.concat(parts, "; "))
  end
  return string.format("#%d %s: %s -> %s", op.id, op.name, tostring(op.from), tostring(op.to))
end

local function append_all(list, more)
  for _, x in ipairs(more) do table.insert(list, x) end
end

local function section(out, heading, kind, entries)
  if #entries == 0 then return end
  table.insert(out, { text = heading, kind = "heading" })
  for _, text in ipairs(entries) do table.insert(out, { text = "  " .. text, kind = kind }) end
end

-- The R7.2 groups, in the order the summary lists them. Link removals,
-- copies and type changes get their own line kinds so the summary can make
-- them stand out: they are the changes most likely to be accidental or, for
-- a type change, to lose the values of fields the new type does not have.
local GROUPS = {
  { heading = "Link removals: check these", kind = "removal", match = { remove_link = true } },
  { heading = "Link additions", kind = "change", match = { add_link = true } },
  { heading = "Parent and area changes", kind = "change", match = { set_parent = true, set_area = true } },
  { heading = "Type changes: check these, ADO drops fields the new type does not have", kind = "type",
    match = { set_type = true } },
  { heading = "Field changes", kind = "change", match = { update = true } },
  { heading = "Copies: check these", kind = "copy", match = { create = "copy" } },
  { heading = "New items", kind = "change", match = { create = "new" } },
}

local function in_group(group, op)
  local m = group.match[op.kind]
  if m == true then return true end
  if m == "copy" then return op.copy_of ~= nil end
  if m == "new" then return op.copy_of == nil end
  return false
end

-- The summary of a plan: rejections, then the R7.2 groups, warnings, and
-- rows with no change and why.
function M.lines(plan)
  local out = {}
  local warnings, no_change, rejected = {}, {}, {}
  for _, n in ipairs(plan.notes) do
    table.insert(n.kind == "warning" and warnings or no_change, n.message)
  end
  for _, r in ipairs(plan.rejections) do table.insert(rejected, r.message) end

  local count = #plan.ops
  if #rejected > 0 then
    table.insert(out, { text = string.format("Save rejected: %d %s, nothing will be sent", #rejected,
      #rejected == 1 and "problem" or "problems"), kind = "title" })
  elseif count > 0 then
    table.insert(out, { text = string.format("Save %d %s to Azure DevOps?", count,
      count == 1 and "change" or "changes"), kind = "title" })
  else
    table.insert(out, { text = "Nothing to save", kind = "title" })
  end
  section(out, "Rejected", "rejection", rejected)
  for _, g in ipairs(GROUPS) do
    local entries = {}
    for _, op in ipairs(plan.ops) do
      if in_group(g, op) then table.insert(entries, M.op_text(op)) end
    end
    section(out, g.heading, g.kind, entries)
  end
  section(out, "Warnings", "warning", warnings)
  section(out, "No change", "note", no_change)
  return out, plan_mod.applicable(plan)
end

-- What one request writes, for progress and the report: "#101" or
-- "new Task 'Title'".
function M.request_label(req)
  local c = req.create
  if not c then return "#" .. req.id end
  if c.copy_of then return string.format("copy of #%d", c.copy_of) end
  return string.format("new %s %s", c.type, quote(c.title))
end

-- The kinds the one-line result counts, in its order.
local COUNTS = {
  { "field update" }, { "type change" }, { "area change" }, { "parent change" }, { "link change" },
  { "created", "created" }, { "copied", "copied" },
}

local function count_kind(op)
  if op.kind == "update" then return "field update" end
  if op.kind == "set_type" then return "type change" end
  if op.kind == "set_area" then return "area change" end
  if op.kind == "set_parent" or op.rel == workitem.PARENT then return "parent change" end
  if op.kind == "create" then return op.copy_of and "copied" or "created" end
  return "link change"
end

-- At most this many new IDs are listed in the one-line result.
local MAX_IDS = 3

-- The save's result as one line, for a notification:
-- "saved 6 changes to 3 work items: 3 field updates, 1 parent change, 2 created (#1000, #1001)"
-- or "save stopped at #102: 1 of 3 work items saved, 1 not attempted".
function M.result_line(result)
  local created = result.created or {}
  if result.failed then
    return string.format("save stopped at %s: %d of %s saved, %d not attempted", M.request_label(result.failed.request),
      #result.completed, plural(#result.requests, "work item"), #result.not_attempted)
  end
  local n, counts, ids = 0, {}, {}
  for _, req in ipairs(result.completed) do
    for _, op in ipairs(req.ops) do
      n = n + 1
      local k = count_kind(op)
      counts[k] = (counts[k] or 0) + 1
      if created[op] then
        ids[k] = ids[k] or {}
        table.insert(ids[k], "#" .. created[op])
      end
    end
  end
  local parts = {}
  for _, c in ipairs(COUNTS) do
    local k = c[1]
    if counts[k] then
      local part = plural(counts[k], k, c[2])
      if ids[k] and #ids[k] <= MAX_IDS then part = part .. " (" .. table.concat(ids[k], ", ") .. ")" end
      table.insert(parts, part)
    end
  end
  return string.format("saved %s to %s: %s", plural(n, "change"), plural(#result.completed, "work item"),
    table.concat(parts, ", "))
end

local function request_lines(req, created)
  local out = {}
  for _, op in ipairs(req.ops) do table.insert(out, M.op_text(op, created[op])) end
  return out
end

-- The report after apply, one entry per work item request: result from
-- core/apply.lua.
function M.report(result)
  local out = {}
  local created = result.created or {}
  if not result.failed then
    local n = 0
    for _, req in ipairs(result.completed) do n = n + #req.ops end
    table.insert(out, { text = string.format("Saved %s to %s", plural(n, "change"),
      plural(#result.completed, "work item")), kind = "title" })
  else
    table.insert(out, { text = string.format("Save stopped: %d of %s saved, 1 failed, %d not attempted",
      #result.completed, plural(#result.requests, "work item"), #result.not_attempted), kind = "title" })
  end
  local done = {}
  for _, req in ipairs(result.completed) do append_all(done, request_lines(req, created)) end
  section(out, "Completed", "change", done)
  if result.failed then
    local req = result.failed.request
    local failed = request_lines(req, created)
    table.insert(failed, "error: " .. tostring(result.failed.error.message))
    section(out, string.format("Failed: nothing was written to %s", M.request_label(req)), "rejection", failed)
  end
  local skipped = {}
  for _, req in ipairs(result.not_attempted) do append_all(skipped, request_lines(req, created)) end
  section(out, "Not attempted", "note", skipped)
  return out
end

return M
