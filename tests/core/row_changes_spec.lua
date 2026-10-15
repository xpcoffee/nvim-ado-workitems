-- Which fields of a row changed (plan 0002 UX2.4), and the agreement with
-- the change plan that the views' ~ markers rely on.
local records = require("tests.support.records")
local row_changes = require("ado.core.row_changes")

local new, area, item = records.new, records.area, records.item
local item_line, field_line, line_of = records.item_line, records.field_line, records.line_of

local function row(fields)
  local r = { kind = "item", slot = "area", type = "Task", state = "To Do", title = "Write API",
    assignee = "Me Myself", tags = "api; backend" }
  for k, v in pairs(fields or {}) do r[k] = v end
  return r
end

test("UX2.4 each column edit names its field, trimmed", function()
  local s = row()
  for field, value in pairs({ title = "Write the API", type = "Bug", state = "Doing", assignee = "Alex",
    tags = "api" }) do
    local diffs, problem = row_changes.changed(s, row({ [field] = "  " .. value .. " " }))
    eq(problem, nil)
    eq(diffs, { [field] = value }, field)
  end
end)

test("UX2.4 whitespace only, and tags reordered, repeated or recased, change nothing", function()
  local s = row()
  eq(row_changes.changed(s, row({ title = "  Write API  ", state = "To Do " })), {})
  eq(row_changes.changed(row({ tags = "a; B" }), row({ tags = "b;a" })), {})
  eq(row_changes.changed(s, row({ tags = " Backend;api ; api" })), {})
  eq(row_changes.changed(row({ tags = "" }), row({ tags = " ; " })), {})
end)

test("UX2.4 the item's own title line compares its title; field lines their value", function()
  local self_row = { kind = "item", slot = "self", title = "Checkout story" }
  eq(row_changes.changed(self_row, { kind = "item", title = "Checkout story " }), {})
  eq(row_changes.changed(self_row, { kind = "item", title = "Checkout" }), { title = "Checkout" })
  local _, problem = row_changes.changed(self_row, row())
  eq(problem, "self_copy")
  local field = { kind = "field", field = "tags", value = "api; backend" }
  eq(row_changes.changed(field, { kind = "field", field = "tags", value = "backend;API" }), {})
  eq(row_changes.changed(field, { kind = "field", field = "tags", value = "api" }), { tags = "api" })
  _, problem = row_changes.changed(field, { kind = "field", field = "state", value = "x" })
  eq(problem, "field_name")
end)

test("UX2.4 a row that no longer reads as its kind, or lost its separators, is a problem", function()
  local _, problem = row_changes.changed(row(), { kind = "item", title = "Task To Do Write API" })
  eq(problem, "separators")
  _, problem = row_changes.changed(row(), { kind = "heading", label = "x" })
  eq(problem, "kind")
  eq(row_changes.changed({ kind = "area", name = "A" }, { kind = "area", name = "B" }), { name = "B" })
end)

test("UX2.4 marks: changed rows, typed and pasted lines, copies, and removed rows", function()
  local snapshot = {
    row({ row_id = 1, title = "One" }),
    row({ row_id = 2, title = "Two" }),
    row({ row_id = 3, title = "Three" }),
  }
  local current = {
    row({ row_id = 1, title = "One, edited" }),
    row({ row_id = 2, title = "Two" }),
    row({ row_id = 2, title = "Two" }),
    row({ row_id = 9, title = "From another view" }),
    { kind = "item", title = "A typed line" },
    { kind = "item", title = "" },
  }
  local m = row_changes.marks(snapshot, current)
  eq(m.marks, { [1] = "changed", [3] = "new", [4] = "new", [5] = "new" })
  eq({ m.changed, m.new, m.removed }, { 1, 3, 1 })
end)

test("UX2.4 marks after an undo to the loaded text: nothing", function()
  local snapshot = { row({ row_id = 1 }) }
  local m = row_changes.marks(snapshot, { row({ row_id = 1 }) })
  eq(m, { marks = {}, changed = 0, new = 0, removed = 0 })
end)

-- Every column-edit scenario of plan_spec and columns_spec: the edit, and
-- the row it is made on. A row is marked ~ exactly when the save summary
-- has a line about it (an op, a note or a rejection), and the ops change
-- the fields row_changes names, so a sign and the summary never disagree.
local SCENARIOS = {
  { "retitle", function(v) item_line(v, 101).title = "Write the API" end, 101 },
  { "state", function(v) item_line(v, 101).state = "Doing" end, 101 },
  { "state in another case", function(v) item_line(v, 101).state = "doing" end, 101 },
  { "restated state", function(v) item_line(v, 101).state = "to do" end, 101 },
  { "state the type lacks", function(v) item_line(v, 101).state = "Resolved" end, 101 },
  { "assignee", function(v) item_line(v, 101).assignee = "alex.jones@example.com" end, 101 },
  { "unassign", function(v) item_line(v, 101).assignee = "" end, 101 },
  { "restated assignee", function(v) item_line(v, 101).assignee = "me@example.com" end, 101 },
  { "ambiguous assignee", function(v) item_line(v, 101).assignee = "Alex" end, 101 },
  { "tags", function(v) item_line(v, 101).tags = "backend; urgent" end, 101 },
  { "tags reordered", function(v) item_line(v, 101).tags = " Backend;api ; api" end, 101 },
  { "tags cleared", function(v) item_line(v, 101).tags = "" end, 101 },
  { "type", function(v) item_line(v, 101).type = "user story" end, 101 },
  { "type outside the set", function(v) item_line(v, 101).type = "Epic" end, 101 },
  { "type and state", function(v)
    local c = item_line(v, 101)
    c.type, c.state = "Bug", "Active"
  end, 101 },
  { "whitespace only", function(v) item_line(v, 101).title = "  Write API " end, 101 },
  { "empty title", function(v) item_line(v, 101).title = "" end, 101 },
  { "separators removed", function(v)
    local c = item_line(v, 101)
    c.type, c.state, c.assignee, c.tags, c.title = nil, nil, nil, nil, "Task To Do Write API"
  end, 101 },
}

local ITEM_SCENARIOS = {
  { "own title", function(v) item_line(v, 101, "self").title = "Write the API" end },
  { "state line", function(v) field_line(v, "state").value = "Doing" end },
  { "tags line reordered", function(v) field_line(v, "tags").value = "backend;API" end },
  { "assignee line", function(v) field_line(v, "assignee").value = "alex.jones@example.com" end },
  { "type line", function(v) field_line(v, "type").value = "Bug" end },
}

local function about(p, id)
  local fields, lines = {}, 0
  for _, op in ipairs(p.ops) do
    if op.id == id then
      lines = lines + 1
      fields[op.name] = true
      if op.state_to then fields.state = true end
    end
  end
  for _, x in ipairs(p.notes) do if x.id == id then lines = lines + 1 end end
  for _, x in ipairs(p.rejections) do if x.id == id then lines = lines + 1 end end
  return fields, lines
end

local function check(name, view, s, edit, id, find)
  edit(view)
  local p = records.compute(s, { view })
  local fields, summary_lines = about(p, id)
  local m = row_changes.marks(view.snapshot, view.current)
  local _, at = find(view)
  local snap
  for _, x in ipairs(view.snapshot) do if x.row_id == view.current[at].row_id then snap = x end end
  local diffs = row_changes.changed(snap, view.current[at])
  eq(m.marks[at] == "changed", summary_lines > 0, name .. ": a ~ exactly when the summary names the row")
  for f in pairs(fields) do ok(diffs[f] ~= nil, name .. ": the plan changes " .. f .. ", row_changes names it") end
end

test("UX2.4 every column edit: a ~ exactly when the summary names the row, with the same fields", function()
  for _, sc in ipairs(SCENARIOS) do
    local s = new()
    local v = area(s, "P\\Team\\A")
    check(sc[1], v, s, sc[2], sc[3], function(view) return item_line(view, sc[3]) end)
  end
  for _, sc in ipairs(ITEM_SCENARIOS) do
    local s = new()
    local v = item(s, 101)
    local find = sc[1] == "own title" and function(view) return item_line(view, 101, "self") end
      or function(view)
        local field = sc[1]:match("^(%l+) line")
        return field_line(view, field)
      end
    check(sc[1], v, s, sc[2], 101, find)
  end
end)

test("UX2.4 a sub-area rename and a heading edit are marked, and rejected", function()
  local s = new()
  local v = area(s, "P\\Team")
  local _, at = line_of(v, function(r) return r.kind == "area" end)
  v.current[at].name = "Renamed"
  local m = row_changes.marks(v.snapshot, v.current)
  eq(m.marks[at], "changed")
  eq(#records.compute(s, { v }).rejections, 1)
end)
