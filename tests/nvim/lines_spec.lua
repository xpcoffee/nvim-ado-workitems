local lines = require("ado.nvim.lines")

local function item(id, title, extra)
  local r = { kind = "item", id = id, type = "Task", state = "To Do", assignee = "", tags = "", title = title }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

test("rows render with the row ID prefix, sub-areas marked, columns aligned", function()
  local text, prefixes = lines.render({
    { kind = "area", name = "A", path = "P\\Team\\A" },
    item(108, "Same title"),
    item(109, "Same title", { type = "User Story", state = "Active", assignee = "Alex Smith", tags = "api" }),
  }, { 7, 8, 12 })
  eq(text, {
    "/7 ▸ A/",
    "/8 Task       │ To Do  │ Same title │            │",
    "/12 User Story │ Active │ Same title │ Alex Smith │ api",
  })
  eq(prefixes, { 3, 3, 4 })
end)

test("parse reads back each column; duplicate titles stay apart by row ID", function()
  local text = lines.render({ item(108, "Same title"), item(109, "Same title", { tags = "a; b" }) }, { 1, 2 })
  eq(lines.parse(text[1]), { row_id = 1, kind = "item", type = "Task", state = "To Do", assignee = "",
    tags = "", title = "Same title" })
  eq(lines.parse(text[2]).row_id, 2)
  eq(lines.parse(text[2]).tags, "a; b")
end)

test("a title holding a slash or the column separator parses whole", function()
  local text = lines.render({ item(110, "A/B test rollout"), item(111, "x │ y / z/") }, { 3, 4 })
  eq(lines.parse(text[1]).title, "A/B test rollout")
  eq(lines.parse(text[2]).title, "x │ y / z/")
  eq(lines.parse(text[2]).kind, "item")
  eq(lines.parse(text[2]).assignee, "")
end)

test("columns render as type, state, title, assignee, tags", function()
  local text = lines.render({ item(112, "Ship it", { assignee = "Alex Smith", tags = "api" }) }, { 1 })
  eq(text[1], "/1 Task │ To Do │ Ship it │ Alex Smith │ api")
  eq(lines.parse(text[1]), { row_id = 1, kind = "item", type = "Task", state = "To Do", assignee = "Alex Smith",
    tags = "api", title = "Ship it" })
end)

test("sub-area rows parse to their name, and a line without a prefix has no row ID", function()
  eq(lines.parse("/5 ▸ Team A/"), { row_id = 5, kind = "area", name = "Team A" })
  eq(lines.parse("New task title"), { kind = "item", title = "New task title" })
end)

test("headings and indented rows render and parse; given widths are kept", function()
  local rows = {
    { kind = "heading", label = "Children: 2 open of 3" },
    { kind = "item", type = "Task", state = "To Do", assignee = "", tags = "", title = "Child", depth = 1 },
  }
  local text, prefixes, widths = lines.render(rows, { 7, 8 }, { 10, 6, 0, 0, 0 })
  eq(text, { "/7 ── Children: 2 open of 3", "/8   Task     │ To Do  │ Child │  │" })
  eq(prefixes, { 3, 3 })
  eq(widths, { 10, 6, 5, 0, 0 })
  eq(lines.parse(text[1]), { row_id = 7, kind = "heading", label = "Children: 2 open of 3" })
  eq(lines.parse(text[2]), { row_id = 8, kind = "item", type = "Task", state = "To Do", assignee = "", tags = "",
    title = "Child" })
end)

test("the viewed item renders as its title, then one line per field", function()
  local text, _, widths = lines.render({
    { kind = "item", slot = "self", id = 101, type = "Task", state = "Active", assignee = "", tags = "", title = "Write the API" },
    { kind = "field", slot = "self", id = 101, field = "type", value = "Task" },
    { kind = "field", slot = "self", id = 101, field = "state", value = "Active" },
    { kind = "field", slot = "self", id = 101, field = "assignee", value = "Alex Smith" },
    { kind = "field", slot = "self", id = 101, field = "tags", value = "" },
    item(102, "Child"),
  }, { 1, 2, 3, 4, 5, 6 })
  eq(text, {
    "/1 Write the API",
    "/2   type:     Task",
    "/3   state:    Active",
    "/4   assignee: Alex Smith",
    "/5   tags:",
    "/6 Task │ To Do │ Child │  │",
  })
  eq(widths, { 4, 5, 5, 0, 0 })
  eq(lines.parse(text[1]), { row_id = 1, kind = "item", title = "Write the API" })
  eq(lines.parse(text[3]), { row_id = 3, kind = "field", field = "state", value = "Active" })
  eq(lines.parse(text[5]), { row_id = 5, kind = "field", field = "tags", value = "" })
end)
