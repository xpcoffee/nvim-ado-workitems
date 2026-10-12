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
  fake.update_fields({ id = 101, fields = { ["System.Title"] = "New" } }, function() end)
  fake.list_projects({}, function() end)
  eq(#fake.calls, 3)
  eq(fake.calls[1].op, "get_work_item")
  eq(fake.calls[2], { op = "update_fields", params = { id = 101, fields = { ["System.Title"] = "New" } } })
  eq(#fake.writes, 1)
  eq(fake.writes[1].op, "update_fields")
end)

test("a write bumps rev and returns the updated raw item", function()
  local fake = Fake.new(seed)
  local result
  fake.update_fields({ id = 103, fields = { ["System.State"] = "Doing" } }, function(err, raw)
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
  fake:fail_on("update_fields", 1)
  fake.update_fields({ id = 101, fields = { ["System.Title"] = "X" } }, function(err)
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
