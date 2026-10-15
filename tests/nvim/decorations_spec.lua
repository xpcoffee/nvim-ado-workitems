-- Colour, change markers and counts in the views (plan 0002 UX2.1 to
-- UX2.7). Headless Neovim does not fire TextChanged after keys fed with
-- nvim_feedkeys (plan 0002 section 4), so change() fires it.
local lines = require("ado.nvim.lines")
local seed = require("tests.fixtures.seed")
local views = require("tests.support.views")
local cursor_to = views.cursor_to

local function change(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(10)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_get_current_buf() })
end

local function setup(opts)
  local env = views.fresh(opts)
  vim.o.termguicolors = true
  return env
end

local function open_area(path)
  require("ado").area_view(path or "P/Team/A")
  return vim.api.nvim_get_current_buf()
end

local function open_item(id)
  require("ado").item_view(id)
  return vim.api.nvim_get_current_buf()
end

local function marks(buf)
  local ns = vim.api.nvim_get_namespaces().ado_decorations
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

-- Per 1-based line: { type = group, dot = { text, group }, sign = text }.
local function decorations(buf)
  local out = {}
  for _, m in ipairs(marks(buf)) do
    local line = m[2] + 1
    out[line] = out[line] or {}
    local d = m[4]
    if d.hl_group then out[line].type = d.hl_group end
    if d.virt_text then out[line].dot = { d.virt_text[1][1], d.virt_text[1][2] } end
    if d.sign_text then out[line].sign = vim.trim(d.sign_text) end
  end
  return out
end

local function line_showing(text)
  return cursor_to(text)
end

local function item_lines(buf)
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if lines.row_ranges(l) then table.insert(out, i) end
  end
  return out
end

test("UX2.1 the Ado groups link to standard groups, by default, and come back after :colorscheme", function()
  setup()
  open_area()
  local links = { AdoType = "Type", AdoState = "Constant", AdoSeparator = "NonText", AdoAreaMark = "Directory",
    AdoHeading = "Title", AdoChanged = "Changed", AdoNew = "Added", AdoCount = "Comment" }
  for group, link in pairs(links) do eq(vim.api.nvim_get_hl(0, { name = group }).link, link, group) end
  vim.cmd("colorscheme default")
  for group, link in pairs(links) do eq(vim.api.nvim_get_hl(0, { name = group }).link, link, group .. " again") end
  eq(vim.api.nvim_get_hl(0, { name = "AdoColor_a4880a" }).fg, 0xa4880a, "the type colour again")
  vim.api.nvim_set_hl(0, "AdoType", { fg = "#123456" })
  require("ado.nvim.highlights").setup()
  eq(vim.api.nvim_get_hl(0, { name = "AdoType" }).fg, 0x123456, "a user's own colour is kept")
end)

test("UX2.2 the type cell takes its ADO colour, and a dot in the state's colour sits before the state", function()
  setup()
  local buf = open_area()
  local d = decorations(buf)
  local task = line_showing("Write API")
  eq(d[task].type, "AdoColor_a4880a")
  eq(d[task].dot, { "● ", "AdoColor_b2b2b2" })
  local story = line_showing("Checkout story")
  eq(d[story].type, "AdoColor_009ccc")
  eq(d[story].dot, { "● ", "AdoColor_007acc" })
  local issue = line_showing("Support issue")
  eq(d[issue].type, "AdoType", "a type without a colour")
  eq(d[issue].dot[2], "AdoState", "a state without a colour")
  for _, l in ipairs(item_lines(buf)) do ok(d[l] and d[l].dot, "line " .. l .. " has a dot") end
  local mark = vim.tbl_filter(function(m) return m[2] + 1 == task and m[4].hl_group end, marks(buf))[1]
  local line = vim.api.nvim_buf_get_lines(buf, task - 1, task, false)[1]
  eq(line:sub(mark[3] + 1, mark[4].end_col), "Task", "the colour covers the type name only")
end)

test("UX2.2 without termguicolors the cells use AdoType and AdoState", function()
  setup()
  vim.o.termguicolors = false
  local buf = open_area()
  local d = decorations(buf)
  local task = line_showing("Write API")
  eq(d[task].type, "AdoType")
  eq(d[task].dot[2], "AdoState")
end)

test("UX2.2 in the item view: the state: line has a dot, child rows are coloured, an expanded row too", function()
  setup()
  local buf = open_item(100)
  local d = decorations(buf)
  local state_line = line_showing("state: Active")
  eq(d[state_line].dot, { "● ", "AdoColor_007acc" })
  eq(d[line_showing("type: User Story")].type, "AdoColor_009ccc")
  local child = line_showing("Add tests")
  eq(d[child].type, "AdoColor_a4880a")
  views.key("<Tab>")
  d = decorations(buf)
  local grandchild = line_showing("Test fixtures")
  eq(d[grandchild].type, "AdoColor_a4880a")
  local line = vim.api.nvim_buf_get_lines(buf, grandchild - 1, grandchild, false)[1]
  local mark = vim.tbl_filter(function(m) return m[2] + 1 == grandchild and m[4].hl_group end, marks(buf))[1]
  eq(line:sub(mark[3] + 1, mark[4].end_col), "Task", "the indent is not coloured")
  eq(d[grandchild].sign, nil, "an expansion is not an edit")
end)

test("UX2.2 a state typed over takes its colour; one the type lacks falls back to AdoState", function()
  setup()
  local buf = open_area()
  local row = line_showing("Write API")
  local ranges, offset = lines.row_ranges(vim.api.nvim_get_current_line())
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[2].first - 1 })
  change("c2eDoing<Esc>")
  eq(lines.parse(vim.api.nvim_get_current_line()).state, "Doing")
  eq(decorations(buf)[row].dot[2], "AdoColor_007acc")
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[2].first - 1 })
  change("ceBogus<Esc>")
  eq(decorations(buf)[row].dot[2], "AdoState")
end)

test("UX2.4 ~ marks an edited row, and goes after u", function()
  setup()
  local buf = open_area()
  local row = line_showing("Write API")
  change("A more<Esc>")
  ok(lines.parse(vim.api.nvim_get_current_line()).tags:find("more"), "the edit reached the tags")
  eq(decorations(buf)[row].sign, "~")
  local others = 0
  for l, d in pairs(decorations(buf)) do if l ~= row and d.sign then others = others + 1 end end
  eq(others, 0, "no other line is marked")
  change("u")
  eq(decorations(buf)[row].sign, nil)
end)

test("UX2.4 whitespace and a re-pad alone mark nothing", function()
  setup()
  local buf = open_area()
  local row = line_showing("Write API")
  local ranges, offset = lines.row_ranges(vim.api.nvim_get_current_line())
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[3].last })
  change("a   <Esc>")
  eq(decorations(buf)[row].sign, nil)
end)

test("UX2.4 + marks a typed new line and a row pasted from another view", function()
  setup()
  open_area("P/Team/A")
  cursor_to("Write API")
  change("yy")
  local b = open_area("P/Team/B")
  change("Gp")
  local pasted = vim.api.nvim_win_get_cursor(0)[1]
  eq(decorations(b)[pasted].sign, "+")
  change("oA new task<Esc>")
  local typed = vim.api.nvim_win_get_cursor(0)[1]
  eq(decorations(b)[typed].sign, "+")
  change("o<Esc>")
  eq(decorations(b)[typed + 1], nil, "an empty line is not marked")
end)

test("UX2.4 a second copy of a row within one view is marked +, the first is not", function()
  setup()
  local buf = open_area()
  local row = line_showing("Write API")
  change("yyp")
  local d = decorations(buf)
  eq(d[row].sign, nil)
  eq(d[row + 1].sign, "+")
end)

test("UX2.5 the window bar counts edited, new and removed rows on the right", function()
  setup()
  local buf = open_area()
  local base = vim.wo.winbar
  ok(base:find("%=%#AdoCount#0 sub-areas · 6 items%*", 1, true), base)
  line_showing("Write API")
  change("A x<Esc>")
  line_showing("Fix login")
  change("dd")
  change("oNew one<Esc>")
  ok(vim.endswith(vim.wo.winbar, "6 items · 1 edited · 1 new · 1 removed%*"), vim.wo.winbar)
  change("u")
  change("u")
  change("u")
  eq(vim.wo.winbar, base)
  eq(vim.bo[buf].modified, false)
end)

test("UX2.5 the item view and the query list count their rows and edits", function()
  setup()
  open_item(100)
  ok(vim.wo.winbar:find("children and links: open only (<leader>wt for all)%=%#AdoCount#2 children · 1 linked%*",
    1, true), vim.wo.winbar)
  line_showing("Add tests")
  change("A x<Esc>")
  ok(vim.endswith(vim.wo.winbar, "2 children · 1 linked · 1 edited%*"), vim.wo.winbar)
  require("ado").my_items()
  vim.wait(20)
  local buf = vim.api.nvim_get_current_buf()
  ok(vim.wo.winbar:find("%=%#AdoCount#4 items%*", 1, true), vim.wo.winbar)
  local d = decorations(buf)
  local row = line_showing("Write API")
  eq(d[row].type, "AdoColor_a4880a", "the query list is coloured too")
end)

test("UX2.5 a % in the location is shown as itself in the window bar", function()
  local s = vim.deepcopy(seed)
  table.insert(s.areas, "P\\Team\\50% done")
  table.insert(s.items, { id = 140, type = "Task", title = "Half", state = "To Do", area = "P\\Team\\50% done",
    changed = "2026-10-11T09:00:00Z" })
  setup({ seed = s })
  open_area("P/Team/50% done")
  ok(vim.startswith(vim.wo.winbar, "P\\Team\\50%% done  ·  "), "escaped once: " .. vim.wo.winbar)
end)

test("UX2.6 a view in every state loads its project's catalog once, then colours its rows", function()
  local env = setup({ area_filters = { state = "all" } })
  local buf = open_area()
  vim.wait(50, function() return env.fake.counts.work_item_types ~= nil end)
  eq(env.fake.counts.work_item_types, 1)
  eq(decorations(buf)[line_showing("Write API")].type, "AdoColor_a4880a")
  open_area("P/Team/B")
  vim.wait(20)
  eq(env.fake.counts.work_item_types, 1, "kept for the session")
end)

test("UX2.7 icons come from setup; one wider than a column keeps its default and warns once", function()
  local env = setup({ ui = { icons = { state = "*", changed = "!!" } } })
  local buf = open_area()
  local row = line_showing("Write API")
  eq(decorations(buf)[row].dot[1], "* ")
  change("A x<Esc>")
  eq(decorations(buf)[row].sign, "~")
  change("A y<Esc>")
  local warnings = vim.tbl_filter(function(n) return n.msg:find("ui.icons", 1, true) end, env.notes)
  eq(#warnings, 1)
  ok(warnings[1].msg:find("changed must be one column wide", 1, true), warnings[1].msg)
end)

test("UX2.3 separators, sub-area rows and headings are drawn by syntax groups", function()
  setup()
  local item = open_item(100)
  local function group_at(text, needle)
    local row = line_showing(text)
    local col = vim.api.nvim_get_current_line():find(needle, 1, true)
    return vim.fn.synIDattr(vim.fn.synID(row, col, 1), "name")
  end
  eq(vim.b[item].current_syntax, "adoitem")
  eq(group_at("Add tests", "│"), "AdoSeparator")
  eq(group_at("Children: 2", "Children"), "AdoHeading")
  eq(group_at("P\\Team\\A", "▸"), "AdoAreaMark")
  local area = open_area("P/Team")
  eq(vim.b[area].current_syntax, "adoarea")
  eq(group_at("A", "▸"), "AdoAreaMark")
end)

test("UX2.4 the views keep a one-column sign column", function()
  setup()
  open_area()
  eq(vim.wo.signcolumn, "yes:1")
end)
