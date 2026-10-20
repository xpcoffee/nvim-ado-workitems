-- Applying a change plan: one write request per work item, the revision
-- guard per item, partial failure, and one event per applied or failed
-- request for the audit log.
local Fake = require("tests.support.fake_gateway")
local apply = require("ado.core.apply")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")
local summary = require("ado.core.summary")
local workitem = require("ado.core.workitem")

local function new()
  local fake = Fake.new(seed)
  return session.new({ gateway = fake, org = "test-org", project = "P" }), fake
end

local function op(id, name, from, to)
  local refs = { title = "System.Title", state = "System.State" }
  return { kind = "update", id = id, field = refs[name], name = name, from = from, to = to, expect_rev = 1,
    views = { "ado://area/P/Team/A" } }
end

local function run(s, plan)
  local events, result = {}, nil
  apply.run(s, plan, { on_event = function(e) table.insert(events, e) end }, function(r) result = r end)
  return result, events
end

local function writes(fake)
  local out = {}
  for _, w in ipairs(fake.writes) do
    if not w.failed then table.insert(out, { w.op, w.params.id, w.params.patch }) end
  end
  return out
end

local function texts(lines)
  local out = {}
  for _, l in ipairs(lines) do table.insert(out, l.text) end
  return out
end

local function url(id)
  return "https://dev.azure.com/test-org/_apis/wit/workItems/" .. id
end

test("each item's changes are one patch, led by a test of the rev the plan was made from", function()
  local s, fake = new()
  local result = run(s, { ops = { op(101, "title", "Write API", "Write the API"), op(103, "state", "To Do", "Doing"),
    op(101, "state", "To Do", "Doing") } })
  eq(writes(fake), {
    { "patch_work_item", 101, { { op = "test", path = "/rev", value = 1 },
      { op = "add", path = "/fields/System.Title", value = "Write the API" },
      { op = "add", path = "/fields/System.State", value = "Doing" } } },
    { "patch_work_item", 103, { { op = "test", path = "/rev", value = 1 },
      { op = "add", path = "/fields/System.State", value = "Doing" } } },
  })
  eq(#result.completed, 2, "one per work item")
  eq(result.failed, nil)
  eq(result.touched, { 101, 103 })
  eq(fake.items[101].fields["System.Title"], "Write the API")
  eq(fake.items[101].rev, 2, "both changes are one revision")
end)

test("two changes to one item read it once and write it once", function()
  local s, fake = new()
  local result = run(s, { ops = { op(101, "title", "Write API", "Write the API"), op(101, "state", "To Do", "Doing") } })
  eq(#result.completed, 1)
  eq(fake.counts.get_work_item, 1)
  eq(fake.counts.patch_work_item, 1)
end)

test("A0001-24 an update to an item whose revision changed since the snapshot fails without writing", function()
  local s, fake = new()
  fake:edit_remotely(101, { ["System.Title"] = "Changed in the web UI" })
  local result = run(s, { ops = { op(101, "state", "To Do", "Doing") } })
  eq(#fake.writes, 0)
  eq(result.failed.request.id, 101)
  eq(result.failed.error.kind, "conflict")
  eq(result.failed.error.message, "#101 changed remotely (rev 1 -> 2)")
  eq(fake.items[101].fields["System.State"], "To Do")
  eq(result.touched, { 101 })
end)

-- The window Risk 2 in plan 0001 described: a change in ADO after apply
-- reads the item and before the write.
test("a change between the read and the write fails the test op, and ADO writes nothing", function()
  local s, fake = new()
  local get = fake.get_work_item
  fake.get_work_item = function(params, cb)
    get(params, function(err, raw)
      fake:edit_remotely(101, { ["System.Title"] = "Changed in the web UI" })
      cb(err, raw)
    end)
  end
  local result = run(s, { ops = { op(101, "title", "Write API", "Write the API"), op(101, "state", "To Do", "Doing") } })
  eq(result.failed.error.kind, "conflict")
  eq(result.failed.error.message, "#101 changed remotely after it was read at rev 1, so ADO wrote nothing to it"
    .. " (VS403351: Test Operation for path /rev failed, value 2 was not equal to test value 1.)")
  eq(fake.items[101].fields["System.Title"], "Changed in the web UI")
  eq(fake.items[101].fields["System.State"], "To Do", "the other change in the request was not written either")
end)

test("a link removal names the relation by its index in the fresh read, and tests that relation first", function()
  local s, fake = new()
  local result = run(s, { ops = {
    { kind = "remove_link", id = 101, rel = workitem.PARENT, target = 100, expect_rev = 1 },
    op(101, "title", "Write API", "Write the API"),
  } })
  eq(result.failed, nil)
  eq(writes(fake), { { "patch_work_item", 101, {
    { op = "test", path = "/rev", value = 1 },
    { op = "add", path = "/fields/System.Title", value = "Write the API" },
    { op = "test", path = "/relations/0/url", value = url(100) },
    { op = "remove", path = "/relations/0" },
  } } })
  eq(fake.items[101].fields["System.Parent"], nil)
  eq(#fake.items[100].relations, 2, "100 keeps its other links")
  eq(result.touched, { 101, 100 })
end)

test("a link moved remotely between the read and the write fails the relation's test, and nothing is removed",
  function()
    local s, fake = new()
    local get = fake.get_work_item
    fake.get_work_item = function(params, cb)
      get(params, function(err, raw)
        table.insert(fake.items[101].relations, 1, { rel = workitem.PARENT, url = url(999) })
        cb(err, raw)
      end)
    end
    local result = run(s, { ops = { { kind = "remove_link", id = 101, rel = workitem.PARENT, target = 100,
      expect_rev = 1 } } })
    eq(result.failed.error.kind, "conflict")
    ok(result.failed.error.message:find("Test Operation for path /relations/0/url failed", 1, true),
      result.failed.error.message)
    eq(fake.items[101].fields["System.Parent"], 100)
  end)

test("a link to remove that the fresh read no longer has fails as a remote change, with no write", function()
  local s, fake = new()
  local result = run(s, { ops = { { kind = "remove_link", id = 103, rel = workitem.PARENT, target = 100,
    expect_rev = 1 } } })
  eq(#fake.writes, 0)
  eq(result.failed.error.message, "#103 no longer has parent #100 in ADO; it changed remotely")
end)

test("A0001-23 when the second of three requests fails: one completed, one failed, one not attempted", function()
  local s, fake = new()
  fake:fail_on("patch_work_item", 2)
  local plan = { ops = { op(101, "state", "To Do", "Doing"), op(102, "state", "Doing", "Done"),
    op(103, "state", "To Do", "Doing") } }
  local result = run(s, plan)
  eq(#result.completed, 1)
  eq(result.completed[1].id, 101)
  eq(result.failed.request.id, 102)
  eq(#result.not_attempted, 1)
  eq(result.not_attempted[1].id, 103)
  eq(result.touched, { 101, 102 }, "the views of these items reload")
  eq(fake.counts.patch_work_item, 2)
  eq(texts(summary.report(result)), {
    "Save stopped: 1 of 3 work items saved, 1 failed, 1 not attempted",
    "Completed", "  #101 state: To Do -> Doing",
    "Failed: nothing was written to #102", "  #102 state: Doing -> Done", "  error: fake failure on patch_work_item",
    "Not attempted", "  #103 state: To Do -> Doing",
  })
  eq(summary.result_line(result), "save stopped at #102: 1 of 3 work items saved, 1 not attempted")
end)

test("every applied or failed request produces one audit event; not attempted ones produce none", function()
  local s, fake = new()
  fake:fail_on("patch_work_item", 2)
  local _, events = run(s, { ops = { op(101, "state", "To Do", "Doing"), op(101, "title", "Write API", "W"),
    op(102, "state", "Doing", "Done"), op(103, "state", "To Do", "Doing") } })
  local done = {}
  for _, e in ipairs(events) do
    if e.kind == "request" then table.insert(done, { e.request.id, #e.request.ops, e.result, e.index, e.total }) end
  end
  eq(done, { { 101, 2, "ok", 1, 3 }, { 102, 1, "failed", 2, 3 } })
  eq(events[2].rev, 2, "the ok event carries the new rev")
  eq(events[1], { kind = "start", index = 1, total = 3, request = events[1].request })
end)

test("apply works when the gateway calls back later", function()
  local s, fake = new()
  fake.mode = "deferred"
  local result
  apply.run(s, { ops = { op(101, "state", "To Do", "Doing"), op(103, "state", "To Do", "Doing") } }, {},
    function(r) result = r end)
  eq(result, nil)
  fake:flush()
  eq(#result.completed, 2)
end)

test("the report and the line after a full save count the changes and the work items", function()
  local s = new()
  local result = run(s, { ops = { op(101, "state", "To Do", "Doing"), op(101, "title", "Write API", "W") } })
  eq(texts(summary.report(result)), { "Saved 2 changes to 1 work item", "Completed", "  #101 state: To Do -> Doing",
    "  #101 title: 'Write API' -> 'W'" })
  eq(summary.result_line(result), "saved 2 changes to 1 work item: 2 field updates")
end)
