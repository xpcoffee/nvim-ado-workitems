-- The assignee, tags and type columns (RFC 0001 R5.17, R5.19 to R5.22),
-- planned from rows the core loaded through the fake gateway, and
-- applied to the fake.
--
-- Seed: 101 (Task, To Do, P\Team\A) is assigned to Me Myself with tags
-- "api; backend"; 102 (Task, Doing) is assigned to Alex Smith; two
-- identities start with "Alex". This spec adds 120, a Task in state Active,
-- which User Story also has, as Task and User Story share states in ADO.
local apply = require("ado.core.apply")
local records = require("tests.support.records")
local seed = require("tests.fixtures.seed")
local summary = require("ado.core.summary")

local area, item = records.area, records.item
local item_line, field_line, yank, paste, new_line = records.item_line, records.field_line, records.yank,
  records.paste, records.new_line
local compute, messages, texts = records.compute, records.messages, records.texts

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

local SEED = copy(seed)
for _, t in ipairs(SEED.types) do
  if t.name == "Task" then table.insert(t.states, { name = "Active", category = "InProgress" }) end
  if t.name == "User Story" then table.insert(t.states, { name = "Doing", category = "InProgress" }) end
end
table.insert(SEED.items, { id = 120, type = "Task", title = "Shared state", state = "Active", area = "P\\Team\\A",
  changed = "2026-10-01T08:00:00Z" })

local TYPES = { "Task", "User Story", "Bug" }

local function new(opts)
  opts = opts or {}
  opts.seed = opts.seed or SEED
  if opts.projects == nil then opts.projects = { { name = "P", types = TYPES } } end
  return records.new(opts)
end

local function run(s, p)
  local result
  apply.run(s, p, {}, function(r) result = r end)
  return result
end

local function calls_of(fake, op)
  local n = 0
  for _, c in ipairs(fake.calls) do if c.op == op then n = n + 1 end end
  return n
end

-- ── assignee (R5.19) ──────────────────────────────────────────────────────────

test("A0001-25 an assignee matching two identities is rejected, naming the row", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.assignee = "Alex"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R5.19")
  eq(p.rejections[1].id, 101)
  eq(p.rejections[1].line, row.line)
  ok(p.rejections[1].message:find("#101 (line " .. row.line .. ") in " .. v.key, 1, true), p.rejections[1].message)
  ok(p.rejections[1].message:find("'Alex' matches 2 identities", 1, true), p.rejections[1].message)
  eq(#fake.writes, 0)
  local _, can_apply = summary.lines(p)
  eq(can_apply, false)
end)

test("an unknown assignee is rejected, naming the row", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).assignee = "Nobody Here"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(messages(p.rejections), { "#101 (line " .. item_line(v, 101).line .. ") in " .. v.key
    .. ": no ADO identity matches 'Nobody Here'; type a name or email that matches one person" })
end)

test("the identity lookup runs before the plan, once per distinct text, and a rejected plan writes nothing",
  function()
    local s, fake = new()
    local v = area(s, "P\\Team\\A")
    item_line(v, 101).assignee = "alex"
    item_line(v, 103).assignee = "Alex"
    local before = #fake.calls
    local p = compute(s, { v })
    eq(#p.rejections, 2)
    eq(calls_of(fake, "resolve_identity"), 1)
    eq(#fake.calls - before, 1, "only the lookup: catalogs are cached")
    eq(#fake.writes, 0)
  end)

test("a partial name matching one identity assigns by unique name; the summary shows who", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).assignee = "alex s"
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(#p.ops, 1)
  eq({ p.ops[1].kind, p.ops[1].field, p.ops[1].from, p.ops[1].to },
    { "update", "System.AssignedTo", "Me Myself", "alex.smith@example.com" })
  eq(texts(summary.lines(p)), { "Save 1 change to Azure DevOps?", "Field changes",
    "  #101 assignee: 'Me Myself' -> 'Alex Smith <alex.smith@example.com>'" })
  local result = run(s, p)
  eq(result.failed, nil)
  eq(fake.items[101].fields["System.AssignedTo"].uniqueName, "alex.smith@example.com")
end)

test("a text equal to one identity's name or email picks it, though it starts another name too", function()
  local seed2 = copy(SEED)
  table.insert(seed2.identities, { display_name = "Alex Smithson", unique_name = "alex.smithson@example.com",
    id = "u-alex-sn" })
  local s = new({ seed = seed2 })
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).assignee = "alex smith"
  item_line(v, 103).assignee = "ALEX.SMITHSON@example.com"
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq({ p.ops[1].to, p.ops[2].to }, { "alex.smith@example.com", "alex.smithson@example.com" })
end)

test("clearing the assignee column unassigns with one update", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).assignee = ""
  local p = compute(s, { v })
  eq(#p.ops, 1)
  eq({ p.ops[1].field, p.ops[1].to }, { "System.AssignedTo", "" })
  eq(texts(summary.lines(p))[3], "  #101 assignee: 'Me Myself' -> none")
  local before = calls_of(fake, "resolve_identity")
  eq(before, 0, "clearing needs no lookup")
  run(s, p)
  eq(fake.items[101].fields["System.AssignedTo"], nil)
  eq(#fake.writes, 1)
end)

test("restating the current assignee by email is no change, listed with its reason", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).assignee = "me@example.com"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(messages(p.notes), { "#101 is already assigned to Me Myself <me@example.com>" })
end)

test("the item view's assignee line edits the assignee", function()
  local s = new()
  local i = item(s, 101)
  field_line(i, "assignee").value = "alex.jones@example.com"
  local p = compute(s, { i })
  eq(p.rejections, {})
  eq({ p.ops[1].id, p.ops[1].to }, { 101, "alex.jones@example.com" })
end)

-- ── tags (R5.20) ──────────────────────────────────────────────────────────────

test("A0001-26 removing one tag and adding another is one update; the summary lists both", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).tags = "backend; urgent"
  local p = compute(s, { v })
  eq(#p.ops, 1)
  eq({ p.ops[1].kind, p.ops[1].field, p.ops[1].to }, { "update", "System.Tags", "backend; urgent" })
  eq(texts(summary.lines(p)), { "Save 1 change to Azure DevOps?", "Field changes",
    "  #101 tags: added 'urgent'; removed 'api'" })
  run(s, p)
  eq(fake.items[101].fields["System.Tags"], "backend; urgent")
end)

test("tags compare as a set: reordering, repeating or recasing them is no change", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).tags = " Backend;api ; api"
  eq(compute(s, { v }).ops, {})
end)

test("clearing the tags column removes every tag", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 101).tags = ""
  local p = compute(s, { v })
  eq(texts(summary.lines(p))[3], "  #101 tags: removed 'api', 'backend'")
  run(s, p)
  eq(fake.items[101].fields["System.Tags"], nil)
end)

test("the item view's tags line edits the tags", function()
  local s = new()
  local i = item(s, 101)
  field_line(i, "tags").value = "api"
  local p = compute(s, { i })
  eq({ p.ops[1].field, p.ops[1].to, p.ops[1].removed }, { "System.Tags", "api", { "backend" } })
end)

test("the same tags edit in two views in another order is one update", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local i = item(s, 100)
  item_line(a, 101).tags = "x; api"
  item_line(i, 101, "child").tags = "api; x"
  local p = compute(s, { a, i })
  eq(p.rejections, {})
  eq(#p.ops, 1)
  eq(p.ops[1].views, { a.key, i.key })
end)

-- ── type (R5.21, R5.22) ───────────────────────────────────────────────────────

test("A0001-28 changing a Task's type column to 'user story' is one type change, shown as one", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  item_line(v, 120).type = "user story"
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(#p.ops, 1)
  eq({ p.ops[1].kind, p.ops[1].field, p.ops[1].from, p.ops[1].to, p.ops[1].state_to },
    { "set_type", "System.WorkItemType", "Task", "User Story", nil })
  local lines = summary.lines(p)
  eq(texts(lines), { "Save 1 change to Azure DevOps?",
    "Type changes: check these, ADO drops fields the new type does not have", "  #120 type: Task -> User Story" })
  eq(lines[3].kind, "type")
  run(s, p)
  eq(fake.items[120].fields["System.WorkItemType"], "User Story")
  eq(fake.items[120].fields["System.State"], "Active")
end)

test("A0001-29 a type outside the configured set, such as Epic or Taks, is no change, listed with the reason",
  function()
    local s = new()
    local v = area(s, "P\\Team\\A")
    item_line(v, 120).type = "Epic"
    item_line(v, 101).type = "Taks"
    item_line(v, 103).type = "Issue"
    local p = compute(s, { v })
    eq(p.ops, {})
    eq(p.rejections, {})
    eq(messages(p.notes), {
      "#101 type 'Taks' is not one of the types of project P (Task, User Story, Bug), so the type stays Task",
      "#103 type 'Issue' is not one of the types of project P (Task, User Story, Bug), so the type stays Task",
      "#120 type 'Epic' is not one of the types of project P (Task, User Story, Bug), so the type stays Task",
    })
    local lines = texts(summary.lines(p))
    eq(lines[1], "Nothing to save")
    eq(lines[2], "No change")
  end)

test("A0001-30 a type change whose current state the new type lacks, with no state edit, is rejected", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.type = "User Story"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq({ p.rejections[1].id, p.rejections[1].line, p.rejections[1].rule }, { 101, row.line, "R5.22" })
  eq(p.rejections[1].message, "#101 (line " .. row.line .. ") in " .. v.key .. ": User Story has no state"
    .. " 'To Do', the state #101 is in; set the state column to one of New, Active, Resolved, Closed, Doing in"
    .. " the same save")
  eq(#fake.writes, 0)
end)

test("a type change with a state the new type has is one call setting both", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.type, row.state = "Bug", "new"
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(#p.ops, 1)
  eq({ p.ops[1].kind, p.ops[1].to, p.ops[1].state_from, p.ops[1].state_to }, { "set_type", "Bug", "To Do", "New" })
  eq(texts(summary.lines(p))[3], "  #101 type: Task -> Bug, state: To Do -> New")
  run(s, p)
  eq(#fake.writes, 1)
  eq({ fake.items[101].fields["System.WorkItemType"], fake.items[101].fields["System.State"] }, { "Bug", "New" })
end)

test("a type change with a state the new type lacks is rejected, naming the new type's states", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.type, row.state = "Bug", "Done"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R5.22")
  ok(p.rejections[1].message:find("'Done' is not a state of Bug", 1, true), p.rejections[1].message)
end)

test("a state edit with a type outside the set is checked against the current type", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 101)
  row.type, row.state = "Epic", "Doing"
  local p = compute(s, { v })
  eq(#p.ops, 1)
  eq({ p.ops[1].name, p.ops[1].to }, { "state", "Doing" })
  eq(#p.notes, 1)
end)

test("without configured types, a type change is rejected naming the row, with the setup to add", function()
  local s = new({ projects = false })
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 120)
  row.type = "bug"
  local p = compute(s, { v })
  eq(p.ops, {})
  eq(#p.rejections, 1)
  eq(p.rejections[1].rule, "R8.6")
  eq(p.rejections[1].message, "#120 (line " .. row.line .. ") in " .. v.key .. ": project P has no types"
    .. " configured, so a row cannot be created as or changed to a type in it; add them in setup(), for example"
    .. ' projects = { { name = "P", types = { ... } } }, choosing from the types P has: Task, User Story, Bug,'
    .. " Issue")
end)

test("the item view's type line edits the type, and its state line goes in the same call", function()
  local s = new()
  local i = item(s, 101)
  field_line(i, "type").value = "User Story"
  field_line(i, "state").value = "Active"
  local p = compute(s, { i })
  eq(p.rejections, {})
  eq(#p.ops, 1)
  eq({ p.ops[1].kind, p.ops[1].to, p.ops[1].state_to }, { "set_type", "User Story", "Active" })
end)

test("different type edits to one item in two views are rejected (R5.10)", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local i = item(s, 100)
  item_line(a, 101).type = "Bug"
  item_line(i, 101, "child").type = "User Story"
  local p = compute(s, { a, i })
  eq(p.ops, {})
  eq(p.rejections[1].rule, "R5.10")
  ok(p.rejections[1].message:find("#101 has conflicting type edits", 1, true), p.rejections[1].message)
end)

test("type changes run before the other field updates, and after area changes", function()
  local s = new()
  local v = area(s, "P\\Team\\A")
  local row = item_line(v, 120)
  row.type, row.title, row.tags = "Bug", "Renamed", "x"
  local p = compute(s, { v })
  eq(records.kinds(p), { "set_type", "update", "update" })
  eq({ p.ops[2].name, p.ops[3].name }, { "title", "tags" })
end)

-- ── new lines and copies ──────────────────────────────────────────────────────

test("a new line with an assignee and tags is created with both", function()
  local s, fake = new()
  local v = area(s, "P\\Team\\A")
  new_line(v, nil, { type = "", state = "", title = "Gift cards", assignee = "alex j", tags = "b; a" })
  local p = compute(s, { v })
  eq(p.rejections, {})
  eq(#p.ops, 1)
  eq({ p.ops[1].assignee, p.ops[1].tags }, { "alex.jones@example.com", "a; b" })
  eq(texts(summary.lines(p))[3], "  new Task 'Gift cards' in P\\Team\\A, no parent, assigned to Alex Jones"
    .. " <alex.jones@example.com>, tags 'a; b'")
  local result = run(s, p)
  local created = fake.items[result.created[p.ops[1]]]
  eq(created.fields["System.AssignedTo"].uniqueName, "alex.jones@example.com")
  eq(created.fields["System.Tags"], "a; b")
  eq(created.rev, 1)
end)

test("a copied row with an edited type, assignee or tags is rejected: a copy takes the original's", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local b = area(s, "P\\Team\\B")
  local pasted = paste(b, yank(a, 101))
  pasted.assignee = ""
  pasted.tags = "other"
  local p = compute(s, { a, b })
  eq(#p.rejections, 2)
  for _, r in ipairs(p.rejections) do eq(r.rule, "R5.6") end
end)

test("a moved row carries its assignee, tags and type edits", function()
  local s = new()
  local a = area(s, "P\\Team\\A")
  local b = area(s, "P\\Team\\B")
  local moved = paste(b, records.cut(a, 120))
  moved.tags = "moved"
  moved.type = "User Story"
  local p = compute(s, { a, b })
  eq(p.rejections, {})
  eq(records.kinds(p), { "set_area", "set_type", "update" })
end)
