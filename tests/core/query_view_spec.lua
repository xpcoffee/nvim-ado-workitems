-- The query list (RFC 0001 R9) on the fake gateway: its location, the
-- rows "mine" lists under each filter, the calls a load costs, and the
-- browser URL. Seed items assigned to me: 100, 101, 103 and 112 are open;
-- 107 (Done), 113 (a Resolved User Story) and 114 (Discarded) are not.
local Fake = require("tests.support.fake_gateway")
local location = require("ado.core.location")
local query_view = require("ado.core.query_view")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")
local types = require("ado.core.types")
local wiql = require("ado.core.wiql")

local function new(opts)
  local fake = Fake.new(seed)
  opts = opts or {}
  opts.gateway, opts.org, opts.project = fake, "test-org", "P"
  return session.new(opts), fake
end

local function load(s, loc)
  local view, err
  query_view.load(s, loc, nil, function(e, v) err, view = e, v end)
  return view, err
end

local function ids(view)
  local out = {}
  for _, r in ipairs(view.rows) do table.insert(out, r.id) end
  return out
end

local function sorted(list)
  table.sort(list)
  return list
end

local function decoded(url)
  local prefix = "https://dev.azure.com/test-org/P/_queries/query/?wiql="
  eq(url:sub(1, #prefix), prefix)
  return (url:sub(#prefix + 1):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

test("a query location holds its fixed assignee, and its URI round-trips the other filters", function()
  local loc = location.query("mine")
  eq(loc, { kind = "query", name = "mine", filters = { state = "open", assignee = "@Me" } })
  eq(location.uri(loc), "ado://query/mine?state=open&type=&tag=")
  eq(location.buffer_name(loc), location.uri(loc))
  eq(location.parse(location.uri(loc)), loc)
  local f = location.query("mine", { state = { "To Do", "Won't, ever" }, types = { "Task" }, tag = "a&b",
    assignee = "someone" })
  eq(f.filters.assignee, "@Me", "the query fixes the assignee")
  eq(location.uri(f), "ado://query/mine?state=To Do,Won't%2C ever&type=Task&tag=a%26b")
  eq(location.parse(location.uri(f)), f)
  eq(location.query("nope"), nil)
end)

test("with_filters keeps a query location a query, and its assignee fixed", function()
  local loc = location.with_filters(location.query("mine"), { state = "all", tag = "api", assignee = "x" })
  eq(loc, { kind = "query", name = "mine", filters = { state = "all", assignee = "@Me", tag = "api" } })
  eq(location.describe(loc), "state: all  ·  assignee: @Me  ·  type: any  ·  tag: api")
end)

test("A0001-31 \"mine\" lists the open items assigned to the user, newest first, with one catalog and one query",
  function()
    local s, fake = new()
    local view = load(s, location.query("mine"))
    eq(ids(view), { 112, 103, 101, 100 })
    eq(view.rows[3], { kind = "item", id = 101, rev = 1, type = "Task", state = "To Do", assignee = "Me Myself",
      assignee_unique = "me@example.com", tags = "api; backend", title = "Write API", project = "P",
      area = "P\\Team\\A", parent = 100 })
    eq(view.truncated, false)
    eq({ fake.calls[1].op, fake.calls[2].op }, { "work_item_types", "query" })
    eq(#fake.calls, 2)
  end)

test("A0001-32 the state, type and tag filters narrow \"mine\"", function()
  local s, fake = new()
  local function at(f) return sorted(ids(load(s, location.query("mine", f)))) end
  eq(at({ state = "all" }), { 100, 101, 103, 107, 112, 113, 114 })
  eq(at({ state = { "Done", "Discarded" } }), { 107, 114 })
  eq(at({ types = { "Task" } }), { 101, 103 })
  eq(at({ state = "all", types = { "User Story" } }), { 100, 113 })
  eq(at({ tag = "api" }), { 101 })
  eq(#fake.calls, 6, "the catalog loads once, then one query per list")
end)

test("each project's open condition is tied to that project", function()
  local c = types.new(seed.types)
  local w = wiql.render(query_view.spec(location.query("mine", { types = { "Bug" } }), { "P", "Q" },
    { P = c, Q = c }, { select = { "System.Id" } }))
  eq(w, "SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = @Me"
    .. " AND [System.TeamProject] IN ('P', 'Q')"
    .. " AND (([System.TeamProject] = 'P' AND ([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active', 'Resolved')))"
    .. " OR ([System.TeamProject] = 'Q' AND ([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active', 'Resolved'))))"
    .. " ORDER BY [System.ChangedDate] DESC")
end)

test("without a project the load fails before any call", function()
  local fake = Fake.new(seed)
  local s = session.new({ gateway = fake, org = "test-org" })
  local _, err = load(s, location.query("mine"))
  eq(err.kind, "invalid")
  eq(#fake.calls, 0)
end)

test("selecting a row leads to its item view", function()
  local s = new()
  local view = load(s, location.query("mine"))
  eq(query_view.select(view, view.rows[1]), location.item(112))
end)

test("the browser URL runs the list's query, open states limited to the loaded types", function()
  local s = new()
  local view = load(s, location.query("mine", { types = { "Task" } }))
  eq(decoded(query_view.browser_url("test-org", view)),
    "SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.AssignedTo],"
    .. " [System.Tags], [System.AreaPath] FROM WorkItems WHERE [System.AssignedTo] = @Me"
    .. " AND [System.TeamProject] IN ('P')"
    .. " AND ([System.WorkItemType] = 'Task' AND [System.State] IN ('To Do', 'Doing'))"
    .. " ORDER BY [System.ChangedDate] DESC")
end)

test("a list in every state needs no catalog, and its browser URL names the filters", function()
  local s, fake = new()
  local view = load(s, location.query("mine", { state = "all", tag = "api" }))
  eq(#fake.calls, 1)
  eq(decoded(query_view.browser_url("test-org", view)),
    "SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.AssignedTo],"
    .. " [System.Tags], [System.AreaPath] FROM WorkItems WHERE [System.AssignedTo] = @Me"
    .. " AND [System.Tags] CONTAINS 'api' AND [System.TeamProject] IN ('P')"
    .. " ORDER BY [System.ChangedDate] DESC")
end)

test("a truncated list's browser URL keeps the open condition for every type", function()
  local s = new({ query_top = 1 })
  local view = load(s, location.query("mine"))
  eq(view.truncated, true)
  ok(query_view.browser_url("test-org", view):find("Issue", 1, true))
end)

test("a browser URL over the web UI's limit is refused with its length", function()
  local s = new()
  local view = load(s, location.query("mine", { state = "all", tag = string.rep("x", 3000) }))
  local url, err = query_view.browser_url("test-org", view)
  eq(url, nil)
  eq(err.kind, "invalid")
  ok(err.length > 3000)
end)
