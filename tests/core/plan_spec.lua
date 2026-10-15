-- The change plan for column edits (title and state) and its summary,
-- planned from rows the core loaded through the fake transport. Structural
-- edits are in structure_spec.lua.
local plan = require("ado.core.plan")
local records = require("tests.support.records")
local summary = require("ado.core.summary")

local new, area, item = records.new, records.area, records.item
local line_of, item_line, field_line = records.line_of, records.item_line, records.field_line
local compute, messages, texts = records.compute, records.messages, records.texts

test("an unedited view plans nothing", function()
  local s = new()
  local p = compute(s, { area(s, "P\\Team\\A") })
  eq(p, { ops = {}, notes = {}, rejections = {} })
  local lines, can_apply = summary.lines(p)
  eq(texts(lines), { "Nothing to save" })
  eq(can_apply, false)
end)

test("a retitle in an area view is one title update with the snapshot rev", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).title = "Write the API"
  local p = compute(s, { v })
  eq(p.ops, { { kind = "update", id = 101, field = "System.Title", name = "title", from = "Write API",
    to = "Write the API", expect_rev = 1, views = { v.key } } })
  eq(p.rejections, {})
  local lines, can_apply = summary.lines(p)
  eq(texts(lines), { "Save 1 change to Azure DevOps?", "Field changes",
    "  #101 title: 'Write API' -> 'Write the API'" })
  eq(can_apply, true)
end)

test("A0001-18 a state its type does not have is rejected, naming the row", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).state = "Resolved"
  local writes = #fake.writes
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].id, 101)
  eq(p.rejections[1].rule, "R5.7")
  ok(p.rejections[1].message:find("#101 (line ", 1, true), p.rejections[1].message)
  ok(p.rejections[1].message:find("'Resolved' is not a state of Task", 1, true), p.rejections[1].message)
  eq(#fake.writes, writes)
  local _, can_apply = summary.lines(p)
  eq(can_apply, false)
end)

test("a state edit matches the type's states without regard to case", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).state = "doing"
  local p = compute(s, { v })
  eq(#p.ops, 1)
  eq(p.ops[1].to, "Doing")
end)

test("A0001-19 retitling an item differently in two views is rejected, naming the item and the views", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local i = item(s, 100)
  item_line(a, 101).title = "Write the API"
  item_line(i, 101, "child").title = "Write an API"
  local p = compute(s, { a, i })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R5.10")
  eq(p.rejections[1].message, "#101 has conflicting title edits: 'Write the API' in " .. a.key
    .. " and 'Write an API' in ado://item/100")
  eq(p.rejections[1].views, { a.key, "ado://item/100" })
end)

test("A0001-19 conflicting state edits in two views are rejected too", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local i = item(s, 100)
  item_line(a, 102).state = "To Do"
  item_line(i, 102, "child").state = "Done"
  local p = compute(s, { a, i })
  eq(p.ops, {})
  eq(messages(p.rejections), { "#102 has conflicting state edits: 'To Do' in " .. a.key
    .. " and 'Done' in ado://item/100" })
end)

test("the same title edit in two views makes one op naming both views", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local i = item(s, 100)
  item_line(a, 101).title = "Write the API"
  item_line(i, 101, "child").title = "Write the API"
  local p = compute(s, { a, i })
  eq(#p.ops, 1)
  eq(p.ops[1].views, { a.key, "ado://item/100" })
end)

test("A0001-20 setting an item to Resolved in an open-only view plans the change and warns", function()
  local s = new()
  local v = area(s, "P\\Team\\B")
  item_line(v, 105).state = "Resolved"
  local p = compute(s, { v })
  eq(#p.ops, 1)
  eq({ p.ops[1].id, p.ops[1].from, p.ops[1].to }, { 105, "New", "Resolved" })
  eq(#p.notes, 1)
  eq(p.notes[1].kind, "warning")
  eq(p.notes[1].rule, "R5.13")
  eq(p.notes[1].message, "#105 will not appear in " .. v.key
    .. " after reload: the view's state filter hides Resolved")
  local lines, can_apply = summary.lines(p)
  eq(texts(lines), { "Save 1 change to Azure DevOps?", "Field changes", "  #105 state: New -> Resolved",
    "Warnings", "  " .. p.notes[1].message })
  eq(can_apply, true)
end)

test("an item view warns for a child set to a finished state, and not for its own row", function()
  local s = new()
  local i = item(s, 100)
  item_line(i, 101, "child").state = "Done"
  field_line(i, "state").value = "Resolved"
  local p = compute(s, { i })
  eq(#p.ops, 2)
  eq(messages(p.notes), { "#101 will not appear in ado://item/100 after reload: the view's state filter hides Done" })
end)

test("a view in every state does not warn", function()
  local s = new()
  local v = area(s, "P\\Team\\B", { state = "all" })
  item_line(v, 105).state = "Resolved"
  local p = compute(s, { v })
  eq(#p.ops, 1)
  eq(p.notes, {})
end)

test("the item view's title line and state line edit the title and the state", function()
  local s = new()
  local i = item(s, 100)
  item_line(i, 100, "self").title = "Checkout story, v2"
  field_line(i, "state").value = "closed"
  local p = compute(s, { i })
  eq(p.rejections, {})
  eq(#p.ops, 2)
  eq({ p.ops[1].name, p.ops[1].to }, { "title", "Checkout story, v2" })
  eq({ p.ops[2].name, p.ops[2].to }, { "state", "Closed" })
end)

test("reordering rows within a view plans nothing: order has no meaning", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  v.current[#v.current], v.current[#v.current - 1] = v.current[#v.current - 1], v.current[#v.current]
  eq(compute(s, { v }), { ops = {}, notes = {}, rejections = {} })
end)

test("a sub-area rename is rejected (R5.16), and so is a heading edit", function()
  local s = new()
  local v = area(s, "P\\Team")
  line_of(v, function(r) return r.kind == "area" end).name = "Renamed"
  local i = item(s, 100)
  line_of(i, function(r) return r.kind == "heading" and r.slot == "children" end).label = "Kids"
  local p = compute(s, { v, i })
  eq(p.ops, {})
  eq(#p.rejections, 2)
  eq(p.rejections[1].rule, "R5.16")
  ok(p.rejections[2].message:find("headings are read-only", 1, true), p.rejections[2].message)
end)

test("a row whose separators were removed is rejected rather than read as a title", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  local c = item_line(v, 101)
  c.type, c.state, c.assignee, c.tags, c.title = nil, nil, nil, nil, "Task To Do Write API"
  local p = compute(s, { v })
  eq(p.ops, {})
  ok(p.rejections[1].message:find("four │ separators", 1, true), p.rejections[1].message)
end)

test("an empty title is rejected", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).title = ""
  local p = compute(s, { v })
  eq(p.ops, {})
  ok(p.rejections[1].message:find("a title cannot be empty", 1, true), p.rejections[1].message)
end)

test("an item loaded at different revisions in two edited views is rejected", function()
  local s, fake = new()
  local a = area(s, "P\\Team\\A")
  fake:edit_remotely(101, { ["System.Title"] = "Write API" })
  local i = item(s, 100)
  item_line(a, 101).state = "Doing"
  local p = compute(s, { a, i })
  eq(p.ops, {})
  eq(p.rejections[1].rule, "R5.14")
  eq(p.rejections[1].message, "#101 was loaded at different revisions in " .. a.key
    .. ", ado://item/100; reload those views before saving")
end)

test("restating the current state in another case is no change, listed with its reason", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).state = "to do"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(messages(p.notes), { "#101 state 'to do' is its current state, To Do" })
  local lines = summary.lines(p)
  eq(texts(lines), { "Nothing to save", "No change", "  #101 state 'to do' is its current state, To Do" })
end)

test("a rejected plan makes 0 transport calls while computing", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).state = "Bogus"
  local prepared
  plan.prepare({ v }, s, function(_, p) prepared = p end)
  local calls = #fake.calls
  local p = plan.compute({ v }, prepared)
  eq(#p.rejections, 1)
  eq(#fake.calls, calls)
end)

test("summary lists rejections first and offers no accept", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).state = "Bogus"
  item_line(v, 102).title = "Add more tests"
  local lines, can_apply = summary.lines(compute(s, { v }))
  eq(can_apply, false)
  eq(lines[1].text, "Save rejected: 1 problem, nothing will be sent")
  eq(lines[2].text, "Rejected")
  eq(lines[3].kind, "rejection")
end)

-- Cut cells (plan 0002 UX5.4). The presentation layer puts each cut cell's
-- full value in the record, and names the cut cells whose full value it
-- could not restore in `ambiguous`.

test("UX5.4 a cut cell with no known full value rejects the save, naming the row, and nothing is sent", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.title = "Write A"
  row.ambiguous = { "title" }
  local writes = #fake.writes
  local p = compute(s, { v })
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "UX5.4")
  eq(p.rejections[1].id, 101)
  eq(p.rejections[1].message, "#101 (line " .. row.line .. ") in " .. v.key .. ": the title was cut to fit the window"
    .. " and the … was edited, so its full text is not known; undo the edit, or press <leader>wx on the cell and"
    .. " edit the full title")
  local _, can_apply = summary.lines(p)
  eq(can_apply, false)
  eq(plan.applicable(p), false)
  eq(#fake.writes, writes)
end)

test("UX5.4 a cut assignee with no known value rejects without looking it up", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.assignee = "alex.jo…"
  row.ambiguous = { "assignee" }
  local calls = #fake.calls
  local p = compute(s, { v })
  eq(#fake.calls, calls, "no resolve_identity for the cut text")
  eq(#p.rejections, 1)
  ok(p.rejections[1].message:find("the assignee was cut", 1, true), p.rejections[1].message)
end)

test("UX5.4 a cut title left as it was plans nothing, and a restored edit plans the full new title", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  -- The record holds the full value of a cell the buffer shows cut.
  local p = compute(s, { v })
  eq(p.ops, {})
  item_line(v, 101).title = "Write the API, restored in full"
  p = compute(s, { v })
  eq(#p.ops, 1)
  eq(p.ops[1].to, "Write the API, restored in full")
  eq(texts(summary.lines(p))[3], "  #101 title: 'Write API' -> 'Write the API, restored in full'",
    "the summary shows the full title")
end)
