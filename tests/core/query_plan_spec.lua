-- Edits in a query list (RFC 0001 R9.3 to R9.7): its rows stand for no
-- relationship, so a field edit saves, a delete changes nothing, a paste
-- into it is rejected, and a row cut from it moves the relationship of the
-- view it is pasted into.
--
-- "mine" lists 112 (Bug, P\Team\C), 103 (Task, P\Team\A, no parent), 101
-- (Task, P\Team\A, parent 100) and 100 (User Story, P\Team\A, no parent).
-- 105 (User Story, P\Team\B) has child 107.
local apply = require("ado.core.apply")
local records = require("tests.support.records")
local summary = require("ado.core.summary")
local workitem = require("ado.core.workitem")

local new, area, item, query = records.new, records.area, records.item, records.query
local item_line, heading = records.item_line, records.heading
local cut, yank, paste, new_line = records.cut, records.yank, records.paste, records.new_line
local compute, messages, kinds = records.compute, records.messages, records.kinds

local function run(s, p)
  local result
  apply.run(s, p, {}, function(r) result = r end)
  return result
end

local function patches(fake)
  local out = {}
  for _, w in ipairs(fake.writes) do
    if not w.failed then table.insert(out, w.op == "patch_work_item" and w.params.id or w.op) end
  end
  return out
end

local function field(fake, id, ref)
  return fake.items[id].fields[ref]
end

test("A0001-33 field edits in a query list save as in other views, one request per item", function()
  local s, fake = new()
  local q = query(s)
  local r101 = item_line(q, 101)
  r101.title, r101.state, r101.tags = "Write the API", "Doing", "api"
  local r103 = item_line(q, 103)
  r103.type, r103.assignee = "bug", "Alex Smith"
  r103.state = "New"
  local p = compute(s, { q })
  eq(p.rejections, {})
  eq(kinds(p), { "set_type", "update", "update", "update", "update" })
  eq(p.ops[1], { kind = "set_type", id = 103, field = "System.WorkItemType", name = "type", from = "Task",
    to = "Bug", state_from = "To Do", state_to = "New", views = { q.key }, expect_rev = 1 })
  run(s, p)
  eq(patches(fake), { 103, 101 })
  eq(field(fake, 101, "System.Title"), "Write the API")
  eq(field(fake, 101, "System.State"), "Doing")
  eq(field(fake, 101, "System.Tags"), "api")
  eq(field(fake, 103, "System.WorkItemType"), "Bug")
  eq(field(fake, 103, "System.AssignedTo").uniqueName, "alex.smith@example.com")
end)

test("A0001-34 deleting a row from a query list with no paste is an empty plan, listed as no change", function()
  local s, fake = new()
  local q = query(s)
  cut(q, 101)
  local p = compute(s, { q })
  eq(p.ops, {})
  eq(p.rejections, {})
  eq(messages(p.notes), { "#101 deleted from " .. q.key .. " only: no change, because a query list's rows"
    .. " stand for no relationship; paste it into an area view or under a parent to move it" })
  eq(p.notes[1].rule, "R9.4")
  eq(#fake.writes, 0)
end)

test("A0001-35 pasting a row or typing a new line in a query list is rejected, naming the line", function()
  local s = new()
  local q, b = query(s), area(s, "P\\Team\\B")
  paste(q, yank(b, 104))
  new_line(q, nil, { title = "A new task" })
  local p = compute(s, { q, b })
  eq(p.ops, {})
  eq(#p.rejections, 2)
  eq(p.rejections[1].rule, "R9.5")
  eq(p.rejections[1].message, "#104 (line 5) in " .. q.key .. ": a query list has no place to put an item: its"
    .. " rows stand for no relationship. Paste the row into an area view or an item view instead, or delete"
    .. " the line")
  eq(p.rejections[2].rule, "R9.5")
  ok(p.rejections[2].message:find("line 6", 1, true), p.rejections[2].message)
end)

test("reordering rows within a query list changes nothing", function()
  local s = new()
  local q = query(s)
  paste(q, cut(q, 112))
  eq(compute(s, { q }), { ops = {}, notes = {}, rejections = {} })
end)

test("A0001-36 a row cut from a query list and pasted into area B's view moves the item to area B", function()
  local s, fake = new()
  local q, b = query(s), area(s, "P\\Team\\B")
  paste(b, cut(q, 103))
  local p = compute(s, { q, b })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "set_area", id = 103, field = "System.AreaPath", name = "area", from = "P\\Team\\A",
    to = "P\\Team\\B", title = "Fix login", views = { q.key, b.key }, expect_rev = 1 } })
  eq(p.notes, {})
  run(s, p)
  eq(field(fake, 103, "System.AreaPath"), "P\\Team\\B")
end)

test("A0001-37 a row cut from a query list and pasted under Q is reparented from its loaded parent to Q", function()
  local s, fake = new()
  local q, to = query(s), item(s, 105)
  paste(to, cut(q, 101), heading(to, "children"))
  local p = compute(s, { q, to })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "set_parent", id = 101, from = 100, to = 105, title = "Write API",
    views = { q.key, to.key }, expect_rev = 1 } })
  run(s, p)
  eq(field(fake, 101, "System.Parent"), 105)
  eq(field(fake, 101, "System.AreaPath"), "P\\Team\\A", "a move under a parent keeps the area (R5.11)")
end)

test("a row cut from a query list for an item with no parent, pasted under Q, gets parent Q", function()
  local s, fake = new()
  local q, to = query(s), item(s, 105)
  paste(to, cut(q, 103), heading(to, "children"))
  local p = compute(s, { q, to })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "add_link", id = 103, rel = workitem.PARENT, target = 105, title = "Fix login",
    target_title = "Payments story", views = { to.key }, expect_rev = 1 } })
  run(s, p)
  eq(field(fake, 103, "System.Parent"), 105)
end)

test("A0001-38 a row yanked from a query list and pasted into area B's view is a copy", function()
  local s = new()
  local q, b = query(s), area(s, "P\\Team\\B")
  paste(b, yank(q, 101))
  local p = compute(s, { q, b })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "create", copy_of = 101, type = "Task", title = "Write API", tags = "api; backend",
    area = "P\\Team\\B", parent = 100, project = "P", views = { b.key }, line = #b.current } })
end)

test("A0001-39 one row cut from a query list and pasted into two views is rejected, naming the item", function()
  local s, fake = new()
  local q, b, to = query(s), area(s, "P\\Team\\B"), item(s, 105)
  local rows = cut(q, 103)
  paste(b, rows)
  paste(to, rows, heading(to, "children"))
  local p = compute(s, { q, b, to })
  eq(p.ops, {})
  eq(messages(p.rejections), { "#103 was cut from " .. q.key .. " and pasted into 2 places (" .. b.key
    .. ", ado://item/105); which paste is the move would be arbitrary. Keep one paste, or undo the cut" })
  eq(p.rejections[1].rule, "R5.10")
  eq(#fake.writes, 0)
end)

test("A0001-40 a row cut from a query list and pasted under its own descendant is rejected", function()
  local s, fake = new()
  local q, under = query(s), item(s, 101)
  paste(under, cut(q, 100), heading(under, "children"))
  local p = compute(s, { q, under })
  eq(p.ops, {})
  eq(p.rejections[1].rule, "R5.12")
  eq(p.rejections[1].message, "putting #100 under #101 would make #100 its own ancestor")
  eq(#fake.writes, 0)
end)

test("a row cut from a query list and pasted into a parent row sets that parent, as a kept original does", function()
  local s = new()
  local q, n = query(s), item(s, 103)
  paste(n, cut(q, 100), heading(n, "parent"))
  local p = compute(s, { q, n })
  eq(p.rejections, {})
  eq({ p.ops[1].kind, p.ops[1].id, p.ops[1].target }, { "add_link", 103, 100 })
  eq(#p.ops, 1)
  eq(p.notes, {}, "the row was pasted, so it is not listed as no change")
end)

test("A0001-41 a state edit that the query list's filter hides plans the change and warns", function()
  local s = new()
  local q = query(s)
  item_line(q, 103).state = "Done"
  local p = compute(s, { q })
  eq(#p.ops, 1)
  eq(messages(p.notes), { "#103 will not appear in " .. q.key
    .. " after reload: the view's state filter hides Done" })
end)

test("a moved row's edits go in the same request as the move", function()
  local s, fake = new()
  local q, b = query(s), area(s, "P\\Team\\B")
  local rows = cut(q, 103)
  rows[1].title = "Fix the login"
  paste(b, rows)
  local p = compute(s, { q, b })
  eq(kinds(p), { "set_area", "update" })
  local result = run(s, p)
  eq(patches(fake), { 103 })
  eq(summary.result_line(result), "saved 2 changes to 1 work item: 1 field update, 1 area change")
end)
