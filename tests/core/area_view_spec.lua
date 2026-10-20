local Fake = require("tests.support.fake_gateway")
local area_view = require("ado.core.area_view")
local location = require("ado.core.location")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")
local types = require("ado.core.types")
local wiql = require("ado.core.wiql")

local function with(overrides)
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  for k, v in pairs(overrides) do d[k] = v end
  return d
end

local function new(data, opts)
  local fake = Fake.new(data or seed)
  opts = opts or {}
  opts.gateway = fake
  opts.org = "test-org"
  opts.project = "P"
  return session.new(opts), fake
end

local function load(s, loc)
  local view, err
  area_view.load(s, loc, nil, function(e, v) err, view = e, v end)
  return view, err
end

local function row_keys(view)
  local out = {}
  for _, r in ipairs(view.rows) do table.insert(out, r.kind == "area" and r.name or r.id) end
  return out
end

local function ids(view)
  local out = {}
  for _, r in ipairs(view.rows) do if r.kind == "item" then table.insert(out, r.id) end end
  table.sort(out)
  return out
end

local function ops(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do table.insert(out, c.op) end
  return out
end

-- P\Team with sub-areas B and A (unsorted), three open items in P\Team, one
-- finished item in P\Team and one open item in P\Team\A.
local TEAM = with({
  areas = { "P\\Team", "P\\Team\\B", "P\\Team\\A", "P\\Team\\A\\Deep" },
  items = {
    { id = 1, type = "Task", title = "One", state = "To Do", area = "P\\Team", changed = "2026-10-03" },
    { id = 2, type = "Task", title = "Two", state = "Doing", area = "P\\Team", changed = "2026-10-02",
      assignee = "me@example.com", tags = "api; backend" },
    { id = 3, type = "Bug", title = "Three", state = "Resolved", area = "P\\Team", changed = "2026-10-01",
      assignee = "alex.smith@example.com" },
    { id = 4, type = "Task", title = "Finished", state = "Done", area = "P\\Team", changed = "2026-10-04" },
    { id = 5, type = "Task", title = "In A", state = "To Do", area = "P\\Team\\A", changed = "2026-10-05",
      assignee = "me@example.com" },
  },
})

test("A0001-1 the area view lists sub-areas first, then the open items", function()
  local s = new(TEAM)
  local view = load(s, location.area("P\\Team"))
  eq(row_keys(view), { "A", "B", 1, 2, 3 })
  eq(view.rows[1], { kind = "area", path = "P\\Team\\A", name = "A" })
  eq(view.rows[4], { kind = "item", id = 2, rev = 1, type = "Task", state = "Doing",
    assignee = "Me Myself", assignee_unique = "me@example.com", tags = "api; backend", title = "Two",
    project = "P", area = "P\\Team" })
  eq(view.areas[1].has_children, true)
  eq(view.truncated, false)
end)

test("A0001-2 with the sub-area toggle on, items of P\\Team\\A are listed too", function()
  local s = new(TEAM)
  eq(ids(load(s, location.area("P\\Team", nil, true))), { 1, 2, 3, 5 })
  eq(ids(load(s, location.area("P\\Team"))), { 1, 2, 3 })
end)

test("A0001-3 entering a sub-area keeps the assignee filter", function()
  local s = new(TEAM)
  local team = location.area("P\\Team", { assignee = "@Me" })
  local team_view = load(s, team)
  eq(ids(team_view), { 2 })
  local view = load(s, location.at(team, team_view.rows[1].path))
  eq(view.location.filters.assignee, "@Me")
  eq(ids(view), { 5 })
end)

test("a load costs area_children and query, plus the catalog once per project", function()
  local s, fake = new(TEAM)
  load(s, location.area("P\\Team"))
  load(s, location.area("P\\Team\\A"))
  load(s, location.area("P\\Team", { state = "all" }))
  eq(ops(fake), { "area_children", "work_item_types", "query", "area_children", "query",
    "area_children", "query" })
  eq(fake.calls[1].params, { project = "P", path = "\\P\\Area\\Team" })
end)

test("progress reports each of the two steps", function()
  local s, fake = new(TEAM)
  fake.mode = "deferred"
  local steps = {}
  area_view.load(s, location.area("P\\Team"), {
    on_progress = function(done, total, what) table.insert(steps, { done, total, what }) end,
  }, function() end)
  fake:flush()
  eq(steps, { { 1, 2, "sub-areas" }, { 2, 2, "items" } })
end)

test("filters: all states, state names, a named assignee, types and a whole tag", function()
  local s = new(TEAM)
  local function at(f) return ids(load(s, location.area("P\\Team", f))) end
  eq(at({ state = "all" }), { 1, 2, 3, 4 })
  eq(at({ state = { "Done", "Resolved" } }), { 3, 4 })
  eq(at({ assignee = "alex.smith@example.com" }), { 3 })
  eq(at({ types = { "Bug" } }), { 3 })
  eq(at({ state = "all", types = { "Task" } }), { 1, 2, 4 })
  eq(at({ tag = "api" }), { 2 })
  eq(at({ tag = "ap" }), {}, "a tag matches whole, as in ADO")
end)

test("WIQL for the default filters, with = and UNDER", function()
  local c = types.new(seed.types)
  local base = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] IN ('P')"
  local function render(loc) return wiql.render(area_view.spec(loc, c, { select = { "System.Id" } })) end
  eq(render(location.area("P\\Team", { types = { "Bug" } })), base
    .. " AND [System.AreaPath] = 'P\\Team'"
    .. " AND ([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active', 'Resolved'))"
    .. " ORDER BY [System.ChangedDate] DESC")
  eq(render(location.area("P\\Team", { state = "all" }, true)), base
    .. " AND [System.AreaPath] UNDER 'P\\Team' ORDER BY [System.ChangedDate] DESC")
end)

test("WIQL for state names, @Me, a named assignee, types and a tag", function()
  local function render(f)
    return wiql.render(area_view.spec(location.area("P\\Team", f), nil, { select = { "System.Id" } }))
  end
  local base = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] IN ('P')"
    .. " AND [System.AreaPath] = 'P\\Team'"
  local order = " ORDER BY [System.ChangedDate] DESC"
  eq(render({ state = { "New", "Won't fix" }, types = { "Task", "Bug" } }), base
    .. " AND [System.State] IN ('New', 'Won''t fix') AND [System.WorkItemType] IN ('Task', 'Bug')" .. order)
  eq(render({ state = "all", assignee = "@me" }), base .. " AND [System.AssignedTo] = @Me" .. order)
  eq(render({ state = "all", assignee = "Alex Smith" }), base .. " AND [System.AssignedTo] = 'Alex Smith'" .. order)
  eq(render({ state = "all", tag = "api" }), base .. " AND [System.Tags] CONTAINS 'api'" .. order)
end)

test("a view of another project's area uses that project's catalog and scope", function()
  local data = with({
    projects = { "P", "Q" },
    areas = { "Q\\Ops" },
    project_types = { Q = { { name = "Bug", states = {
      { name = "Resolved", category = "Resolved" }, { name = "Triage", category = "Proposed" } } } } },
    items = {
      { id = 1, project = "Q", type = "Bug", title = "Q open", state = "Triage", area = "Q\\Ops" },
      { id = 2, project = "Q", type = "Bug", title = "Q resolved", state = "Resolved", area = "Q\\Ops" },
    },
  })
  local s, fake = new(data, { projects = { { name = "P" }, { name = "Q" } } })
  eq(ids(load(s, location.area("Q/Ops"))), { 1 })
  eq(fake.calls[2].params, { project = "Q" })
  ok(fake.calls[3].params.wiql:find("[System.TeamProject] IN ('Q')", 1, true))
end)

test("more items than query_top set the truncated flag", function()
  local s = new(TEAM, { query_top = 2 })
  local view = load(s, location.area("P\\Team"))
  eq(#view.items, 2)
  eq(view.truncated, true)
  eq(view.total, 3)
end)

test("a failed call fails the load once, with the gateway's error", function()
  local s, fake = new(TEAM)
  fake:fail_on("area_children", 1, { kind = "failed", message = "no such area" })
  local calls = 0
  area_view.load(s, location.area("P\\Nope"), nil, function(err, view)
    calls = calls + 1
    eq(err, { kind = "failed", message = "no such area" })
    eq(view, nil)
  end)
  eq(calls, 1)
end)

test("an unknown area path fails on the fake as on ADO", function()
  local _, err = load(new(TEAM), location.area("P\\Nope"))
  eq(err.kind, "failed")
end)

test("the browser URL runs the view's query, open states limited to the loaded types", function()
  local s = new(TEAM)
  local view = load(s, location.area("P\\Team", { assignee = "@Me" }))
  local url = area_view.browser_url("test-org", view)
  local prefix = "https://dev.azure.com/test-org/P/_queries/query/?wiql="
  eq(url:sub(1, #prefix), prefix)
  local w = url:sub(#prefix + 1):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  eq(w, "SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.AssignedTo],"
    .. " [System.Tags], [System.AreaPath] FROM WorkItems WHERE [System.TeamProject] IN ('P')"
    .. " AND [System.AreaPath] = 'P\\Team'"
    .. " AND ([System.WorkItemType] = 'Task' AND [System.State] IN ('To Do', 'Doing'))"
    .. " AND [System.AssignedTo] = @Me ORDER BY [System.ChangedDate] DESC")
end)

test("a truncated view's browser URL keeps the open condition for every type", function()
  local s = new(TEAM, { query_top = 1 })
  local url = area_view.browser_url("test-org", load(s, location.area("P\\Team")))
  ok(url:find("Issue", 1, true), "every type of the catalog is in the condition")
end)

test("a browser URL over the web UI's limit is refused with its length", function()
  local s = new(TEAM)
  local view = load(s, location.area("P\\Team", { state = "all", tag = string.rep("x", 3000) }))
  local url, err = area_view.browser_url("test-org", view)
  eq(url, nil)
  eq(err.kind, "invalid")
  ok(err.length > 3000)
end)
