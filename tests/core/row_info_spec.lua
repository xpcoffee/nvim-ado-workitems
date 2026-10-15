-- The full-row float's lines (plan 0002 UX4.4).
local row_info = require("ado.core.row_info")

local LOADED = { id = 101, assignee = "Alex Jones", assignee_unique = "alex.jones@example.com", area = "P\\Team\\A" }

test("UX4.4 an item with an assignee and tags", function()
  eq(row_info.lines({ type = "User Story", state = "Active", title = "Write the API for the login service",
    assignee = "Alex Jones", tags = "api; backend" }, LOADED), {
    "#101  User Story · Active",
    "title     Write the API for the login service",
    "assignee  Alex Jones <alex.jones@example.com>",
    "tags      api; backend",
    "area      P\\Team\\A",
  })
end)

test("UX4.4 an item with no assignee or tags, and an email typed for the loaded person", function()
  local lines = row_info.lines({ type = "Task", state = "New", title = "T", assignee = "", tags = "" }, LOADED)
  eq(lines[3], "assignee  none")
  eq(lines[4], "tags      none")
  eq(row_info.lines({ type = "Task", state = "New", title = "T", assignee = "ALEX.JONES@example.com", tags = "" },
    LOADED)[3], "assignee  Alex Jones <alex.jones@example.com>")
  eq(row_info.lines({ type = "Task", state = "New", title = "T", assignee = "sam@example.com", tags = "" },
    LOADED)[3], "assignee  sam@example.com", "another person, as typed")
end)

test("UX4.4 a new line has no ID or area", function()
  eq(row_info.lines({ type = "Task", state = "", title = "New", assignee = "", tags = "" }, nil), {
    "new  Task", "title     New", "assignee  none", "tags      none" })
end)
