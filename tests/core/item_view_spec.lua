local Fake = require("tests.support.fake_transport")
local area_view = require("ado.core.area_view")
local history = require("ado.core.history")
local item_view = require("ado.core.item_view")
local location = require("ado.core.location")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")

-- Most specs check the sections, so they read rows without the viewed
-- item's field lines and the closing Details row; those have their own
-- specs.
local all_rows = item_view.rows
item_view = setmetatable({ rows = function(d)
  local out = {}
  for _, r in ipairs(all_rows(d)) do
    if r.kind ~= "field" and r.slot ~= "boundary" then table.insert(out, r) end
  end
  return out
end }, { __index = item_view })

local function with(overrides)
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  for k, v in pairs(overrides) do d[k] = v end
  return d
end

-- Story 20 has a finished parent 10, three children (22 finished), Related
-- links to an open and a finished Bug and to an item that does not exist.
-- Child 21 has an open and a finished child.
local TREE = with({
  areas = { "P\\Team", "P\\Team\\A" },
  items = {
    { id = 10, type = "User Story", title = "Parent", state = "Closed", area = "P\\Team" },
    { id = 20, type = "User Story", title = "N", state = "Active", area = "P\\Team\\A", parent = 10,
      related = { 31, 30, 999 } },
    { id = 21, type = "Task", title = "Child open", state = "To Do", area = "P\\Team\\A", parent = 20 },
    { id = 22, type = "Task", title = "Child done", state = "Done", area = "P\\Team\\A", parent = 20 },
    { id = 23, type = "Task", title = "Child doing", state = "Doing", area = "P\\Team\\A", parent = 20 },
    { id = 24, type = "Task", title = "Grandchild open", state = "To Do", area = "P\\Team\\A", parent = 21 },
    { id = 25, type = "Task", title = "Grandchild done", state = "Done", area = "P\\Team\\A", parent = 21 },
    { id = 30, type = "Bug", title = "Related open", state = "Active", area = "P\\Team" },
    { id = 31, type = "Bug", title = "Related closed", state = "Closed", area = "P\\Team" },
  },
})

local function new(data, opts)
  local fake = Fake.new(data or TREE)
  opts = opts or {}
  opts.transport = fake
  opts.org = "test-org"
  opts.project = "P"
  return session.new(opts), fake
end

local function load(s, loc, opts)
  local view, err
  item_view.load(s, loc, opts, function(e, v) err, view = e, v end)
  return view, err
end

local function ops(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do table.insert(out, c.op) end
  return out
end

-- "slot:id" for item rows, "slot" for the others.
local function shape(rows)
  local out = {}
  for _, r in ipairs(rows) do
    table.insert(out, r.kind == "item" and (r.slot .. ":" .. r.id) or (r.kind == "area" and "area" or r.slot))
  end
  return out
end

local function expand(s, d, rows, id)
  for _, r in ipairs(rows) do
    if r.kind == "item" and r.id == id and r.slot == "child" then
      local out, err
      item_view.expand(s, d, r, function(e, x) err, out = e, x end)
      return out, err
    end
  end
  error("no child row " .. id)
end

test("R3.1 the rows are the item, its parent, its area, its children, then each link section", function()
  local view = load(new(), location.item(20))
  local rows = item_view.rows(item_view.display(view))
  eq(shape(rows), { "self:20", "parent:10", "area", "children", "child:21", "child:23", "link", "link:30" })
  eq(rows[1], { kind = "item", slot = "self", depth = 0, id = 20, rev = 1, type = "User Story", state = "Active",
    assignee = "", assignee_unique = "", tags = "", title = "N", project = "P", area = "P\\Team\\A", parent = 10 })
  eq(rows[3], { kind = "area", slot = "area", path = "P\\Team\\A", name = "P\\Team\\A" })
  eq(rows[4].label, "Children: 2 open of 3")
  eq(rows[7], { kind = "heading", slot = "link", rel = "System.LinkTypes.Related",
    label = "Related: 1 open of 2, 1 not readable" })
  eq(rows[8].rel, "System.LinkTypes.Related")
end)

test("A0001-4 selecting an item in an area view gives its item location; back returns to the area location", function()
  local s = new()
  local area = location.area("P\\Team\\A", { types = { "Task" }, state = "all" })
  local h = history.new()
  h:visit(area)
  local av
  area_view.load(s, area, nil, function(_, v) av = v end)
  local loc = area_view.select(av, av.rows[1])
  eq(loc, location.item(av.rows[1].id))
  h:visit(loc)
  local back = h:back()
  ok(location.equal(back, area))
  eq(back.filters, { state = "all", types = { "Task" } })
end)

test("A0001-5 selecting the area row gives the area location of N's area path, with default filters", function()
  local view = load(new(), location.item(20, true))
  local d = item_view.display(view)
  local rows = item_view.rows(d)
  local loc = item_view.select(d, rows[3], { state = "open", assignee = "@Me" })
  eq(loc, location.area("P\\Team\\A", { state = "open", assignee = "@Me" }))
  eq(item_view.select(d, rows[3]), location.area("P\\Team\\A"))
end)

test("selecting the parent, a child or a link gives that item's location, carrying the toggle", function()
  local view = load(new(), location.item(20, true))
  local d = item_view.display(view)
  local rows = item_view.rows(d)
  eq(item_view.select(d, rows[2]), location.item(10, true))
  eq(item_view.select(d, rows[5]), location.item(21, true))
  eq(item_view.select(d, rows[1]), nil, "the item's own row")
  eq(item_view.select(d, rows[4]), nil, "a heading")
end)

test("R3.8 the parent row shows whatever its state", function()
  local view = load(new(), location.item(20))
  local rows = item_view.rows(item_view.display(view))
  eq({ rows[2].slot, rows[2].id, rows[2].state }, { "parent", 10, "Closed" })
end)

test("R3.8 children and links are open only by default; the toggle shows all with no call", function()
  local s, fake = new()
  local loc = location.item(20)
  local view = load(s, loc)
  local calls = #fake.calls
  local rows = item_view.rows(item_view.display(view, location.with_all(loc, true)))
  eq(shape(rows), { "self:20", "parent:10", "area", "children", "child:21", "child:22", "child:23",
    "link", "link:30", "link:31" })
  eq(rows[4].label, "Children: 3")
  eq(rows[8].label, "Related: 2, 1 not readable")
  eq(#fake.calls, calls)
end)

test("a load costs get_work_item with relations and one query, plus the catalog once", function()
  local s, fake = new()
  load(s, location.item(20))
  load(s, location.item(21))
  eq(ops(fake), { "get_work_item", "query", "work_item_types", "get_work_item", "query" })
  eq(fake.calls[1].params, { id = 20, relations = true })
  eq(fake.calls[2].params.wiql, "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType],"
    .. " [System.AssignedTo], [System.Tags], [System.AreaPath], [System.TeamProject], [System.ChangedDate],"
    .. " [System.Parent] FROM WorkItems WHERE [System.Id] IN (10, 21, 22, 23, 31, 30, 999) ORDER BY [System.Id]")
end)

test("an item with no links costs no query", function()
  local s, fake = new()
  local view = load(s, location.item(30))
  eq(ops(fake), { "get_work_item", "work_item_types" })
  eq(shape(item_view.rows(item_view.display(view))), { "self:30", "parent", "area", "children" })
  eq(item_view.rows(item_view.display(view))[2].label, "Parent: none")
  eq(item_view.rows(item_view.display(view))[4].label, "Children: none")
end)

test("link types limited to link_types: the Related section and its query IDs are left out", function()
  local s, fake = new()
  local view = load(s, location.item(20), { link_types = { item_view.HIERARCHY } })
  eq(shape(item_view.rows(item_view.display(view))), { "self:20", "parent:10", "area", "children",
    "child:21", "child:23" })
  eq(fake.calls[2].params.spec.where.value, { 10, 21, 22, 23 })
end)

test("R3.4 expansion makes exactly 1 call and inserts the open children beneath; collapse makes none", function()
  local s, fake = new()
  local view = load(s, location.item(20))
  local d = item_view.display(view)
  local calls = #fake.calls
  local below = expand(s, d, item_view.rows(d), 21)
  eq(#fake.calls, calls + 1)
  eq(fake.calls[#fake.calls].params.wiql:match("WHERE .*$"), "WHERE [System.Parent] = 21 ORDER BY [System.Id]")
  eq(shape(below), { "child:24" })
  eq({ below[1].depth, below[1].block_parent }, { 1, 21 })
  eq(shape(item_view.rows(d)), { "self:20", "parent:10", "area", "children", "child:21", "child:24", "child:23",
    "link", "link:30" })
  item_view.collapse(d, 21)
  eq(#fake.calls, calls + 1)
  eq(shape(item_view.rows(d)), { "self:20", "parent:10", "area", "children", "child:21", "child:23",
    "link", "link:30" })
end)

test("an expanded row follows the toggle, and collapsing it collapses the rows beneath", function()
  local s = new()
  local loc = location.item(20, true)
  local d = item_view.display(load(s, loc))
  expand(s, d, item_view.rows(d), 21)
  local rows = item_view.rows(d)
  eq(shape(rows), { "self:20", "parent:10", "area", "children", "child:21", "child:24", "child:25", "child:22",
    "child:23", "link", "link:30", "link:31" })
  expand(s, d, rows, 24)
  ok(d.expanded[24], "24 is expanded, with no children")
  item_view.collapse(d, 21)
  eq(d.expanded, {})
end)

test("only child rows expand", function()
  local s, fake = new()
  local d = item_view.display(load(s, location.item(20)))
  local calls = #fake.calls
  local err
  item_view.expand(s, d, item_view.rows(d)[2], function(e) err = e end)
  eq(err.kind, "invalid")
  eq(#fake.calls, calls)
end)

test("a location going back is collapsed", function()
  local s = new()
  local h = history.new()
  local loc = location.item(20)
  h:visit(loc)
  local view = load(s, loc)
  local d = item_view.display(view, h:current())
  expand(s, d, item_view.rows(d), 21)
  h:visit(item_view.select(d, item_view.rows(d)[5]))
  eq(h:current(), location.item(21))
  local again = item_view.display(view, h:back())
  eq(shape(item_view.rows(again)), { "self:20", "parent:10", "area", "children", "child:21", "child:23",
    "link", "link:30" })
end)

test("the load works with deferred callbacks and reports its two steps", function()
  local s, fake = new()
  fake.mode = "deferred"
  local steps, view = {}, nil
  item_view.load(s, location.item(20), {
    on_progress = function(done, total, what) table.insert(steps, { done, total, what }) end,
  }, function(_, v) view = v end)
  fake:flush()
  ok(view, "the view loaded")
  eq(steps, { { 1, 2, "item" }, { 2, 2, "links" } })
end)

test("a failed read fails the load once with the transport's error", function()
  local s, fake = new()
  fake:fail_on("get_work_item", 1, { kind = "not_found", message = "no such item" })
  local calls = 0
  item_view.load(s, location.item(20), nil, function(err, view)
    calls = calls + 1
    eq(err, { kind = "not_found", message = "no such item" })
    eq(view, nil)
  end)
  eq(calls, 1)
end)

test("a linked item in another project is judged by that project's catalog", function()
  local data = with({
    projects = { "P", "Q" },
    areas = { "P\\Team", "Q\\Ops" },
    project_types = { Q = { { name = "Bug", states = {
      { name = "Closed", category = "InProgress" } } } } },
    items = {
      { id = 1, type = "Task", title = "N", state = "To Do", area = "P\\Team", related = { 2 } },
      { id = 2, project = "Q", type = "Bug", title = "Q bug", state = "Closed", area = "Q\\Ops" },
    },
  })
  local s, fake = new(data)
  local view = load(s, location.item(1))
  eq(shape(item_view.rows(item_view.display(view))), { "self:1", "parent", "area", "children", "link", "link:2" })
  eq(ops(fake), { "get_work_item", "query", "work_item_types", "work_item_types" })
end)

test("the viewed item's ID, type, state, assignee and tags follow its row, one line each, the ID first", function()
  local view = load(new(), location.item(20))
  local rows = all_rows(item_view.display(view))
  eq(rows[1].slot, "self")
  local fields = {}
  for i = 2, 6 do
    eq(rows[i].kind, "field")
    eq(rows[i].id, 20)
    fields[i - 1] = rows[i].field .. "=" .. rows[i].value
  end
  eq(fields, { "id=20", "type=User Story", "state=Active", "assignee=" .. (rows[1].assignee or ""),
    "tags=" .. (rows[1].tags or "") })
  eq(rows[7].slot, "parent")
  eq(item_view.select(item_view.display(view), rows[2]), nil, "a field line")
end)

test("C7.4 the rows end with the Details boundary row, a heading after the last link section", function()
  local s = new()
  local view = load(s, location.item(20))
  local rows = all_rows(item_view.display(view))
  local last = rows[#rows]
  eq({ last.kind, last.slot, last.label }, { "heading", "boundary", "Details" })
  eq(rows[#rows - 1].slot, "link", "the last link row comes just before it")
end)
