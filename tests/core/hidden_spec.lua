-- RFC 0001 R5.13: when a save leaves an item where the destination view's
-- filters will hide it after reload, the plan still makes the change and
-- the summary says the item will not appear there.
--
-- Seed: P\Team\A holds 100 (User Story), 101 (tags "api; backend"), 102
-- (Alex Smith), 103, 106 and 111, open; 100, 101 and 103 are assigned to
-- Me Myself. P\Team\B holds 104 and 105 (User Story), open and unassigned,
-- and 107 (Done), a child of 105. 112 (Bug, Resolved, open for Bug) in
-- P\Team\C is assigned to Me Myself.
local records = require("tests.support.records")

local new, area, item = records.new, records.area, records.item
local item_line, heading, cut, yank, paste, new_line = records.item_line, records.heading, records.cut,
  records.yank, records.paste, records.new_line
local compute, messages, kinds = records.compute, records.messages, records.kinds

test("a closed item moved into an open-only view is moved, with a warning it will not appear", function()
  local s = new()
  local b = area(s, "P\\Team\\B", { state = "all" })
  local a = area(s, "P\\Team\\A")
  paste(a, cut(b, 107))
  local p = compute(s, { b, a })
  eq(kinds(p), { "set_area" })
  eq(messages(p.notes), { "#107 will not appear in " .. a.key .. " after reload: the view's state filter hides Done" })
  eq(p.notes[1].rule, "R5.13")
end)

test("a closed child moved under an item view's open-only children gets the warning too", function()
  local s = new()
  local from = item(s, 105, { all = true })
  local to = item(s, 100)
  paste(to, cut(from, 107), heading(to, "children"))
  local p = compute(s, { from, to })
  eq(kinds(p), { "set_parent" })
  eq(messages(p.notes), { "#107 will not appear in ado://item/100 after reload: the view's state filter hides Done" })
end)

test("a copy whose type the view's type filter leaves out is created, with a warning", function()
  local s = new()
  local b = area(s, "P\\Team\\B")
  local a = area(s, "P\\Team\\A", { types = { "Task" } })
  paste(a, yank(b, 105))
  local p = compute(s, { b, a })
  eq(kinds(p), { "create" })
  eq(messages(p.notes), { "the copy of #105 will not appear in " .. a.key
    .. " after reload: the view's type filter hides User Story" })
end)

test("an item pasted into a view filtered by another assignee gets a warning", function()
  local s = new()
  local c = area(s, "P\\Team\\C")
  local a = area(s, "P\\Team\\A", { assignee = "Alex Smith" })
  paste(a, cut(c, 112))
  local p = compute(s, { c, a })
  eq(kinds(p), { "set_area" })
  eq(messages(p.notes), { "#112 will not appear in " .. a.key
    .. " after reload: the view's assignee filter (Alex Smith) hides items assigned to Me Myself" })
end)

test("an unassigned item moved into an @Me view gets a warning; one assigned to the user does not", function()
  local s = new()
  local b = area(s, "P\\Team\\B")
  local c = area(s, "P\\Team\\C")
  local a = area(s, "P\\Team\\A", { assignee = "@Me" })
  paste(a, cut(b, 104))
  paste(a, cut(c, 112))
  local p = compute(s, { b, c, a })
  eq(kinds(p), { "set_area", "set_area" })
  eq(messages(p.notes), { "#104 will not appear in " .. a.key
    .. " after reload: the view's assignee filter hides unassigned items" })
end)

test("reassigning an item in an @Me view warns that it will not appear there", function()
  local s = new()
  local a = area(s, "P\\Team\\A", { assignee = "@Me" })
  item_line(a, 101).assignee = "alex s"
  local p = compute(s, { a })
  eq(#p.ops, 1)
  eq(messages(p.notes), { "#101 will not appear in " .. a.key
    .. " after reload: the view's assignee filter (@Me) hides items assigned to Alex Smith" })
end)

test("removing the tag a view filters on warns that the item will not appear", function()
  local s = new()
  local a = area(s, "P\\Team\\A", { tag = "api" })
  item_line(a, 101).tags = "backend"
  local p = compute(s, { a })
  eq(messages(p.notes), { "#101 will not appear in " .. a.key
    .. " after reload: the view's tag filter hides items without the tag 'api'" })
end)

test("a type change in a type-filtered view warns that the item will not appear", function()
  local s = new()
  local a = area(s, "P\\Team\\A", { types = { "Task" } })
  local row = item_line(a, 101)
  row.type, row.state = "Bug", "New"
  local p = compute(s, { a })
  eq(kinds(p), { "set_type" })
  eq(messages(p.notes), { "#101 will not appear in " .. a.key .. " after reload: the view's type filter hides Bug" })
end)

test("a new line in an @Me view warns unless it is assigned", function()
  local s = new()
  local a = area(s, "P\\Team\\A", { assignee = "@Me" })
  new_line(a, nil, { type = "", state = "", title = "Nobody's", assignee = "", tags = "" })
  new_line(a, nil, { type = "", state = "", title = "Mine", assignee = "me@example.com", tags = "" })
  local p = compute(s, { a })
  eq(kinds(p), { "create", "create" })
  eq(messages(p.notes), { "new Task 'Nobody's' will not appear in " .. a.key
    .. " after reload: the view's assignee filter hides unassigned items" })
end)

test("a move into a view whose filters show the item makes no warning", function()
  local s = new()
  local b = area(s, "P\\Team\\B")
  local a = area(s, "P\\Team\\A", { types = { "Task" } })
  paste(a, cut(b, 104))
  local p = compute(s, { b, a })
  eq(kinds(p), { "set_area" })
  eq(p.notes, {})
end)
