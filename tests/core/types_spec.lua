local Fake = require("tests.support.fake_transport")
local query = require("ado.core.query")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")
local types = require("ado.core.types")
local wiql = require("ado.core.wiql")

local function ids(items)
  local out = {}
  for _, it in ipairs(items) do table.insert(out, it.id) end
  table.sort(out)
  return out
end

local function with_items(items)
  local s = {}
  for k, v in pairs(seed) do s[k] = v end
  s.items = items
  return s
end

local function new(opts, data)
  local fake = Fake.new(data or seed)
  opts = opts or {}
  opts.transport = fake
  opts.org = "test-org"
  opts.project = opts.project or "P"
  return session.new(opts), fake
end

local function ops(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do table.insert(out, c.op) end
  return out
end

test("A0002-1 my work items returns only the item in an open state", function()
  local s = new(nil, with_items({
    { id = 1, type = "User Story", title = "Active", state = "Active", area = "P\\Team", assignee = "me@example.com" },
    { id = 2, type = "User Story", title = "Resolved", state = "Resolved", area = "P\\Team", assignee = "me@example.com" },
    { id = 3, type = "Task", title = "Discarded", state = "Discarded", area = "P\\Team", assignee = "me@example.com" },
  }))
  s:my_items(function(err, items)
    eq(err, nil)
    eq(ids(items), { 1 })
  end)
end)

test("A0002-2 a state open for one type and finished for another", function()
  -- Resolved is InProgress for Bug and Resolved for User Story in the seed.
  local s = new(nil, with_items({
    { id = 1, type = "Bug", title = "a", state = "Resolved", area = "P\\Team", assignee = "me@example.com" },
    { id = 2, type = "User Story", title = "b", state = "Resolved", area = "P\\Team", assignee = "me@example.com" },
  }))
  s:my_items(function(_, items) eq(ids(items), { 1 }) end)
  s:catalog("P", function(_, catalog)
    eq(catalog:is_open("Bug", "Resolved"), true)
    eq(catalog:is_open("User Story", "Resolved"), false)
  end)
end)

test("A0002-3 text search returns open items by default and every match with all_states", function()
  local s = new(nil, with_items({
    { id = 1, type = "Task", title = "Login open", state = "Doing", area = "P\\Team" },
    { id = 2, type = "Task", title = "Login done", state = "Done", area = "P\\Team" },
    { id = 3, type = "Task", title = "Login discarded", state = "Discarded", area = "P\\Team" },
    { id = 4, type = "Task", title = "Other", state = "To Do", area = "P\\Team" },
  }))
  s:search("login", nil, function(_, items) eq(ids(items), { 1 }) end)
  s:search("login", { all_states = true }, function(_, items) eq(ids(items), { 1, 2, 3 }) end)
end)

test("my work items on the seed: open items only, across types", function()
  local s = new()
  s:my_items(function(_, items) eq(ids(items), { 100, 101, 103, 112 }) end)
end)

test("the catalog loads once per session; later uses make 0 calls", function()
  local s, fake = new()
  local events = {}
  s.on_event = function(e) table.insert(events, e) end
  s:my_items(function() end)
  s:search("login", nil, function() end)
  s:states("Bug", nil, function() end)
  eq(ops(fake), { "work_item_types", "query", "query" })
  eq(events, { { kind = "catalog_loaded", project = "P", types = #seed.types, calls = 1, fallback = {} } })
end)

test("callers during an in-flight load share it", function()
  local s, fake = new()
  fake.mode = "deferred"
  local got = 0
  async(fake, function(done)
    s:catalog("P", function(err) eq(err, nil) got = got + 1 end)
    s:catalog("P", function(err) eq(err, nil) got = got + 1 done() end)
  end)
  eq(got, 2)
  eq(ops(fake), { "work_item_types" })
end)

test("a failed load is reported and retried on the next use", function()
  local s, fake = new()
  fake:fail_on("work_item_types", 1, { kind = "auth", message = "expired" })
  s:my_items(function(err) eq(err, { kind = "auth", message = "expired" }) end)
  s:my_items(function(err, items) eq(err, nil) eq(#items, 4) end)
  eq(ops(fake), { "work_item_types", "work_item_types", "query" })
end)

test("changing project loads the new project's catalog once and keeps the old one", function()
  local s, fake = new()
  s:my_items(function() end)
  s:set_project("Q")
  s:my_items(function() end)
  s:set_project("P")
  s:my_items(function() end)
  eq(ops(fake), { "work_item_types", "query", "work_item_types", "query", "query" })
  eq(fake.calls[3].params, { project = "Q" })
end)

test("without a project the catalog load is invalid and makes 0 calls", function()
  local fake = Fake.new(seed)
  local s = session.new({ transport = fake, org = "o" })
  s:catalog(nil, function(err) eq(err.kind, "invalid") end)
  s:my_items(function(err) eq(err.kind, "invalid") end)
  eq(#fake.calls, 0)
end)

test("per-type fallback when the type list has no categories", function()
  local s, fake = new()
  fake.types_omit_categories = true
  local events = {}
  s.on_event = function(e) table.insert(events, e) end
  s:my_items(function(_, items) eq(ids(items), { 100, 101, 103, 112 }) end)
  local expected = { "work_item_types" }
  for _ = 1, #seed.types do table.insert(expected, "work_item_type_states") end
  table.insert(expected, "query")
  eq(ops(fake), expected)
  eq(fake.calls[2].params, { type = "Task", project = "P" })
  eq(events[1].calls, 1 + #seed.types)
  eq(events[1].fallback, { "Task", "User Story", "Bug", "Issue" })
end)

test("a fallback state still without a category fails the load", function()
  local catalog_err
  types.load({
    work_item_types = function(_, cb) cb(nil, { { name = "T", states = { { name = "A" } } } }) end,
    work_item_type_states = function(_, cb) cb(nil, { { name = "A" } }) end,
  }, "P", nil, function(err) catalog_err = err end)
  eq(catalog_err.kind, "failed")
  ok(catalog_err.message:find("state 'A' of type T has no state category", 1, true), catalog_err.message)
end)

test("configured open_categories change what counts as open", function()
  local s = new({ open_categories = { "Proposed" } })
  s:my_items(function(_, items) eq(ids(items), { 101, 103 }) end)
  local c = types.new(seed.types, { "resolved", "Completed" })
  eq(c:is_open("User Story", "Resolved"), true)
  eq(c:is_open("Task", "Done"), true)
  eq(c:is_open("Task", "To Do"), false)
end)

test("is_open and states ignore case; unknown types are not open", function()
  local c = types.new(seed.types)
  eq(c:is_open("task", "to do"), true)
  eq(c:is_open("Epic", "New"), false)
  eq(c:states("bug"), { "New", "Active", "Resolved", "Closed" })
  eq(c:states("Epic"), nil)
  eq(c:names(), { "Task", "User Story", "Bug", "Issue" })
end)

test("open condition renders per type, in catalog order", function()
  local c = types.new(seed.types)
  eq(wiql.render({ select = { "System.Id" }, where = c:open_condition() }),
    "SELECT [System.Id] FROM WorkItems WHERE"
    .. " ([System.WorkItemType] = 'Task' AND [System.State] IN ('To Do', 'Doing'))"
    .. " OR ([System.WorkItemType] = 'User Story' AND [System.State] IN ('New', 'Active'))"
    .. " OR ([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active', 'Resolved'))"
    .. " OR ([System.WorkItemType] = 'Issue' AND [System.State] IN ('To Do'))")
end)

test("open condition restricted to a type list", function()
  local c = types.new(seed.types)
  eq(wiql.render({ select = { "System.Id" }, where = c:open_condition({ "bug", "Epic" }) }),
    "SELECT [System.Id] FROM WorkItems WHERE"
    .. " ([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active', 'Resolved'))")
end)

test("open condition with no open state matches nothing", function()
  local c = types.new({ { name = "T", states = { { name = "Done", category = "Completed" } } } })
  local s = new()
  s.transport.query(query.request({ select = { "System.Id" }, where = c:open_condition() }),
    function(_, items) eq(items, {}) end)
end)

test("state and type names with quotes are escaped", function()
  local c = types.new({ { name = "Dev's task", states = {
    { name = "Won't do", category = "Proposed" }, { name = "Done", category = "Completed" } } } })
  eq(wiql.render({ select = { "System.Id" }, where = c:open_condition() }),
    "SELECT [System.Id] FROM WorkItems WHERE"
    .. " ([System.WorkItemType] = 'Dev''s task' AND [System.State] IN ('Won''t do'))")
end)

-- Assumption 6 in the plan: ADO caps WIQL at 32,000 characters; the az
-- transport warns from 16,000.
test("open condition length for the seed stays far below the WIQL limit", function()
  local w = wiql.render(query.my_items(types.new(seed.types):open_condition()))
  ok(#w < 1000, "my items WIQL is " .. #w .. " characters")
end)

test("types with the same open states share one clause", function()
  local c = types.new({
    { name = "Task", states = { { name = "New", category = "Proposed" }, { name = "Done", category = "Completed" } } },
    { name = "Bug", states = { { name = "New", category = "Proposed" }, { name = "Closed", category = "Completed" } } },
    { name = "Epic", states = { { name = "New", category = "Proposed" }, { name = "Active", category = "InProgress" } } },
  })
  eq(wiql.render({ select = { "System.Id" }, where = c:open_condition() }),
    "SELECT [System.Id] FROM WorkItems WHERE"
    .. " ([System.WorkItemType] IN ('Task', 'Bug') AND [System.State] IN ('New'))"
    .. " OR ([System.WorkItemType] = 'Epic' AND [System.State] IN ('New', 'Active'))")
  local s = new(nil, with_items({
    { id = 1, type = "Bug", title = "a", state = "New", area = "P\\Team", assignee = "me@example.com" },
    { id = 2, type = "Bug", title = "b", state = "Active", area = "P\\Team", assignee = "me@example.com" },
  }))
  s.transport.query(query.request({ select = { "System.Id" }, where = c:open_condition() }),
    function(_, items) eq(#items, 1) eq(items[1].id, 1) end)
end)
