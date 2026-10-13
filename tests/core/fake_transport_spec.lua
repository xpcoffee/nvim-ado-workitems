local Fake = require("tests.support.fake_transport")
local query = require("ado.core.query")
local seed = require("tests.fixtures.seed")

local function ids(items)
  local out = {}
  for _, it in ipairs(items) do table.insert(out, it.id) end
  return out
end

test("calls are recorded in order and writes separately", function()
  local fake = Fake.new(seed)
  fake.get_work_item({ id = 101 }, function() end)
  fake.patch_work_item({ id = 101, patch = { { op = "add", path = "/fields/System.Title", value = "New" } } }, function() end)
  fake.list_projects({}, function() end)
  eq(#fake.calls, 3)
  eq(fake.calls[1].op, "get_work_item")
  eq(fake.calls[2], { op = "patch_work_item", params = { id = 101, patch = { { op = "add", path = "/fields/System.Title", value = "New" } } } })
  eq(#fake.writes, 1)
  eq(fake.writes[1].op, "patch_work_item")
end)

test("a write bumps rev and returns the updated raw item", function()
  local fake = Fake.new(seed)
  local result
  fake.patch_work_item({ id = 103, patch = { { op = "add", path = "/fields/System.State", value = "Doing" } } },
    function(err, raw)
      eq(err, nil)
      result = raw
    end)
  eq(result.rev, 2)
  eq(result.fields["System.State"], "Doing")
end)

test("fail_on fails only the n-th call of that operation", function()
  local fake = Fake.new(seed)
  fake:fail_on("get_work_item", 2, { kind = "auth", message = "expired" })
  local errs = {}
  for _ = 1, 3 do
    fake.get_work_item({ id = 100 }, function(err) table.insert(errs, err or false) end)
  end
  eq(errs, { false, { kind = "auth", message = "expired" }, false })
  ok(fake.calls[2].failed)
end)

test("a failed write is recorded but not applied", function()
  local fake = Fake.new(seed)
  fake:fail_on("patch_work_item", 1)
  fake.patch_work_item({ id = 101, patch = { { op = "add", path = "/fields/System.Title", value = "X" } } }, function(err)
    eq(err.kind, "failed")
  end)
  eq(fake.items[101].fields["System.Title"], "Write API")
  eq(fake.items[101].rev, 1)
  ok(fake.writes[1].failed)
end)

test("deferred mode queues callbacks until flush", function()
  local fake = Fake.new(seed)
  fake.mode = "deferred"
  local ran = false
  fake.get_work_item({ id = 100 }, function() ran = true end)
  eq(ran, false)
  async(fake, function(done)
    fake.list_projects({}, function(err, names)
      eq(names, { "P" })
      ok(ran, "earlier callback runs first")
      done()
    end)
  end)
end)

test("edit_remotely changes fields and rev without recording a call", function()
  local fake = Fake.new(seed)
  fake:edit_remotely(101, { ["System.Title"] = "Theirs" })
  eq(fake.items[101].rev, 2)
  eq(#fake.calls, 0)
end)

test("query evaluates my items in every state against the seed, newest first", function()
  local fake = Fake.new(seed)
  fake.query(query.request(query.my_items()), function(err, items)
    eq(err, nil)
    eq(ids(items), { 112, 107, 103, 101, 100, 114, 113 })
    eq(items[1]._links, nil)
    eq(items[1].fields["System.Title"], "Resolved bug")
  end)
end)

test("query evaluates CONTAINS WORDS as word prefixes over title and description", function()
  local fake = Fake.new(seed)
  fake.query(query.request(query.text_search("tok")), function(_, items)
    eq(ids(items), { 103 })
  end)
  fake.query(query.request(query.text_search("same TITLE")), function(_, items)
    eq(ids(items), { 109, 108 })
  end)
end)

test("get_work_item includes relations only when asked", function()
  local fake = Fake.new(seed)
  fake.get_work_item({ id = 101 }, function(_, raw) eq(raw.relations, nil) end)
  fake.get_work_item({ id = 101, relations = true }, function(_, raw)
    eq(raw.relations[1].rel, "System.LinkTypes.Hierarchy-Reverse")
    ok(raw.relations[1].url:find("/100$"))
  end)
end)

test("an unknown item is not_found", function()
  local fake = Fake.new(seed)
  fake.get_work_item({ id = 999 }, function(err) eq(err.kind, "not_found") end)
end)

test("query evaluates IN and < conditions", function()
  local fake = Fake.new(seed)
  local spec = { select = { "System.Id" }, order_by = {},
    where = { field = "System.State", op = "IN", value = { "doing", "Resolved" } } }
  fake.query(query.request(spec), function(_, items) eq(ids(items), { 102, 109, 112, 113 }) end)
  spec.where = { field = "System.Id", op = "<", value = 0 }
  fake.query(query.request(spec), function(_, items) eq(items, {}) end)
end)

test("work_item_types lists every type with state categories, or without on request", function()
  local fake = Fake.new(seed)
  fake.work_item_types({ project = "P" }, function(err, list)
    eq(err, nil)
    eq(list[1], { name = "Task", isDisabled = false, states = {
      { name = "To Do", category = "Proposed" }, { name = "Doing", category = "InProgress" },
      { name = "Done", category = "Completed" }, { name = "Discarded", category = "Removed" } } })
    eq(#list, #seed.types)
  end)
  fake.types_omit_categories = true
  fake.work_item_types({ project = "P" }, function(_, list) eq(list[1].states[1], { name = "To Do" }) end)
end)

local function patched(fake, id, patch)
  local err, raw
  fake.patch_work_item({ id = id, patch = patch }, function(e, r) err, raw = e, r end)
  return err, raw
end

local function api_url(id)
  return "https://dev.azure.com/test-org/_apis/wit/workItems/" .. id
end

test("a patch applies its ops in order as one revision, and a link alone leaves the rev", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  local err, raw = patched(fake, 103, { { op = "test", path = "/rev", value = 1 },
    { op = "add", path = "/fields/System.Title", value = "Fix the login" },
    { op = "add", path = "/fields/System.State", value = "Doing" },
    { op = "add", path = "/relations/-", value = { rel = "System.LinkTypes.Hierarchy-Reverse", url = api_url(100) } } })
  eq(err, nil)
  eq(raw.rev, 2)
  eq(fake.items[103].fields["System.Parent"], 100)
  eq(fake.items[100].relations[#fake.items[100].relations].url, api_url(103), "the parent gets the child end")
  eq(fake.items[100].rev, 1)
  err, raw = patched(fake, 103, { { op = "test", path = "/rev", value = 2 },
    { op = "remove", path = "/relations/0" } })
  eq(err, nil)
  eq(raw.rev, 2)
  eq(fake.items[103].fields["System.Parent"], nil)
end)

test("a failed test op is a conflict, and nothing in the patch is written", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  local err = patched(fake, 101, { { op = "add", path = "/fields/System.Title", value = "x" },
    { op = "remove", path = "/relations/0" }, { op = "test", path = "/rev", value = 7 } })
  eq(err, { kind = "conflict",
    message = "VS403351: Test Operation for path /rev failed, value 1 was not equal to test value 7." })
  eq(fake.items[101].fields["System.Title"], "Write API")
  eq(fake.items[101].fields["System.Parent"], 100)
  eq(#fake.writes, 1)
  ok(fake.writes[1].failed)
end)

test("a later op that fails undoes the earlier ones, on both ends of a link", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  local before = #fake.items[105].relations
  local err = patched(fake, 103, {
    { op = "add", path = "/relations/-", value = { rel = "System.LinkTypes.Related", url = api_url(105) } },
    { op = "add", path = "/fields/System.State", value = "Bogus" } })
  ok(err.message:find("'Bogus' that is not in the list", 1, true), err.message)
  eq(#fake.items[105].relations, before)
  eq(fake.items[103].fields["System.State"], "To Do")
end)

test("add on System.Tags merges into the tags, as ADO does; replace replaces", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  patched(fake, 101, { { op = "add", path = "/fields/System.Tags", value = "urgent" } })
  eq(fake.items[101].fields["System.Tags"], "api; backend; urgent")
  patched(fake, 101, { { op = "replace", path = "/fields/System.Tags", value = "urgent" } })
  eq(fake.items[101].fields["System.Tags"], "urgent")
end)

test("a create applies its fields and parent in one call; a failing one creates nothing", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  local err, raw
  fake.create_work_item({ project = "P", type = "Task", patch = {
    { op = "add", path = "/fields/System.Title", value = "New" },
    { op = "add", path = "/fields/System.AreaPath", value = "P\\Team\\A" },
    { op = "add", path = "/relations/-", value = { rel = "System.LinkTypes.Hierarchy-Reverse", url = api_url(100) } },
  } }, function(e, r) err, raw = e, r end)
  eq(err, nil)
  eq({ raw.id, raw.rev, raw.fields["System.State"], fake.items[1000].fields["System.Parent"] }, { 1000, 1, "To Do", 100 })
  fake.create_work_item({ project = "P", type = "Task", patch = {
    { op = "add", path = "/fields/System.Title", value = "Orphan" },
    { op = "add", path = "/relations/-", value = { rel = "System.LinkTypes.Hierarchy-Reverse", url = api_url(999) } },
  } }, function(e) err = e end)
  eq(err.kind, "not_found")
  eq(fake.items[1001], nil)
  eq(fake.next_id, 1001)
end)
