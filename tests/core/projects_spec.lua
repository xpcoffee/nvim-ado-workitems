-- Configured projects (owner decision 2026-10-12, RFC 0002 R1.8 and R1.9):
-- lists cover only the configured projects, and each item is judged open by
-- its own project's type catalog.
local Fake = require("tests.support.fake_transport")
local query = require("ado.core.query")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")
local wiql = require("ado.core.wiql")

-- Projects P and Q both have a Bug type, but Resolved is open (InProgress) in
-- P and finished (Resolved) in Q. Project R is never configured.
local Q_TYPES = {
  { name = "Bug", states = {
    { name = "New", category = "Proposed" },
    { name = "Resolved", category = "Resolved" },
  } },
}

local function data()
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  d.projects = { "P", "Q", "R" }
  d.project_types = { Q = Q_TYPES, R = Q_TYPES }
  d.items = {
    { id = 1, project = "P", type = "Bug", title = "Login P", state = "Resolved", area = "P\\Team", assignee = "me@example.com" },
    { id = 2, project = "Q", type = "Bug", title = "Login Q", state = "Resolved", area = "Q", assignee = "me@example.com" },
    { id = 3, project = "Q", type = "Bug", title = "Login Q new", state = "New", area = "Q", assignee = "me@example.com" },
    { id = 4, project = "R", type = "Bug", title = "Login R", state = "New", area = "R", assignee = "me@example.com" },
  }
  return d
end

local function new(opts)
  local fake = Fake.new(data())
  opts.transport = fake
  opts.org = "test-org"
  return session.new(opts), fake
end

local function ids(items)
  local out = {}
  for _, it in ipairs(items) do table.insert(out, it.id) end
  table.sort(out)
  return out
end

local function ops(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do table.insert(out, c.op .. (c.params.project and (" " .. c.params.project) or "")) end
  return out
end

local PQ = { { name = "P", types = { "Task", "Bug" } }, { name = "Q" } }

test("the scope limits a query to the configured projects", function()
  local spec = query.text_search("login", query.scope({ "P", "Q" }))
  ok(wiql.render(spec):find(" AND [System.TeamProject] IN ('P', 'Q') ORDER BY", 1, true), wiql.render(spec))
end)

test("with open states, each project's condition is tied to that project", function()
  local open_p = { field = "System.State", op = "IN", value = { "Active" } }
  local open_q = { field = "System.State", op = "IN", value = { "New" } }
  eq(wiql.render({ select = { "System.Id" }, where = query.scope({ "P", "Q" }, { open_p, open_q }) }),
    "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] IN ('P', 'Q')"
    .. " AND (([System.TeamProject] = 'P' AND [System.State] IN ('Active'))"
    .. " OR ([System.TeamProject] = 'Q' AND [System.State] IN ('New')))")
  eq(wiql.render({ select = { "System.Id" }, where = query.scope({ "P" }, { open_p }) }),
    "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] IN ('P') AND [System.State] IN ('Active')")
  eq(query.scope({}), nil)
end)

test("the same type name is judged by each item's own project catalog", function()
  local s = new({ projects = PQ })
  s:my_items(function(err, items)
    eq(err, nil)
    eq(ids(items), { 1, 3 }, "P's Resolved Bug is open, Q's is not, R is not configured")
  end)
  s:search("login", { all_states = true }, function(_, items) eq(ids(items), { 1, 2, 3 }) end)
end)

test("catalogs load lazily, one call per configured project, then are reused", function()
  local s, fake = new({ projects = PQ })
  eq(#fake.calls, 0, "creating the session makes no call")
  s:search("login", { all_states = true }, function() end)
  eq(ops(fake), { "query P" }, "an all-states search needs no catalog")
  s:states("Bug", "Q", function(_, names) eq(names, { "New", "Resolved" }) end)
  eq(ops(fake), { "query P", "work_item_types Q" }, "one project's lookup loads only that project")
  s:my_items(function() end)
  s:my_items(function() end)
  eq(ops(fake), { "query P", "work_item_types Q", "work_item_types P", "query P", "query P" })
end)

test("without configured projects the one chosen project is the scope", function()
  local s, fake = new({ project = "Q" })
  eq(s:project_names(), { "Q" })
  s:my_items(function(_, items) eq(ids(items), { 3 }) end)
  eq(ops(fake), { "work_item_types Q", "query Q" })
  ok(fake.calls[2].params.wiql:find("[System.TeamProject] IN ('Q')", 1, true), fake.calls[2].params.wiql)
end)

test("configured projects win over a configured project", function()
  local s = new({ projects = PQ, project = "R" })
  eq(s:project_names(), { "P", "Q" })
  eq(s:default_project(), "P")
end)

test("configured types the catalog lacks are reported once per session, without failing the load", function()
  local events = {}
  local s = session.new({ transport = Fake.new(data()), org = "test-org",
    projects = { { name = "P", types = { "task", "Epik", "Bug", "Storey" } }, { name = "Q", types = { "Bug" } } },
    on_event = function(e) table.insert(events, e) end })
  local loaded
  s:catalog("P", function(err, catalog) eq(err, nil) loaded = catalog end)
  ok(loaded ~= nil)
  s:catalog("P", function() end)
  s:catalog("Q", function() end)
  local unknown = {}
  for _, e in ipairs(events) do
    if e.kind == "unknown_types" then table.insert(unknown, e) end
  end
  eq(unknown, { { kind = "unknown_types", project = "P", unknown = { "Epik", "Storey" },
    valid = { "Task", "User Story", "Bug", "Issue" } } })
end)

test("a malformed projects setting fails at session creation", function()
  fails(function() new({ projects = { { types = {} } } }) end, "projects%[1%] needs a name")
  fails(function() new({ projects = { { name = "P", types = "Task" } } }) end, "types must be a list")
end)
