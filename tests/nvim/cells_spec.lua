-- The `ic` and `ac` cell text objects (plan 0002 UX1.7).
local lines = require("ado.nvim.lines")
local seed = require("tests.fixtures.seed")
local views = require("tests.support.views")
local cursor_to = views.cursor_to

local function key(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(10)
end

local function current_line()
  return vim.api.nvim_get_current_line()
end

local function open_area(path)
  require("ado").area_view(path or "P/Team/A")
  return vim.api.nvim_get_current_buf()
end

local function open_item(id)
  require("ado").item_view(id)
  return vim.api.nvim_get_current_buf()
end

-- Puts the cursor on byte `at` (1-based) of cell `column` of the row
-- showing title; at defaults to the cell's first byte.
local function to_cell(title, column, at)
  local row = cursor_to(title)
  local ranges, offset = lines.row_ranges(current_line())
  local index = require("ado.core.table_layout").INDEX[column]
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[index].first - 1 + (at or 1) - 1 })
  return row
end

-- The text `vic` or `vac` selects on the cursor line.
local function selected(object)
  key("v" .. object .. "<Esc>")
  local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local line = current_line()
  local last = e[3]
  while last < #line and line:byte(last + 1) >= 0x80 and line:byte(last + 1) < 0xC0 do last = last + 1 end
  return line:sub(s[3], last)
end

local function with_items(change)
  local data = {}
  for k, v in pairs(seed) do data[k] = v end
  data.items = {}
  for _, it in ipairs(seed.items) do table.insert(data.items, change(vim.deepcopy(it)) or it) end
  return data
end

test("UX1.7 cic on an assignee replaces the whole name", function()
  views.fresh()
  open_area()
  local row = to_cell("Add tests", "assignee", 7)
  key("cicMe Myself<Esc>")
  eq(lines.parse(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]).assignee, "Me Myself")
end)

test("UX1.7 ic selects the trimmed text of each cell, ac adds its padding and separator", function()
  views.fresh()
  open_area()
  to_cell("Write API", "id")
  eq(selected("ic"), "101")
  eq(selected("ac"), "101 │ ", "the first cell takes the separator after it and one space")
  to_cell("Write API", "type")
  eq(selected("ic"), "Task")
  eq(selected("ac"), " Task       │")
  to_cell("Write API", "state", 3)
  eq(selected("ic"), "To Do")
  eq(selected("ac"), " To Do  │")
  to_cell("Write API", "title")
  eq(selected("ic"), "Write API")
  to_cell("Write API", "tags", 4)
  eq(selected("ic"), "api; backend")
  eq(selected("ac"), "  │ api; backend", "the last cell takes the separator before it, as aw does")
end)

test("UX1.7 dac removes a cell and its separator", function()
  views.fresh()
  open_area()
  local row = to_cell("Write API", "state")
  key("dac")
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  eq(line:match("^/%d+ (.*)$"), "101 │ Task       │ Write API      │ Me Myself  │ api; backend")
end)

test("UX1.7 a title holding the separator is one cell", function()
  views.fresh({ seed = with_items(function(it) if it.id == 103 then it.title = "x │ y │ z" return it end end) })
  open_area()
  local row = to_cell("x │ y │ z", "title", 3)
  eq(selected("ic"), "x │ y │ z")
  key("cicLogin fixed<Esc>")
  eq(lines.parse(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]).title, "Login fixed")
end)

test("UX1.7 on a child row ic leaves out the indent", function()
  views.fresh()
  open_item(100)
  cursor_to("Add tests")
  key("<Tab>")
  to_cell("Test fixtures", "type", 3)
  eq(selected("ic"), "Task")
  to_cell("Test fixtures", "id")
  eq(selected("ic"), "106", "the indent is in the type column, not the id column")
end)

test("UX1.7 on a field line the cell is the value; on the item's own title line it is the whole title", function()
  views.fresh({ seed = with_items(function(it) if it.id == 100 then it.title = "a │ b │ c │ d │ e" return it end end) })
  local buf = open_item(100)
  cursor_to("state: Active")
  vim.cmd("normal! $")
  eq(selected("ic"), "Active")
  key("cicClosed<Esc>")
  ok(vim.tbl_contains(views.shown(buf), "state: Closed"))
  vim.api.nvim_win_set_cursor(0, { 1, #"/" + 3 })
  eq(selected("ic"), "a │ b │ c │ d │ e")
  key("cicNew title<Esc>")
  eq(lines.body(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]), "New title")
end)

test("UX1.7 on an empty cell ic selects its padding, so cic inserts at the cell start", function()
  views.fresh()
  open_area()
  local row = to_cell("Support issue", "assignee")
  key("cicAlex Smith<Esc>")
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  eq(lines.parse(line).assignee, "Alex Smith")
  ok(line:find("│ Alex Smith", 1, true), line)
end)

test("UX1.7 on a sub-area or heading row the object selects nothing", function()
  views.fresh()
  open_area("P/Team")
  local before = current_line()
  ok(lines.parse(before).kind == "area", before)
  key("dic")
  eq(current_line(), before)
  key("dac")
  eq(current_line(), before)
  views.fresh()
  open_item(100)
  cursor_to("Children: 2")
  before = current_line()
  key("dic")
  eq(current_line(), before)
  eq(vim.bo.modified, false)
end)

test("UX1.7 . repeats cic on another row", function()
  views.fresh()
  local buf = open_area()
  to_cell("Fix login", "assignee")
  key("cicAlex Smith<Esc>")
  to_cell("Write API", "assignee", 4)
  key(".")
  local assignees = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local p = lines.parse(l)
    assignees[p.title] = p.assignee
  end
  eq(assignees["Fix login"], "Alex Smith")
  eq(assignees["Write API"], "Alex Smith")
end)
