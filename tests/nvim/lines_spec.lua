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
    "/8 108 │ Task       │ To Do  │ Same title │            │",
    "/12 109 │ User Story │ Active │ Same title │ Alex Smith │ api",
  })
  eq(prefixes, { 3, 3, 4 })
end)

test("parse reads back each column; duplicate titles stay apart by row ID", function()
  local text = lines.render({ item(108, "Same title"), item(109, "Same title", { tags = "a; b" }) }, { 1, 2 })
  eq(lines.parse(text[1]), { row_id = 1, kind = "item", shown_id = "108", type = "Task", state = "To Do",
    assignee = "", tags = "", title = "Same title" })
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

test("columns render as id, type, state, title, assignee, tags", function()
  local text = lines.render({ item(112, "Ship it", { assignee = "Alex Smith", tags = "api" }) }, { 1 })
  eq(text[1], "/1 112 │ Task │ To Do │ Ship it │ Alex Smith │ api")
  eq(lines.parse(text[1]), { row_id = 1, kind = "item", shown_id = "112", type = "Task", state = "To Do",
    assignee = "Alex Smith", tags = "api", title = "Ship it" })
end)

test("IDs of different lengths line up in one column, and a typed line's id cell is empty", function()
  local text = lines.render({ item(7, "Short id"), item(900033, "Long id"),
    { kind = "item", type = "Task", state = "", assignee = "", tags = "", title = "Typed" } }, { 1, 2, 3 })
  eq(text, {
    "/1 7      │ Task │ To Do │ Short id │  │",
    "/2 900033 │ Task │ To Do │ Long id  │  │",
    "/3        │ Task │       │ Typed    │  │",
  })
  eq(lines.parse(text[3]).shown_id, "")
  eq(lines.value({ id = 900033 }, "id"), "900033")
  eq(lines.value({}, "id"), "")
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
  rows[2].id = 30
  local text, prefixes, widths = lines.render(rows, { 7, 8 }, { 0, 10, 6, 0, 0, 0 })
  eq(text, { "/7 ── Children: 2 open of 3", "/8 30 │   Task     │ To Do  │ Child │  │" },
    "the indent is in the type column, so IDs line up")
  eq(prefixes, { 3, 3 })
  eq(widths, { 2, 10, 6, 5, 0, 0 })
  eq(lines.parse(text[1]), { row_id = 7, kind = "heading", label = "Children: 2 open of 3" })
  eq(lines.parse(text[2]), { row_id = 8, kind = "item", shown_id = "30", type = "Task", state = "To Do",
    assignee = "", tags = "", title = "Child" })
end)

test("the viewed item renders as its title, then one line per field", function()
  local text, _, widths = lines.render({
    { kind = "item", slot = "self", id = 101, type = "Task", state = "Active", assignee = "", tags = "", title = "Write the API" },
    { kind = "field", slot = "self", id = 101, field = "id", value = "101" },
    { kind = "field", slot = "self", id = 101, field = "type", value = "Task" },
    { kind = "field", slot = "self", id = 101, field = "state", value = "Active" },
    { kind = "field", slot = "self", id = 101, field = "assignee", value = "Alex Smith" },
    { kind = "field", slot = "self", id = 101, field = "tags", value = "" },
    item(102, "Child"),
  }, { 1, 2, 3, 4, 5, 6, 7 })
  eq(text, {
    "/1 Write the API",
    "/2   id:       101",
    "/3   type:     Task",
    "/4   state:    Active",
    "/5   assignee: Alex Smith",
    "/6   tags:",
    "/7 102 │ Task │ To Do │ Child │  │",
  })
  eq(widths, { 3, 4, 5, 5, 0, 0 })
  eq(lines.parse(text[1]), { row_id = 1, kind = "item", title = "Write the API" })
  eq(lines.parse(text[2]), { row_id = 2, kind = "field", field = "id", value = "101" })
  eq(lines.parse(text[4]), { row_id = 4, kind = "field", field = "state", value = "Active" })
  eq(lines.parse(text[6]), { row_id = 6, kind = "field", field = "tags", value = "" })
end)
