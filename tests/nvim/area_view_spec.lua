-- The area view buffer on the fake transport: rendering, navigation,
-- filters, the sub-area toggle, :w and the browser URL. Selecting an item
-- is in layout_spec.lua.
local Fake = require("tests.support.fake_transport")
local seed = require("tests.fixtures.seed")
local lines = require("ado.nvim.lines")

local function key(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local opened_urls

local function fresh(opts)
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  local fake = Fake.new(seed)
  local c = { transport = fake, org = "test-org", project = "P", projects = false, write_guard = false,
    area_paths = { "P/Team", "P\\Team\\B" }, area_filters = { state = "open" } }
  for k, v in pairs(opts or {}) do c[k] = v end
  require("ado.config").setup(c)
  require("ado.nvim.session").reset()
  for _, m in ipairs({ "ado.nvim.area_view", "ado.nvim.item_view", "ado.nvim.layout" }) do package.loaded[m] = nil end
  local executable = vim.fn.executable
  vim.fn.executable = function(name)
    if name == "pandoc" then return 0 end
    return executable(name)
  end
  local notes = {}
  vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
  require("ado.nvim.progress").echo = function() end
  opened_urls = {}
  vim.ui.open = function(url) table.insert(opened_urls, url) end
  return fake, require("ado.nvim.area_view"), notes
end

local function parsed(buf)
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)) do
    local p = lines.parse(l)
    table.insert(out, p.kind == "area" and p.name or p.title)
  end
  return out
end

local function cursor_to(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local p = lines.parse(l)
    if (p.kind == "area" and p.name or p.title) == text then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  error("no row " .. text)
end

local function open(path)
  require("ado").area_view(path)
  return vim.api.nvim_get_current_buf()
end

test("the view of P/Team lists its sub-areas in an editable acwrite buffer named by its location", function()
  local fake = fresh()
  local buf = open("P/Team")
  eq(vim.api.nvim_buf_get_name(buf), "ado://area/P/Team?state=open&type=&assignee=&tag=&sub=0")
  eq(parsed(buf), { "A", "B", "C", "D" })
  eq(vim.bo[buf].buftype, "acwrite")
  eq(vim.bo[buf].modifiable, true)
  eq(vim.wo.conceallevel, 2)
  eq(vim.wo.winbar, "P\\Team  ·  state: open  ·  assignee: any  ·  type: any  ·  tag: any"
    .. "  ·  sub-areas: excluded  ·  4 sub-areas, 0 items")
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
  eq(#marks, 4)
  eq(marks[1][4].conceal, "")
  eq(#fake.calls, 3, "area_children, catalog, query")
end)

test("<CR> on a sub-area enters it with the filters; [h and ]h walk back and forward without reloading", function()
  local fake, area_view = fresh()
  open("P/Team")
  area_view.open(require("ado.core.location").with_filters(area_view.state(0).location, { assignee = "@Me" }))
  cursor_to("A")
  key("<CR>")
  local buf = vim.api.nvim_get_current_buf()
  eq(area_view.state(buf).location.path, "P\\Team\\A")
  eq(area_view.state(buf).location.filters.assignee, "@Me")
  eq(parsed(buf), { "Fix login", "Write API", "Checkout story" })
  local calls = #fake.calls
  key("[h")
  eq(area_view.state(0).location.path, "P\\Team")
  eq(area_view.state(0).location.filters.assignee, "@Me")
  key("]h")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(#fake.calls, calls)
end)

test("- goes to the parent area, and stops at the project's root area", function()
  local _, area_view, notes = fresh()
  open("P/Team/B")
  key("-")
  eq(area_view.state(0).location.path, "P\\Team")
  key("-")
  eq(area_view.state(0).location.path, "P")
  key("-")
  eq(area_view.state(0).location.path, "P")
  eq(notes[#notes].msg, "[ado] already at the project's root area")
end)

test("<leader>wu toggles items of sub-areas", function()
  local _, area_view = fresh()
  open("P/Team")
  key("<leader>wu")
  local loc = area_view.state(0).location
  eq(loc.sub, true)
  ok(vim.api.nvim_buf_get_name(0):find("sub=1$"))
  eq(#area_view.state(0).view.items, 12, "15 seed items, 3 finished")
end)

test("<leader>wf sets a filter and the window bar shows it", function()
  local _, area_view = fresh()
  open("P/Team/A")
  vim.ui.select = function(_, _, choose) choose("types") end
  vim.ui.input = function(o, answer)
    eq(o.default, "")
    answer("Task, User Story")
  end
  key("<leader>wf")
  eq(area_view.state(0).location.filters.types, { "Task", "User Story" })
  eq(parsed(0), { "Test fixtures", "Fix login", "Add tests", "Write API", "Checkout story" })
  ok(vim.wo.winbar:find("type: Task, User Story", 1, true), vim.wo.winbar)
end)

test(":w with no edits sends nothing and says so", function()
  local fake, _, notes = fresh()
  open("P/Team/A")
  vim.cmd("write")
  vim.wait(20)
  eq(#fake.writes, 0)
  eq(notes[#notes].msg, "[ado] no unsaved edits in the views")
end)

test("<leader>wb opens the view's query; <leader>wr reloads with 2 calls", function()
  local fake = fresh()
  open("P/Team/A")
  key("<leader>wb")
  eq(#opened_urls, 1)
  ok(opened_urls[1]:find("^https://dev%.azure%.com/test%-org/P/_queries/query/%?wiql=SELECT"), opened_urls[1])
  local calls = #fake.calls
  key("<leader>wr")
  eq(#fake.calls, calls + 2)
end)

test("area_view() offers the configured paths in a picker", function()
  local _, area_view = fresh()
  vim.ui.select = function(items, o, choose)
    eq(items, { "P/Team", "P\\Team\\B" })
    eq(o.prompt, "Area")
    choose(items[2])
  end
  require("ado").area_view()
  eq(area_view.state(0).location.path, "P\\Team\\B")
end)

test("a failed load says so in the window bar", function()
  local fake, area_view = fresh()
  fake:fail_on("area_children", 1)
  open("P/Team")
  ok(vim.wo.winbar:find("load failed", 1, true), vim.wo.winbar)
  eq(area_view.state(0).view, nil)
end)
