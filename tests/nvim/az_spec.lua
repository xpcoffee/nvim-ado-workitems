-- The az transport builds the same argv as lua/ado/client.lua did before the
-- transport split. No process starts: vim.system is replaced per test.
local az = require("ado.nvim.az")

local URL = "https://dev.azure.com/o"

local function transport(response)
  response = response or {}
  local argvs = {}
  local t = az.new({
    org = "o",
    executable = function() return response.missing == nil end,
    system = function(args, _, on_exit)
      table.insert(argvs, vim.deepcopy(args))
      on_exit({ code = response.code or 0, stdout = response.stdout or "{}", stderr = response.stderr })
    end,
  })
  return t, argvs
end

-- Runs one operation and waits for its scheduled callback.
local function call(t, op, params)
  local done, err, result = false, nil, nil
  t[op](params, function(e, r)
    done, err, result = true, e, r
  end)
  ok(not done, "callback must be scheduled, not synchronous")
  ok(vim.wait(1000, function() return done end), "callback never ran")
  return err, result
end

test("get_work_item runs work-item show", function()
  local t, argvs = transport({ stdout = '{"id": 42, "rev": 3}' })
  local err, raw = call(t, "get_work_item", { id = 42 })
  eq(err, nil)
  eq(raw, { id = 42, rev = 3 })
  eq(argvs[1], { "az", "boards", "work-item", "show", "--id", "42", "--output", "json", "--org", URL })
end)

test("query passes --project after --org and unwraps value", function()
  local t, argvs = transport({ stdout = '{"value": [{"id": 1}]}' })
  local _, items = call(t, "query", { wiql = "SELECT 1", spec = {}, project = "P" })
  eq(items, { { id = 1 } })
  eq(argvs[1], { "az", "boards", "query", "--wiql", "SELECT 1", "--output", "json", "--org", URL, "--project", "P" })
end)

test("query with no results: az prints nothing, the transport returns an empty list", function()
  local err, items = call(transport({ stdout = "" }), "query", { wiql = "W", spec = {}, project = "P" })
  eq(err, nil)
  eq(items, {})
end)

test("query without a project omits --project", function()
  local t, argvs = transport({ stdout = "[]" })
  local _, items = call(t, "query", { wiql = "W", spec = {} })
  eq(items, {})
  eq(argvs[1], { "az", "boards", "query", "--wiql", "W", "--output", "json", "--org", URL })
end)

local PATCH_HEAD = { "az", "rest", "--method", "patch", "--url", URL .. "/_apis/wit/workitems/7?api-version=7.1",
  "--resource", "499b84ac-1321-427f-aa17-267ca6975798", "--headers", "Content-Type=application/json-patch+json",
  "--body" }

test("add_comment runs update --discussion", function()
  local t, argvs = transport()
  call(t, "add_comment", { id = 7, text = "hi there" })
  eq(argvs[1], { "az", "boards", "work-item", "update", "--id", "7", "--discussion", "hi there",
    "--output", "json", "--org", URL })
end)

test("list_projects returns project names", function()
  local t, argvs = transport({ stdout = '{"value": [{"name": "P"}, {"name": "Q"}]}' })
  local _, names = call(t, "list_projects", {})
  eq(names, { "P", "Q" })
  eq(argvs[1], { "az", "devops", "project", "list", "--output", "json", "--org", URL })
end)

test("work_item_type_states runs devops invoke and returns the state list", function()
  local t, argvs = transport({ stdout = '{"value": [{"name": "To Do", "category": "Proposed"}]}' })
  local _, states = call(t, "work_item_type_states", { type = "Task", project = "P" })
  eq(states, { { name = "To Do", category = "Proposed" } })
  eq(argvs[1], { "az", "devops", "invoke", "--area", "wit", "--resource", "workitemtypestates",
    "--route-parameters", "project=P", "type=Task", "--api-version", "6.0", "--output", "json",
    "--org", URL })
end)

test("a login failure becomes an auth error with the actionable message", function()
  local t = transport({ code = 1, stderr = "ERROR: Please run 'az login' to setup account." })
  local err = call(t, "get_work_item", { id = 1 })
  eq(err, { kind = "auth", message = "auth expired - run `az login` (then `az devops login` if prompted)" })
end)

test("other failures keep stderr, and bad JSON and a missing az are reported", function()
  local err = call(transport({ code = 1, stderr = "TF401232: Work item 1 does not exist" }), "get_work_item", { id = 1 })
  eq(err, { kind = "failed", message = "TF401232: Work item 1 does not exist" })
  err = call(transport({ code = 1, stderr = "" }), "get_work_item", { id = 1 })
  eq(err.message, "az command failed")
  err = call(transport({ stdout = "not json" }), "get_work_item", { id = 1 })
  eq(err.message, "failed to parse az output")
  local t, argvs = transport({ missing = true })
  err = call(t, "get_work_item", { id = 1 })
  eq(err.message, "az CLI not found")
  eq(#argvs, 0)
end)

test("work_item_types runs devops invoke with the trimming projection", function()
  local t, argvs = transport({ stdout = '[{"name": "Bug", "isDisabled": false, "states": []}]' })
  local _, list = call(t, "work_item_types", { project = "P" })
  eq(list, { { name = "Bug", isDisabled = false, states = {} } })
  eq(argvs[1], { "az", "devops", "invoke", "--area", "wit", "--resource", "workitemtypes",
    "--route-parameters", "project=P", "--api-version", "7.1",
    "--query", "value[].{name: name, isDisabled: isDisabled, states: states[].{name: name, category: category}}",
    "--output", "json", "--org", URL })
  local err = call(t, "work_item_types", {})
  eq(err.kind, "invalid")
  eq(#argvs, 1)
end)

-- tests/fixtures/az/work_item_types.json is the trimmed response from the
-- Example project, recorded in the phase 1 route check.
local FIXTURES = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/fixtures/az/"

local function read(name)
  local f = assert(io.open(FIXTURES .. name, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

test("the recorded types response builds a catalog with the real open states", function()
  local types = require("ado.core.types")
  local query = require("ado.core.query")
  local wiql = require("ado.core.wiql")
  local _, list = call(transport({ stdout = read("work_item_types.json") }), "work_item_types", { project = "P" })
  eq(#list, 23)
  for _, wt in ipairs(list) do
    for _, s in ipairs(wt.states) do ok(s.category, wt.name .. " " .. s.name .. " has a category") end
  end
  local c = types.new(list)
  eq(c:is_open("Bug", "Resolved"), false)
  eq(c:is_open("Epic", "Resolved"), true)
  eq(c:is_open("Issue", "Waiting for External"), true)
  eq(c:is_open("Issue", "Discarded"), false)
  eq(c:states("Task"), { "New", "Active", "Closed", "Removed" })
  local w = wiql.render(query.my_items(c:open_condition()))
  -- 2,316 characters before types with the same open states were grouped.
  ok(#w < 1800, "my items WIQL is " .. #w .. " characters")
end)

test("the recorded per-type states response keeps categories", function()
  local _, states = call(transport({ stdout = read("work_item_type_states_task.json") }),
    "work_item_type_states", { type = "Task", project = "P" })
  eq(states[4], { name = "Removed", category = "Removed", color = "ffffff" })
end)

test("a query over the warning length is sent and reported in :messages", function()
  local notes = {}
  local notify = vim.notify
  vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
  local t, argvs = transport({ stdout = "[]" })
  call(t, "query", { wiql = string.rep("x", 16001), spec = {} })
  vim.notify = notify
  eq(#argvs, 1)
  eq(notes, { { msg = "[ado] query is 16001 characters; ADO rejects WIQL over 32000", level = vim.log.levels.WARN } })
end)

test("area_children lists one level under the node path, from the recorded response", function()
  local t, argvs = transport({ stdout = read("area_children_platform.json") })
  local err, nodes = call(t, "area_children",
    { project = "Example", path = "\\Example\\Area\\Software\\Platform" })
  eq(err, nil)
  eq(argvs[1], { "az", "boards", "area", "project", "list", "--project", "Example",
    "--path", "\\Example\\Area\\Software\\Platform", "--depth", "1", "--output", "json", "--org", URL })
  eq(#nodes, 5)
  eq(nodes[5].path, "\\Example\\Area\\Software\\Platform\\Team A")
  local _, leaf = call(transport({ stdout = read("area_children_leaf.json") }), "area_children",
    { project = "Example", path = nodes[5].path })
  eq(leaf, {}, "a leaf's children are null in the response")
end)

test("get_work_item with relations adds --expand relations", function()
  local t, argvs = transport({ stdout = '{"id": 42, "rev": 3}' })
  call(t, "get_work_item", { id = 42, relations = true })
  eq(argvs[1], { "az", "boards", "work-item", "show", "--id", "42", "--expand", "relations",
    "--output", "json", "--org", URL })
end)

-- work_item_show_relations.json and query_children.json are trimmed
-- responses from the phase 3 route check, with IDs and titles replaced.
test("the recorded relations response parses to a parent and Related links, without the attachment", function()
  local workitem = require("ado.core.workitem")
  local _, raw = call(transport({ stdout = read("work_item_show_relations.json") }), "get_work_item",
    { id = 1003, relations = true })
  eq(workitem.relations(raw), {
    parent = 1001,
    children = {},
    links = {
      { rel = "System.LinkTypes.Related", name = "Related", id = 1005 },
      { rel = "System.LinkTypes.Related", name = "Related", id = 1004 },
    },
  })
end)

test("the recorded children query normalises, with relations null", function()
  local workitem = require("ado.core.workitem")
  local _, raws = call(transport({ stdout = read("query_children.json") }), "query", { wiql = "W", spec = {} })
  eq(#raws, 3)
  local item = workitem.normalise(raws[2], "example-org")
  eq({ item.id, item.type, item.state }, { 1004, "Task", "New" })
  eq(workitem.relations(raws[2]), { children = {}, links = {} })
end)

test("create_work_item posts the patch to the type's create URL, with the project and type encoded", function()
  local t, argvs = transport({ stdout = read("work_item_create.json") })
  local patch = { { op = "add", path = "/fields/System.Title", value = "T" } }
  local err, raw = call(t, "create_work_item", { project = "My P", type = "User Story", patch = patch })
  eq(err, nil)
  eq({ raw.id, raw.rev, raw.fields["System.State"] }, { 1001, 1, "New" })
  local argv = argvs[1]
  eq({ unpack(argv, 1, 6) }, { "az", "rest", "--method", "post", "--url",
    URL .. "/My%20P/_apis/wit/workitems/$User%20Story?api-version=7.1" })
  eq(vim.json.decode(argv[12]), patch)
  local missing = call(transport(), "create_work_item", { type = "Task", patch = patch })
  eq(missing.kind, "invalid")
end)

test("resolve_identity searches the people picker through az rest and keeps active identities", function()
  local t, argvs = transport({ stdout = read("identity_picker.json") })
  local err, found = call(t, "resolve_identity", { text = "tes" })
  eq(err, nil)
  eq(found, { { display_name = "Test User", unique_name = "test.user@example.com", mail = "test.user@example.com",
    id = "00000000-0000-0000-0000-000000000001" } })
  local argv = argvs[1]
  eq({ unpack(argv, 1, 6) }, { "az", "rest", "--method", "post", "--url",
    URL .. "/_apis/IdentityPicker/Identities?api-version=7.1-preview.1" })
  local body = vim.json.decode(argv[12])
  eq({ body.query, body.operationScopes, body.identityTypes }, { "tes", { "ims" }, { "user" } })
  ok(not vim.tbl_contains(argv, "--org"), "az rest takes the organisation in the URL")
end)

test("a failed test op is a conflict carrying ADO's message; other failures stay failures", function()
  local stderr = read("work_item_patch_test_failed.txt")
  local err = call(transport({ code = 1, stderr = stderr }), "patch_work_item", { id = 7, patch = {} })
  eq(err, { kind = "conflict",
    message = "VS403351: Test Operation for path /rev failed, value 2 was not equal to test value 1." })
  err = call(transport({ code = 1, stderr = "ERROR: Bad Request(TF201036: one parent)" }), "patch_work_item",
    { id = 7, patch = {} })
  eq(err, { kind = "failed", message = "ERROR: Bad Request(TF201036: one parent)" })
end)

test("patch_work_item sends the patch as given, in one az rest call", function()
  local t, argvs = transport({ stdout = read("work_item_patch.json") })
  local patch = { { op = "test", path = "/rev", value = 4 },
    { op = "add", path = "/fields/System.Title", value = "T" },
    { op = "test", path = "/relations/0/url", value = "https://dev.azure.com/o/_apis/wit/workItems/8" },
    { op = "remove", path = "/relations/0" },
    { op = "add", path = "/relations/-", value = { rel = "System.LinkTypes.Hierarchy-Reverse",
      url = "https://dev.azure.com/o/_apis/wit/workItems/9" } } }
  local err, raw = call(t, "patch_work_item", { id = 7, patch = patch })
  eq(err, nil)
  eq({ raw.id, raw.rev, raw.fields["System.State"] }, { 1002, 3, "Closed" })
  local argv = argvs[1]
  eq({ unpack(argv, 1, 11) }, PATCH_HEAD)
  eq(vim.json.decode(argv[12]), patch)
  eq({ unpack(argv, 13) }, { "--output", "json" })
end)
