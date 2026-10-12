local query = require("ado.core.query")
local wiql = require("ado.core.wiql")

local SELECT = "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType],"
  .. " [System.AssignedTo], [System.Tags], [System.IterationPath], [System.AreaPath],"
  .. " [System.TeamProject], [System.ChangedDate], [System.Description] FROM WorkItems"

local OPEN = { any = {
  { all = {
    { field = "System.WorkItemType", op = "=", value = "Bug" },
    { field = "System.State", op = "IN", value = { "New", "Active" } },
  } },
  { all = {
    { field = "System.WorkItemType", op = "=", value = "Task" },
    { field = "System.State", op = "IN", value = { "To Do" } },
  } },
} }

local OPEN_WIQL = "(([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active'))"
  .. " OR ([System.WorkItemType] = 'Task' AND [System.State] IN ('To Do')))"

test("my items with an open condition", function()
  eq(wiql.render(query.my_items(OPEN)), SELECT
    .. " WHERE [System.AssignedTo] = @Me AND " .. OPEN_WIQL
    .. " ORDER BY [System.ChangedDate] DESC")
end)

test("text search with an open condition", function()
  eq(wiql.render(query.text_search("login bug", OPEN)), SELECT
    .. " WHERE ([System.Title] CONTAINS WORDS 'login bug' OR [System.Description] CONTAINS WORDS 'login bug')"
    .. " AND " .. OPEN_WIQL
    .. " ORDER BY [System.ChangedDate] DESC")
end)

test("text search in every state has no state condition", function()
  eq(wiql.render(query.text_search("login bug")), SELECT
    .. " WHERE [System.Title] CONTAINS WORDS 'login bug' OR [System.Description] CONTAINS WORDS 'login bug'"
    .. " ORDER BY [System.ChangedDate] DESC")
end)

test("IN lists escape quotes in each name", function()
  eq(wiql.render({
    select = { "System.Id" },
    where = { field = "System.State", op = "IN", value = { "Won't fix", "Active" } },
  }), "SELECT [System.Id] FROM WorkItems WHERE [System.State] IN ('Won''t fix', 'Active')")
end)

test("single quotes in search text are doubled", function()
  local s = wiql.render(query.text_search("it's 'quoted'"))
  ok(s:find("CONTAINS WORDS 'it''s ''quoted'''", 1, true), s)
end)

test("request carries both the WIQL and the spec", function()
  local spec = query.my_items()
  local req = query.request(spec)
  eq(req.spec, spec)
  eq(req.wiql, wiql.render(spec))
end)

test("numbers render unquoted and a group of one has no parentheses", function()
  eq(wiql.render({
    select = { "System.Id" },
    where = { all = { { any = { { field = "System.Id", op = "=", value = 7 } } } } },
  }), "SELECT [System.Id] FROM WorkItems WHERE [System.Id] = 7")
end)
