-- Expansion in the item view (RFC 0001 R3.4): <Tab> inserts a child's own
-- children beneath it and removes them again, without redrawing the rest.
local seed = require("tests.fixtures.seed")
local views = require("tests.support.views")
local key, parsed, cursor_to = views.key, views.parsed, views.cursor_to

-- The seed plus a finished child of 101 and a grandchild under 106.
local function deeper()
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  d.items = {}
  for _, it in ipairs(seed.items) do table.insert(d.items, it) end
  table.insert(d.items, { id = 115, type = "Task", title = "Finished subtask", state = "Done",
    area = "P\\Team\\A", parent = 101, changed = "2026-10-12T09:00:00Z" })
  table.insert(d.items, { id = 116, type = "Task", title = "Fixture data", state = "To Do",
    area = "P\\Team\\A", parent = 106, changed = "2026-10-12T10:00:00Z" })
  return d
end

local function open(id)
  require("ado").item_view(id)
  return vim.api.nvim_get_current_buf()
end

local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

test("<Tab> inserts the child rows under the right row, indented; <Tab> again removes only them", function()
  local env = views.fresh({ seed = deeper() })
  local buf = open(100)
  local before = buffer_lines()
  local calls = #env.fake.calls
  local at = cursor_to("Add tests")
  key("<Tab>")
  eq(#env.fake.calls, calls + 1)
  eq(parsed(buf), { "Checkout story", "Parent: none", "P\\Team\\A", "Children: 2", "Write API", "Add tests",
    "Test fixtures", "Related: 1", "Payments story" })
  local inserted = buffer_lines()[at + 1]
  ok(inserted:find("^/%d+   Task%s+│"), inserted)
  for i = 1, at do eq(buffer_lines()[i], before[i], "line " .. i .. " is untouched") end
  eq(vim.bo[buf].modified, false)
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_view, 0, -1, {})
  eq(#marks, #buffer_lines(), "every line keeps its concealed prefix")
  key("<Tab>")
  eq(buffer_lines(), before)
  eq(#env.fake.calls, calls + 1, "collapse makes no call")
end)

test("collapsing an outer row removes the rows expanded beneath it too", function()
  views.fresh({ seed = deeper() })
  local buf = open(100)
  cursor_to("Add tests")
  key("<Tab>")
  cursor_to("Test fixtures")
  key("<Tab>")
  eq(parsed(buf), { "Checkout story", "Parent: none", "P\\Team\\A", "Children: 2", "Write API", "Add tests",
    "Test fixtures", "Fixture data", "Related: 1", "Payments story" })
  cursor_to("Add tests")
  key("<Tab>")
  eq(parsed(buf), { "Checkout story", "Parent: none", "P\\Team\\A", "Children: 2", "Write API", "Add tests",
    "Related: 1", "Payments story" })
end)

test("a child whose children are all finished says so; <leader>wt shows them in place", function()
  local env = views.fresh({ seed = deeper() })
  local buf = open(100)
  cursor_to("Write API")
  key("<Tab>")
  eq(#parsed(buf), 8)
  eq(env.echoes[#env.echoes], "#101 has no open children; <leader>wt shows all")
  local calls = #env.fake.calls
  key("<leader>wt")
  eq(parsed(buf), { "Checkout story", "Parent: none", "P\\Team\\A", "Children: 2", "Write API",
    "Finished subtask", "Add tests", "Related: 1", "Payments story" })
  eq(#env.fake.calls, calls)
end)

test("only child rows expand", function()
  local env = views.fresh()
  open(100)
  local calls = #env.fake.calls
  cursor_to("Payments story")
  key("<Tab>")
  eq(#env.fake.calls, calls)
  eq(env.notes[#env.notes].msg, "[ado] only child rows expand")
end)

test("going back to an item shows it collapsed", function()
  views.fresh({ seed = deeper() })
  local buf = open(100)
  cursor_to("Add tests")
  key("<Tab>")
  cursor_to("Write API")
  key("<CR>")
  key("[h")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(parsed(buf), { "Checkout story", "Parent: none", "P\\Team\\A", "Children: 2", "Write API", "Add tests",
    "Related: 1", "Payments story" })
end)
