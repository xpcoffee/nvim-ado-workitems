-- Structural edits (RFC 0001 R5 table, R5.4 to R5.12, R5.18): deleting,
-- pasting, moving and adding rows across views, planned from rows the core
-- loaded through the fake transport, and applied to the fake.
--
-- Seed hierarchy: 100 (User Story, P\Team\A) has children 101 and 102,
-- 102 has child 106, and 100 is Related to 105. 105 (User Story,
-- P\Team\B) has child 107 (Done). 103 (P\Team\A) and 104 (P\Team\B) have
-- no parent.
local apply = require("ado.core.apply")
local records = require("tests.support.records")
local summary = require("ado.core.summary")
local workitem = require("ado.core.workitem")

local new, area, item = records.new, records.area, records.item
local item_line, field_line, heading, area_row = records.item_line, records.field_line, records.heading,
  records.area_row
local cut, yank, paste, delete, new_line = records.cut, records.yank, records.paste, records.delete, records.new_line
local compute, messages, texts, kinds = records.compute, records.messages, records.texts, records.kinds

local function run(s, p)
  local result
  apply.run(s, p, {}, function(r) result = r end)
  return result
end

local function successful_writes(fake)
  local out = {}
  for _, w in ipairs(fake.writes) do
    if not w.failed then table.insert(out, w.op) end
  end
  return out
end

local function has(list, pattern)
  for _, x in ipairs(list) do
    if x.message:find(pattern, 1, true) then return true end
  end
  return false
end

local function all_messages(list)
  return table.concat(records.messages(list), "\n")
end

local function parent_of(fake, id)
  return fake.items[id].fields["System.Parent"]
end

test("A0001-6 a titled new line under N's children is one create with parent N and N's area", function()
  local s, fake = new()
  local v = item(s, 100)
  new_line(v, heading(v, "children"), { title = "Write the changelog" })
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "create", type = "Task", title = "Write the changelog", tags = "", area = "P\\Team\\A",
    parent = 100, project = "P", views = { v.key }, line = 9 } })
  local result = run(s, p)
  eq(successful_writes(fake), { "create_work_item" }, "the parent link is part of the create")
  local id = result.created[p.ops[1]]
  eq(id, 1000)
  eq(parent_of(fake, id), 100)
  eq(fake.items[id].fields["System.AreaPath"], "P\\Team\\A")
  eq(texts(summary.report(result)), { "Saved 1 change to 1 work item", "Completed",
    "  new Task 'Write the changelog' in P\\Team\\A, parent #100 -> #1000" })
  eq(summary.result_line(result), "saved 1 change to 1 work item: 1 created (#1000)")
end)

test("A0001-7 moving child C from P's view to Q's view is one parent change, and no create", function()
  local s, fake = new()
  local from, to = item(s, 100), item(s, 105)
  paste(to, cut(from, 101), heading(to, "children"))
  local p = compute(s, { from, to })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "set_parent", id = 101, from = 100, to = 105, title = "Write API",
    views = { from.key, to.key }, expect_rev = 1 } })
  run(s, p)
  eq(successful_writes(fake), { "patch_work_item" }, "one request on the child")
  eq(fake.writes[1].params.id, 101)
  eq(parent_of(fake, 101), 105)
end)

test("A0001-8 moving X from area A's view to area B's view is one area path update", function()
  local s, fake = new()
  local a, b = area(s, "P\\Team\\A"), area(s, "P\\Team\\B")
  paste(b, cut(a, 103))
  local p = compute(s, { a, b })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "set_area", id = 103, field = "System.AreaPath", name = "area", from = "P\\Team\\A",
    to = "P\\Team\\B", title = "Fix login", views = { a.key, b.key }, expect_rev = 1 } })
  eq(texts(summary.lines(p)), { "Save 1 change to Azure DevOps?", "Parent and area changes",
    "  #103 'Fix login' area: P\\Team\\A -> P\\Team\\B" })
  run(s, p)
  eq(fake.items[103].fields["System.AreaPath"], "P\\Team\\B")
end)

test("A0001-9 deleting X from area A's view only is an empty plan, and the summary lists X as no change", function()
  local s, fake = new()
  local a = area(s, "P\\Team\\A")
  cut(a, 103)
  local p = compute(s, { a })
  eq(p.ops, {})
  eq(p.rejections, {})
  eq(messages(p.notes), { "#103 deleted from " .. a.key .. " only: no change, because every work item needs an"
    .. " area path; paste it into another area view to move it" })
  eq(p.notes[1].rule, "R5.4")
  local lines, can_apply = summary.lines(p)
  eq(texts(lines), { "Nothing to save", "No change", "  " .. p.notes[1].message })
  eq(can_apply, false)
  eq(#fake.writes, 0)
end)

test("A0001-10 pasting X into area B while it stays in area A creates a copy with X's title, type, tags and parent",
  function()
    local s, fake = new()
    local a, b = area(s, "P\\Team\\A"), area(s, "P\\Team\\B")
    paste(b, yank(a, 101))
    local p = compute(s, { a, b })
    eq(p.rejections, {})
    eq(p.ops, { { kind = "create", copy_of = 101, type = "Task", title = "Write API", tags = "api; backend",
      area = "P\\Team\\B", parent = 100, project = "P", views = { b.key }, line = #b.current } })
    eq(texts(summary.lines(p)), { "Save 1 change to Azure DevOps?", "Copies: check these",
      "  copy of #101 'Write API' (Task) in P\\Team\\B, parent #100" })
    local result = run(s, p)
    local copy = fake.items[result.created[p.ops[1]]].fields
    eq({ copy["System.Title"], copy["System.WorkItemType"], copy["System.Tags"], copy["System.AreaPath"],
      copy["System.Parent"] }, { "Write API", "Task", "api; backend", "P\\Team\\B", 100 })
    eq(copy["System.AssignedTo"], nil, "a copy has no assignee")
    eq(copy["System.Description"], nil, "a copy has no description")
    eq(copy["System.State"], "To Do", "a copy takes its type's initial state")
  end)

test("A0001-11 pasting child C under Q while C stays in P's view creates a copy with parent Q and C's area",
  function()
    local s = new()
    local p_view, q_view = item(s, 100), item(s, 105)
    paste(q_view, yank(p_view, 101), heading(q_view, "children"))
    local p = compute(s, { p_view, q_view })
    eq(p.rejections, {})
    eq(#p.ops, 1)
    eq({ p.ops[1].kind, p.ops[1].copy_of, p.ops[1].parent, p.ops[1].area }, { "create", 101, 105, "P\\Team\\A" })
  end)

test("a copy of an item whose type is not in its project's types is rejected naming the row (R5.6)", function()
  local s, fake = new({ projects = { { name = "P", types = { "Task" } } } })
  local a, b = area(s, "P\\Team\\A"), area(s, "P\\Team\\B")
  local row = paste(b, yank(a, 100))
  local p = compute(s, { a, b })
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R5.6")
  eq(p.rejections[1].message, "#100 (line " .. row.line .. ") in " .. b.key
    .. ": a copy keeps the original's type, and User Story is not one of the types of project P: Task")
  local _, can_apply = summary.lines(p)
  eq(can_apply, false)
  eq(#fake.writes, 0)
end)

test("without configured types, a copy and a new line are rejected naming the row (R8.6)", function()
  local s, fake = new({ projects = false })
  local a, b = area(s, "P\\Team\\A"), area(s, "P\\Team\\B")
  local copied = paste(b, yank(a, 101))
  local added = new_line(b, nil, { title = "Gift cards" })
  local p = compute(s, { a, b })
  local why = "project P has no types configured, so a row cannot be created as or changed to a type in it;"
    .. ' add them in setup(), for example projects = { { name = "P", types = { ... } } }, choosing from the'
    .. " types P has: Task, User Story, Bug, Issue"
  eq(messages(p.rejections), {
    "#101 (line " .. copied.line .. ") in " .. b.key .. ": " .. why,
    "line " .. added.line .. " in " .. b.key .. ": " .. why,
  })
  eq(p.rejections[1].rule, "R8.6")
  eq(p.rejections[2].rule, "R8.6")
  eq(#fake.writes, 0)
end)

test("A0001-12 pasting X, which has no parent, under Q is one parent link and no create", function()
  local s, fake = new()
  local a, q = area(s, "P\\Team\\A"), item(s, 105)
  paste(q, yank(a, 103), heading(q, "children"))
  local p = compute(s, { a, q })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "add_link", id = 103, rel = workitem.PARENT, target = 105, title = "Fix login",
    target_title = "Payments story", views = { q.key }, expect_rev = 1 } })
  eq(texts(summary.lines(p)), { "Save 1 change to Azure DevOps?", "Link additions",
    "  #103 'Fix login': add parent #105 'Payments story'" })
  run(s, p)
  eq(parent_of(fake, 103), 105)
end)

test("A0001-13 deleting child C from P's view only is one link removal and no state change", function()
  local s, fake = new()
  local v = item(s, 100)
  cut(v, 101)
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(p.ops, { { kind = "remove_link", id = 101, rel = workitem.PARENT, target = 100, title = "Write API",
    target_title = "Checkout story", views = { v.key }, expect_rev = 1 } })
  local lines = summary.lines(p)
  eq(texts(lines), { "Save 1 change to Azure DevOps?", "Link removals: check these",
    "  #101 'Write API': remove parent #100 'Checkout story'" })
  eq(lines[3].kind, "removal", "link removals stand out")
  run(s, p)
  eq(parent_of(fake, 101), nil)
  eq(fake.items[101].fields["System.State"], "To Do")
  eq(successful_writes(fake), { "patch_work_item" })
end)

test("A0001-14 pasting M into N's parent row while N's parent row stays is rejected", function()
  local s, fake = new()
  local n, b = item(s, 101), area(s, "P\\Team\\B")
  paste(n, yank(b, 104), item_line(n, 100, "parent"))
  local p = compute(s, { n, b })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R5.9")
  ok(p.rejections[1].message:find("#101 already has parent #100", 1, true), p.rejections[1].message)
  eq(#fake.writes, 0)
end)

test("pasting M into the parent row of N, which has no parent, sets it; replacing the parent row moves N", function()
  local s = new()
  local n, b = item(s, 103), area(s, "P\\Team\\B")
  paste(n, yank(b, 105), heading(n, "parent"))
  local p = compute(s, { n, b })
  eq(p.rejections, {})
  eq({ p.ops[1].kind, p.ops[1].id, p.ops[1].target }, { "add_link", 103, 105 })

  local m = item(s, 101)
  cut(m, 100, "parent")
  paste(m, yank(b, 105), field_line(m, "tags"))
  p = compute(s, { m, b })
  eq(p.rejections, {})
  eq({ p.ops[1].kind, p.ops[1].id, p.ops[1].from, p.ops[1].to }, { "set_parent", 101, 100, 105 })
end)

test("A0001-15 deleting expanded row C with its displayed children is one link removal, for C only", function()
  local s = new()
  local v = item(s, 100, { expand = { 102 } })
  cut(v, 102)
  cut(v, 106)
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(kinds(p), { "remove_link" })
  eq({ p.ops[1].id, p.ops[1].target }, { 102, 100 })
  eq(messages(p.notes), { "#106 stays a child of #102: it went with #102 as one block" })
end)

test("deleting a descendant row on its own removes only its link to the row it is shown under (R5.8)", function()
  local s = new()
  local v = item(s, 100, { expand = { 102 } })
  cut(v, 106)
  local p = compute(s, { v })
  eq(kinds(p), { "remove_link" })
  eq({ p.ops[1].id, p.ops[1].target }, { 106, 102 })
end)

test("moving an expanded block moves only its top row; the descendants stay attached (R5.8)", function()
  local s = new()
  local from, to = item(s, 100, { expand = { 102 } }), item(s, 105)
  local block = cut(from, 102)
  for _, r in ipairs(cut(from, 106)) do table.insert(block, r) end
  paste(to, block, heading(to, "children"))
  local p = compute(s, { from, to })
  eq(p.rejections, {})
  eq(kinds(p), { "set_parent" })
  eq({ p.ops[1].id, p.ops[1].from, p.ops[1].to }, { 102, 100, 105 })
end)

test("a pasted copy's displayed descendants are not copied, and the summary says so (R5.8)", function()
  local s = new()
  local from, to = item(s, 100, { expand = { 102 } }), item(s, 105)
  local block = yank(from, 102)
  for _, r in ipairs(yank(from, 106)) do table.insert(block, r) end
  paste(to, block, heading(to, "children"))
  local p = compute(s, { from, to })
  eq(p.rejections, {})
  eq(kinds(p), { "create" })
  eq(p.ops[1].copy_of, 102)
  eq(messages(p.notes), { "#106 is shown under #102 but is not copied with it: a copy has no children,"
    .. " so the row goes on reload" })
  eq(p.notes[1].kind, "warning")
end)

test("A0001-16 cutting X once and pasting it into two views is rejected, naming X", function()
  local s, fake = new()
  local a, b, d = area(s, "P\\Team\\A"), area(s, "P\\Team\\B"), area(s, "P\\Team\\D")
  local rows = cut(a, 103)
  paste(b, rows)
  paste(d, rows)
  local p = compute(s, { a, b, d })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].id, 103)
  eq(p.rejections[1].rule, "R5.10")
  ok(p.rejections[1].message:find("^#103 was cut once and pasted into 2 places"), p.rejections[1].message)

  local p_view, q1, q2 = item(s, 100), item(s, 105), item(s, 103)
  local child = cut(p_view, 101)
  paste(q1, child, heading(q1, "children"))
  paste(q2, child, heading(q2, "children"))
  p = compute(s, { p_view, q1, q2 })
  eq(p.ops, {})
  ok(p.rejections[1].message:find("^#101 was cut once and pasted into 2 places"), p.rejections[1].message)
  eq(#fake.writes, 0)
end)

test("A0001-17 moving child C under Q leaves C's area path unchanged", function()
  local s, fake = new()
  local from, to = item(s, 100), item(s, 105)
  paste(to, cut(from, 101), heading(to, "children"))
  local p = compute(s, { from, to })
  for _, op in ipairs(p.ops) do ok(op.kind ~= "set_area", "no area change") end
  run(s, p)
  eq(parent_of(fake, 101), 105)
  eq(fake.items[101].fields["System.AreaPath"], "P\\Team\\A", "105 is in P\\Team\\B; 101 stays in P\\Team\\A")
end)

test("A0001-21 a row the state filter hid is not in the snapshot, so it cannot be deleted: an empty plan", function()
  local s, fake = new()
  local open = item(s, 105)
  for _, r in ipairs(open.snapshot) do ok(r.id ~= 107, "the Done child is hidden") end
  local all = item(s, 105, { all = true })
  item_line(all, 107)
  eq(compute(s, { open }), { ops = {}, notes = {}, rejections = {} })
  local b = area(s, "P\\Team\\B")
  for _, r in ipairs(b.snapshot) do ok(r.id ~= 107, "hidden in the open area view too") end
  eq(compute(s, { b }), { ops = {}, notes = {}, rejections = {} })
  eq(#fake.writes, 0)
end)

test("A0001-22 moving N under one of its own descendants is rejected before any transport call", function()
  local s, fake = new()
  local top, low = item(s, 100), item(s, 106)
  paste(low, cut(top, 102), heading(low, "children"))
  local calls = #fake.calls
  local p = compute(s, { top, low })
  eq(#fake.calls, calls, "the loaded rows show every ancestor, so planning makes no call")
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R5.12")
  eq(p.rejections[1].message, "putting #102 under #106 would make #102 its own ancestor")
  eq(#fake.writes, 0)
end)

test("the cycle check reads ancestors the views do not show, one get_work_item per level", function()
  local s, fake = new()
  local leaf, b = item(s, 106), area(s, "P\\Team\\B")
  -- 106's view shows 106's parent 102 and, through 102's row, 100; 100's
  -- own parent is not shown, so it is read once.
  paste(leaf, yank(b, 104), heading(leaf, "children"))
  local calls = #fake.calls
  local p = compute(s, { leaf, b })
  eq(p.rejections, {})
  eq(#fake.calls - calls, 1)
  eq(fake.calls[#fake.calls].op, "get_work_item")
  eq(fake.calls[#fake.calls].params.id, 100)
end)

test("A0001-27 a new line with a blank type in a child list is created with the configured child-list default type",
  function()
    local s = new({ default_types = { area = "Task", children = "Bug" } })
    local v = item(s, 100)
    new_line(v, heading(v, "children"), { type = "", state = "", title = "Broken checkout", assignee = "", tags = "" })
    local p = compute(s, { v })
    eq(p.rejections, {})
    eq(kinds(p), { "create" })
    eq({ p.ops[1].type, p.ops[1].parent }, { "Bug", 100 })
  end)

test("a new line in an area view is created in that area, with the area default type and no parent", function()
  local s = new({ default_types = { area = "User Story", children = "Task" } })
  local a = area(s, "P\\Team\\A")
  new_line(a, nil, { title = "Gift cards" })
  local p = compute(s, { a })
  eq(p.ops, { { kind = "create", type = "User Story", title = "Gift cards", tags = "", area = "P\\Team\\A",
    project = "P", views = { a.key }, line = #a.current } })
  eq(texts(summary.lines(p)), { "Save 1 change to Azure DevOps?", "New items",
    "  new User Story 'Gift cards' in P\\Team\\A, no parent" })
end)

test("a new line's type matches the project's types without regard to case; another type rejects naming the row",
  function()
    local s = new({ projects = { { name = "P", types = { "Task", "User Story" } } } })
    local a = area(s, "P\\Team\\A")
    new_line(a, nil, { type = "user story", state = "", title = "Gift cards", assignee = "", tags = "" })
    local p = compute(s, { a })
    eq(p.ops[1].type, "User Story")
    local bad = new_line(a, nil, { type = "Bug", state = "", title = "Typo", assignee = "", tags = "" })
    p = compute(s, { a })
    eq(#p.rejections, 1)
    eq(p.rejections[1].rule, "R5.18")
    eq(p.rejections[1].message, "line " .. bad.line .. " in " .. a.key
      .. ": 'Bug' is not one of the types of project P: Task, User Story")
    local _, can_apply = summary.lines(p)
    eq(can_apply, false)
  end)

test("a new line with a state, or an assignee that is not one identity, is rejected; blank lines are ignored",
  function()
    local s = new()
    local a = area(s, "P\\Team\\A")
    new_line(a, nil, { type = "Task", state = "Doing", title = "Started", assignee = "Alex", tags = "x" })
    new_line(a, nil, { title = "   " })
    local p = compute(s, { a })
    eq(p.ops, {})
    eq(#p.rejections, 2)
    ok(p.rejections[1].message:find("leave the state column empty", 1, true), p.rejections[1].message)
    ok(p.rejections[2].message:find("'Alex' matches 2 identities", 1, true), p.rejections[2].message)
    eq(p.rejections[2].rule, "R5.19")
  end)

test("new lines in the parent row, a link section or among the item's own lines are rejected", function()
  local s = new()
  local v = item(s, 101)
  new_line(v, item_line(v, 100, "parent"), { title = "A new parent" })
  local w = item(s, 100)
  new_line(w, heading(w, "System.LinkTypes.Related"), { title = "Linked" })
  new_line(w, field_line(w, "type"), { title = "Among the fields" })
  local p = compute(s, { v, w })
  eq(p.ops, {})
  ok(p.rejections[1].message:find("a new line cannot be a parent", 1, true), p.rejections[1].message)
  ok(p.rejections[2].message:find("new lines go under the Children heading", 1, true), p.rejections[2].message)
  ok(p.rejections[3].message:find("a new line cannot be linked", 1, true), p.rejections[3].message)
end)

test("deleting a row from a link section removes the link from both items", function()
  local s, fake = new()
  local v = item(s, 100)
  cut(v, 105)
  local p = compute(s, { v })
  eq(p.ops, { { kind = "remove_link", id = 100, rel = "System.LinkTypes.Related", target = 105, name = "Related",
    title = "Checkout story", target_title = "Payments story", views = { v.key }, expect_rev = 1 } })
  eq(texts(summary.lines(p))[3], "  #100: remove Related link to #105 'Payments story'")
  run(s, p)
  eq(#fake.items[105].relations, 1, "the link is gone from both ends; 105 keeps its child")
end)

test("pasting into an existing link section adds the link; one already linked is no change", function()
  local s = new()
  local v, a = item(s, 100), area(s, "P\\Team\\A")
  paste(v, yank(a, 103), heading(v, "System.LinkTypes.Related"))
  local p = compute(s, { v, a })
  eq(p.rejections, {})
  eq({ p.ops[1].kind, p.ops[1].id, p.ops[1].rel, p.ops[1].target, p.ops[1].name },
    { "add_link", 100, "System.LinkTypes.Related", 103, "Related" })

  local again, b = item(s, 100), area(s, "P\\Team\\B")
  paste(again, yank(b, 105), heading(again, "System.LinkTypes.Related"))
  p = compute(s, { again, b })
  eq(p.ops, {})
  eq(messages(p.notes), { "#105 is already linked to #100; the state filter may hide its row" })
end)

test("deleting one link from both of its ends is one link removal", function()
  local s = new()
  local v, w = item(s, 100), item(s, 105)
  cut(v, 105)
  cut(w, 100, "link")
  local p = compute(s, { v, w })
  eq(kinds(p), { "remove_link" })
  eq(p.ops[1].views, { v.key, w.key })
end)

test("pasting a row on the area row, or among the item's own lines, is rejected (R5.11)", function()
  local s = new()
  local v, a = item(s, 100), area(s, "P\\Team\\A")
  paste(v, yank(a, 103), area_row(v))
  paste(v, yank(a, 103), item_line(v, 100, "self"))
  local p = compute(s, { v, a })
  eq(p.ops, {})
  eq(p.rejections[1].rule, "R5")
  ok(p.rejections[1].message:find("rows cannot be pasted among the item's own lines", 1, true))
  eq(p.rejections[2].rule, "R5.11")
end)

test("pasting a parentless item under two parents is rejected (R5.9)", function()
  local s = new()
  local a, p1, p2 = area(s, "P\\Team\\A"), item(s, 100), item(s, 105)
  local rows = yank(a, 103)
  paste(p1, rows, heading(p1, "children"))
  paste(p2, rows, heading(p2, "children"))
  local p = compute(s, { a, p1, p2 })
  eq(p.ops, {})
  eq(p.rejections[1].rule, "R5.9")
  eq(p.rejections[1].message, "#103 would get 2 parents (#100, #105), and ADO allows one parent per item")
end)

test("a pasted row whose ID the registry no longer holds is rejected with its line", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local c = new_line(a, nil, { type = "Task", state = "To Do", title = "Ghost", assignee = "", tags = "" })
  c.row_id = 99999
  local p = compute(s, { a })
  eq(p.ops, {})
  ok(p.rejections[1].message:find("^line " .. c.line .. " in .*this row's ID is not known"), p.rejections[1].message)
end)

test("deleting or moving a heading, the area row or a field line is rejected", function()
  local s = new()
  local v = item(s, 100)
  delete(v, heading(v, "children"))
  local p = compute(s, { v })
  ok(has(p.rejections, "this line was deleted"), all_messages(p.rejections))

  local w = item(s, 100)
  local row = area_row(w)
  delete(w, row)
  paste(w, { row }, heading(w, "children"))
  p = compute(s, { w })
  ok(has(p.rejections, "this line was moved"), all_messages(p.rejections))

  local a = area(s, "P\\Team")
  delete(a, records.line_of(a, function(r) return r.kind == "area" end))
  p = compute(s, { a })
  eq(p.rejections[1].rule, "R5.16")
end)

test("a moved row carries its title edit; a copied row gives the copy the edited title", function()
  local s = new()
  local a, b = area(s, "P\\Team\\A"), area(s, "P\\Team\\B")
  local rows = cut(a, 103)
  rows[1].title = "Fix the login"
  paste(b, rows)
  local p = compute(s, { a, b })
  eq(kinds(p), { "set_area", "update" })
  eq({ p.ops[2].id, p.ops[2].to }, { 103, "Fix the login" })

  local c, d = area(s, "P\\Team\\A"), area(s, "P\\Team\\D")
  local copied = yank(c, 101)
  copied[1].title = "Write API v2"
  paste(d, copied)
  p = compute(s, { c, d })
  eq(kinds(p), { "create" })
  eq(p.ops[1].title, "Write API v2")
end)

test("ops run link removals, parent changes, link additions, area changes, updates, then creates", function()
  local s = new()
  local a, b, d = area(s, "P\\Team\\A"), area(s, "P\\Team\\B"), area(s, "P\\Team\\D")
  local v, q = item(s, 100), item(s, 105)
  new_line(v, heading(v, "children"), { title = "New child" })
  paste(q, cut(v, 101), heading(q, "children"))
  cut(v, 102)
  paste(q, yank(d, 110), heading(q, "children"))
  paste(b, cut(a, 103))
  item_line(b, 104).title = "Update the docs"
  local p = compute(s, { a, b, d, v, q })
  eq(p.rejections, {})
  eq(kinds(p), { "remove_link", "set_parent", "add_link", "set_area", "update", "create" })
  eq({ p.ops[1].id, p.ops[2].id, p.ops[3].id, p.ops[4].id, p.ops[5].id }, { 102, 101, 110, 103, 104 })
end)

test("a parent change that fails leaves the item under its old parent: the request is one write", function()
  local s, fake = new()
  local from, to = item(s, 100), item(s, 105)
  paste(to, cut(from, 101), heading(to, "children"))
  local p = compute(s, { from, to })
  fake:fail_on("patch_work_item", 1)
  local result = run(s, p)
  eq(parent_of(fake, 101), 100)
  eq(result.failed.request.ops[1].kind, "set_parent")
  eq(result.failed.error.message, "fake failure on patch_work_item")
  eq(result.touched, { 101, 100, 105 })
end)

test("a create with a parent that fails creates nothing", function()
  local s, fake = new()
  local v = item(s, 100)
  new_line(v, heading(v, "children"), { title = "Orphan" })
  local p = compute(s, { v })
  fake:fail_on("create_work_item", 1)
  local result = run(s, p)
  eq(result.created[p.ops[1]], nil)
  eq(fake.items[1000], nil)
  eq(texts(summary.report(result))[2], "Failed: nothing was written to new Task 'Orphan'")
end)

test("a move, a retitle and a new link on one item are one request; a create under it comes last", function()
  local s, fake = new()
  local from, to = item(s, 100), item(s, 105)
  local moved = cut(from, 101)
  moved[1].title = "Write the API"
  paste(to, moved, heading(to, "children"))
  new_line(to, heading(to, "children"), { title = "New child" })
  local p = compute(s, { from, to })
  eq(p.rejections, {})
  local result = run(s, p)
  local order = {}
  for _, w in ipairs(fake.writes) do table.insert(order, { w.op, w.params.id or w.params.type }) end
  eq(order, { { "patch_work_item", 101 }, { "create_work_item", "Task" } })
  eq(#result.completed, 2)
  eq(parent_of(fake, 101), 105)
  eq(fake.items[101].fields["System.Title"], "Write the API")
  eq(parent_of(fake, 1000), 105)
  eq(summary.result_line(result), "saved 3 changes to 2 work items: 1 field update, 1 parent change, 1 created (#1000)")
end)

test("the revision guard checks a link target before the plan writes it, when the target has its own edit",
  function()
    local s, fake = new()
    local from, to = item(s, 100), item(s, 105)
    paste(to, cut(from, 101), heading(to, "children"))
    item_line(to, 105, "self").title = "Payments story, v2"
    local p = compute(s, { from, to })
    eq(kinds(p), { "set_parent", "update" })
    fake:edit_remotely(105, { ["System.Title"] = "Renamed in the web UI" })
    local result = run(s, p)
    eq(#fake.writes, 0, "105 changed remotely, so not even the move starts")
    eq(result.failed.error.kind, "conflict")
    eq(result.failed.error.message, "#105 changed remotely (rev 1 -> 2)")
  end)

test("an item loaded at different revisions in two views with a structural op is rejected (R5.14)", function()
  local s, fake = new()
  local a = area(s, "P\\Team\\A")
  fake:edit_remotely(101, { ["System.Title"] = "Write API" })
  local v, b = item(s, 100), area(s, "P\\Team\\B")
  paste(b, cut(a, 101))
  local p = compute(s, { a, v, b })
  eq(p.ops, {})
  eq(p.rejections[1].rule, "R5.14")
  eq(p.rejections[1].message, "#101 was loaded at different revisions in " .. a.key .. ", " .. v.key
    .. "; reload those views before saving")
end)
