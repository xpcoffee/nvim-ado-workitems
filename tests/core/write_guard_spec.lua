local Fake = require("tests.support.fake_transport")
local seed = require("tests.fixtures.seed")
local write_guard = require("ado.core.write_guard")
local requests = require("ado.core.requests")

local function url(id)
  return "https://dev.azure.com/test-org/_apis/wit/workItems/" .. id
end

-- A create's params for title, area and an optional parent.
local function create(wtype, title, area, parent)
  return { project = "P", type = wtype,
    patch = requests.create_patch({ title = title, area = area, parent = parent }, "test-org") }
end

local function patch(id, ...)
  return { id = id, patch = { { op = "test", path = "/rev", value = 1 }, ... } }
end

local function set(ref, value)
  return { op = "add", path = "/fields/" .. ref, value = value }
end

-- A patch that sets fields without testing /rev, for checks that write to
-- one item more than once.
local function edit(id, fields)
  local p = {}
  for ref, value in pairs(fields) do table.insert(p, set(ref, value)) end
  table.sort(p, function(a, b) return a.path < b.path end)
  return { id = id, patch = p }
end

local function link(target, rel)
  return { op = "add", path = "/relations/-", value = { rel = rel or "System.LinkTypes.Related", url = url(target) } }
end

-- Seed areas: 101 and 111 (an Issue) are in P\Team\A; 104 is in P\Team\B.
local function guarded(opts)
  local fake = Fake.new(seed)
  local created = {}
  fake.create_work_item = function(params, cb)
    table.insert(created, params)
    cb(nil, { id = 900, rev = 1, fields = {} })
  end
  local g = write_guard.wrap(fake, opts or { area = "P\\Team\\A" })
  return g, fake, created
end

local function ops(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do table.insert(out, c.op) end
  return out
end

local function result_of(g, op, params)
  local err, result
  g[op](params, function(e, r) err, result = e, r end)
  return err, result
end

test("reads pass through unchanged", function()
  local g, fake = guarded()
  local _, raw = result_of(g, "get_work_item", { id = 104 })
  eq(raw.id, 104)
  local _, names = result_of(g, "list_projects", {})
  eq(names, { "P" })
  eq(ops(fake), { "get_work_item", "list_projects" })
end)

test("C7.1 list_comments is a read: it passes through unchanged, also on an Issue outside the area", function()
  local g, fake = guarded()
  local err, page = result_of(g, "list_comments", { id = 111, project = "P", top = 5 })
  eq(err, nil)
  eq(page.comments, {})
  err = result_of(g, "list_comments", { id = 104, project = "P", top = 5 })
  eq(err, nil)
  eq(ops(fake), { "list_comments", "list_comments" })
  eq(#fake.writes, 0)
end)

test("a write inside the area reaches the transport", function()
  local g, fake = guarded()
  local err, raw = result_of(g, "patch_work_item", edit(101, { ["System.Title"] = "x" }))
  eq(err, nil)
  eq(raw.rev, 2)
  eq(ops(fake), { "get_work_item", "patch_work_item" })
end)

test("a write outside the area is refused with zero writes", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", edit(104, { ["System.Title"] = "x" }))
  eq(err.kind, "invalid")
  ok(err.message:find("#104 is in area 'P\\Team\\B', outside 'P\\Team\\A'", 1, true), err.message)
  eq(#fake.writes, 0)
  eq(ops(fake), { "get_work_item" }, "only the guard's own read")
end)

test("a write to an Issue is refused with zero writes", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", edit(111, { ["System.Title"] = "x" }))
  ok(err.message:find("#111 is of type Issue", 1, true), err.message)
  err = result_of(g, "add_comment", { id = 111, text = "hi" })
  ok(err.message:find("#111 is of type Issue", 1, true), err.message)
  eq(#fake.writes, 0)
end)

test("changing a type to Issue is refused with zero transport calls", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", edit(101, { ["System.WorkItemType"] = "issue" }))
  ok(err.message:find("changing a type to issue", 1, true), err.message)
  eq(#fake.calls, 0)
end)

test("changing the type of an Issue is refused with zero writes", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", edit(111, { ["System.WorkItemType"] = "Task" }))
  ok(err.message:find("#111 is of type Issue", 1, true), err.message)
  eq(#fake.writes, 0)
end)

test("a type change between allowed types inside the area reaches the transport", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", edit(101, { ["System.WorkItemType"] = "User Story", ["System.State"] = "New" }))
  eq(err, nil)
  eq(ops(fake), { "get_work_item", "patch_work_item" })
end)

test("assignee and tag updates get the same checks as any other field", function()
  local g, fake = guarded({ area = "P\\Team\\A", title_prefix = "Write" })
  for _, fields in ipairs({ { ["System.AssignedTo"] = "me@example.com" }, { ["System.AssignedTo"] = "" },
    { ["System.Tags"] = "a; b" } }) do
    eq(result_of(g, "patch_work_item", edit(101, fields)), nil)
    ok(result_of(g, "patch_work_item", edit(104, fields)).message:find("outside", 1, true))
    ok(result_of(g, "patch_work_item", edit(111, fields)).message:find("of type Issue", 1, true))
    ok(result_of(g, "patch_work_item", edit(102, fields)).message:find("does not start with", 1, true))
  end
  eq(#fake.writes, 3, "only the three updates to #101")
end)

test("moving an item out of the area is refused with zero transport calls", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", edit(101, { ["System.AreaPath"] = "P\\Team\\B" }))
  ok(err.message:find("new area 'P\\Team\\B' is outside", 1, true), err.message)
  eq(#fake.calls, 0)
end)

test("sub-areas are allowed; a sibling sharing the prefix is not", function()
  local g, fake = guarded({ area = "P/Team" })
  eq(result_of(g, "patch_work_item", edit(104, { ["System.Title"] = "x" })), nil)
  fake:edit_remotely(101, { ["System.AreaPath"] = "P\\TeamX" })
  local err = result_of(g, "patch_work_item", edit(101, { ["System.Title"] = "x" }))
  eq(err.kind, "invalid")
  eq(#fake.writes, 1)
end)

test("creates need an allowed area and a type other than Issue, checked without calls", function()
  local g, fake, created = guarded()
  local err = result_of(g, "create_work_item", create("Issue", "t", "P\\Team\\A"))
  ok(err.message:find("type Issue", 1, true), err.message)
  err = result_of(g, "create_work_item", create("Task", "t", "P\\Team\\B"))
  ok(err.message:find("area 'P\\Team\\B' is outside", 1, true), err.message)
  err = result_of(g, "create_work_item", { project = "P", type = "Task", patch = { set("System.Title", "t") } })
  ok(err.message:find("area 'nil' is outside", 1, true), err.message)
  err = result_of(g, "create_work_item", { project = "P", type = "Task", patch = {} })
  ok(err.message:find("the patch is empty", 1, true), err.message)
  eq(#created, 0)
  eq(#fake.calls, 0)
  eq(result_of(g, "create_work_item", create("Task", "t", "P\\Team\\A\\New")), nil)
  eq(#created, 1)
end)

test("a create's parent is checked like any other item it writes", function()
  local g, fake, created = guarded()
  local err = result_of(g, "create_work_item", create("Task", "t", "P\\Team\\A", 104))
  ok(err.message:find("#104 is in area 'P\\Team\\B'", 1, true), err.message)
  err = result_of(g, "create_work_item", create("Task", "t", "P\\Team\\A", 111))
  ok(err.message:find("#111 is of type Issue", 1, true), err.message)
  eq(#created, 0)
  eq(result_of(g, "create_work_item", create("Task", "t", "P\\Team\\A", 100)), nil)
  eq(#created, 1)
  eq(ops(fake), { "get_work_item", "get_work_item", "get_work_item" })
end)

test("a create cannot test, remove, or set its type in a field", function()
  local g, _, created = guarded()
  for _, extra in ipairs({ { op = "test", path = "/rev", value = 1 }, { op = "remove", path = "/relations/0" },
    set("System.WorkItemType", "Task") }) do
    local params = create("Task", "t", "P\\Team\\A")
    table.insert(params.patch, extra)
    ok(result_of(g, "create_work_item", params).message:find("write guard refused create_work_item", 1, true))
  end
  eq(#created, 0)
end)

test("a link added in a patch checks both ends", function()
  local g, fake = guarded()
  local err = result_of(g, "patch_work_item", patch(101, link(104)))
  ok(err and err.message:find("#104", 1, true), err and err.message)
  eq(ops(fake), { "get_work_item", "get_work_item" })
  eq(#fake.writes, 0)
end)

test("a link removed by index checks the item at that index, read from the item's relations", function()
  local g, fake = guarded()
  -- Relation 0 of 101 is its parent link to 100, moved out of the area here.
  fake:edit_remotely(100, { ["System.AreaPath"] = "P\\Team\\B" })
  local err = result_of(g, "patch_work_item", patch(101, { op = "remove", path = "/relations/0" }))
  ok(err and err.message:find("#100 is in area 'P\\Team\\B'", 1, true), err and err.message)
  err = result_of(g, "patch_work_item", patch(101, { op = "remove", path = "/relations/7" }))
  ok(err.message:find("relation 7 of #101 is not a link to a work item", 1, true), err.message)
  eq(#fake.writes, 0)
  eq(fake.calls[1].params.relations, true, "the guard reads the item's relations")
end)

test("every field in a patch is checked: type, title and area, and a field with no rule is refused", function()
  local g, fake = guarded({ area = "P\\Team\\A", title_prefix = "Write" })
  local cases = {
    { set("System.State", "Doing"), set("System.WorkItemType", "Issue"), "changing a type to Issue" },
    { set("System.Title", "Other"), "the new title does not start with 'Write'" },
    { set("System.AreaPath", "P\\Team\\B"), "new area 'P\\Team\\B' is outside" },
    { set("System.Reason", "x"), "no rule for field System.Reason" },
    { { op = "move", path = "/fields/System.Title", from = "/x" }, "no rule for 'move /fields/System.Title'" },
    { { op = "test", path = "/fields/System.Title", value = "x" }, "no rule for 'test /fields/System.Title'" },
    { { op = "add", path = "/relations/-", value = { rel = "Hyperlink", url = "https://example.com" } },
      "a relation added must link to a work item" },
  }
  for _, c in ipairs(cases) do
    local expected = table.remove(c)
    local err = result_of(g, "patch_work_item", patch(101, unpack(c)))
    ok(err and err.message:find(expected, 1, true), (err and err.message or "nil") .. " for " .. expected)
  end
  eq(#fake.calls, 0, "all refused from the patch alone")
  local err = result_of(g, "patch_work_item", patch(101, set("System.Title", "Write the API"),
    set("System.State", "Doing"), { op = "test", path = "/relations/0/url", value = url(100) },
    { op = "remove", path = "/relations/0" }))
  ok(err and err.message:find("#100's title does not start with 'Write'", 1, true), err and err.message)
  fake:edit_remotely(100, { ["System.Title"] = "Write the story" })
  eq(result_of(g, "patch_work_item", patch(101, set("System.Title", "Write the API"),
    { op = "test", path = "/relations/0/url", value = url(100) }, { op = "remove", path = "/relations/0" })), nil)
  eq(#fake.writes, 1)
end)

test("with title_prefix, only items titled with it are written, and creates and retitles keep it", function()
  local fake = Fake.new(seed)
  local reached = {}
  fake.create_work_item = function(_, cb) table.insert(reached, "create") cb(nil, { id = 900, rev = 1, fields = {} }) end
  fake:edit_remotely(101, { ["System.Title"] = "[test] Write API" })
  local g = write_guard.wrap(fake, { area = "P\\Team\\A", title_prefix = "[test] " })
  eq(result_of(g, "patch_work_item", edit(101, { ["System.State"] = "Doing" })), nil)
  local err = result_of(g, "patch_work_item", edit(102, { ["System.State"] = "Done" }))
  ok(err.message:find("#102's title does not start with '[test] '", 1, true), err.message)
  err = result_of(g, "patch_work_item", edit(101, { ["System.Title"] = "Write API" }))
  ok(err.message:find("the new title does not start with", 1, true), err.message)
  err = result_of(g, "patch_work_item", patch(101, link(102)))
  ok(err.message:find("#102's title", 1, true), err.message)
  err = result_of(g, "create_work_item", create("Task", "Untitled", "P\\Team\\A"))
  ok(err.message:find("the title does not start with", 1, true), err.message)
  eq(result_of(g, "create_work_item", create("Task", "[test] New", "P\\Team\\A")), nil)
  eq(#fake.writes, 1)
  eq(reached, { "create" })
end)

test("an operation the guard has no rule for is refused", function()
  local g = write_guard.wrap({ delete_everything = function() error("must not run") end }, { area = "P" })
  local err = result_of(g, "delete_everything", {})
  ok(err.message:find("no rule for this operation", 1, true))
end)

test("with no area configured every write is refused", function()
  local g, fake = guarded({})
  local err = result_of(g, "patch_work_item", edit(101, { ["System.Title"] = "x" }))
  ok(err.message:find("no allowed area", 1, true))
  eq(#fake.calls, 0)
end)

test("a failed read refuses the write", function()
  local g, fake = guarded()
  fake:fail_on("get_work_item", 1, { kind = "auth", message = "expired" })
  local err = result_of(g, "patch_work_item", edit(101, { ["System.Title"] = "x" }))
  ok(err.message:find("could not read #101: expired", 1, true), err.message)
  eq(#fake.writes, 0)
end)

test("works with deferred callbacks", function()
  local g, fake = guarded()
  fake.mode = "deferred"
  async(fake, function(done)
    g.patch_work_item(edit(104, { ["System.Title"] = "x" }), function(err)
      eq(err.kind, "invalid")
      done()
    end)
  end)
  eq(#fake.writes, 0)
end)

-- Adding an operation to the transport without deciding how the guard treats
-- it would leave it refused for every caller.
test("every transport operation is either a read or has a write check", function()
  local transport = require("ado.core.transport")
  local all = {}
  for _, op in ipairs(transport.OPERATIONS) do all[op] = true end
  for op in pairs(transport.WRITES) do all[op] = true end
  local stub = {}
  for op in pairs(all) do
    stub[op] = function(_, cb)
      cb(nil, { id = 1, rev = 1, fields = { ["System.AreaPath"] = "P\\A", ["System.WorkItemType"] = "Task" } })
    end
  end
  local g = write_guard.wrap(stub, { area = "P\\A" })
  local unruled = {}
  for op in pairs(all) do
    local err = result_of(g, op, { id = 1, type = "Task",
      patch = { { op = "add", path = "/fields/System.Title", value = "t" },
        { op = "add", path = "/fields/System.AreaPath", value = "P\\A" } } })
    if err and err.message:find("has no rule", 1, true) then table.insert(unruled, op) end
  end
  table.sort(unruled)
  eq(unruled, {})
end)
