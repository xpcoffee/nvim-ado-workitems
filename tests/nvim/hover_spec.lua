-- The full-row float on a cut cell (plan 0002 UX4.4). Headless Neovim
-- fires CursorMoved only when it waits for keys, so each spec fires it
-- after moving the cursor, as the editor does.
local hover = require("ado.nvim.hover")
local lines = require("ado.nvim.lines")
local views = require("tests.support.views")

local function setup()
  local env = views.fresh({ seed = require("tests.fixtures.long_seed") })
  vim.o.columns, vim.o.lines = 80, 24
  vim.cmd("vsplit")
  vim.cmd("only")
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, 60)
  hover.delay = 10
  require("ado").area_view("P/Team/A")
  return env, vim.api.nvim_get_current_buf()
end

local function line_of(buf, id)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local rid = tonumber(l:match("^/(%d+) "))
    local reg = rid and require("ado.nvim.registry").get(rid)
    if reg and reg.row.kind == "item" and reg.row.id == id then return i end
  end
end

local function rest_on(buf, id, index)
  local row = line_of(buf, id)
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local ranges, offset = lines.row_ranges(line)
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[index].first - 1 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  vim.wait(100, function() return hover.window() ~= nil end)
end

test("UX4.4 resting on a cut title opens the full row beside the cursor, without focus", function()
  local _, buf = setup()
  local win = vim.api.nvim_get_current_win()
  rest_on(buf, 103, 3)
  local float = hover.window()
  ok(float, "a float opened")
  eq(vim.api.nvim_get_current_win(), win, "the cursor stays in the view")
  eq(vim.api.nvim_win_get_config(float).focusable, false)
  local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)
  eq(text[1], "#103  Task · To Do")
  eq(text[2], "title     Fix login redirect loop after the session token refresh on mobile")
  eq(text[3], "assignee  Me Myself <me@example.com>")
  hover.close()
end)

test("UX4.4 a type shown as a letter, or a row with hidden tags, opens it too; a cell shown whole does not", function()
  local _, buf = setup()
  rest_on(buf, 100, 1)
  ok(hover.window(), "the letter S of a User Story")
  hover.close()
  rest_on(buf, 101, 2)
  ok(hover.window(), "a row whose tags are hidden")
  local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(hover.window()), 0, -1, false)
  eq(text[4], "tags      api; backend; checkout; documentation")
  hover.close()
  rest_on(buf, 100, 2)
  eq(hover.window(), nil, "the state of a row shown in full")
end)

test("UX4.4 the float closes when the cursor moves or Insert mode starts", function()
  local _, buf = setup()
  rest_on(buf, 103, 3)
  ok(hover.window())
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  eq(hover.window(), nil)
  rest_on(buf, 103, 3)
  ok(hover.window())
  vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
  eq(hover.window(), nil)
end)

test("UX4.4 the float waits for the cursor to rest", function()
  local _, buf = setup()
  hover.delay = 200
  rest_on(buf, 103, 3)
  vim.wait(20)
  eq(hover.window(), nil, "not before the delay")
  vim.wait(300, function() return hover.window() ~= nil end)
  ok(hover.window(), "after it")
  hover.close()
  hover.delay = 300
end)
