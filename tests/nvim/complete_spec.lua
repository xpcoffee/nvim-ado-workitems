-- The Insert-mode menu of type and state cells (plan 0002 UX3.1, UX3.3 to
-- UX3.5). Keys are fed with nvim_feedkeys, which leaves Insert mode once
-- they run out, so <F2> (mapped below) reads the menu while it is open.
local lines = require("ado.nvim.lines")
local views = require("tests.support.views")
local cursor_to = views.cursor_to

local menu

local function setup(opts)
  local env = views.fresh(opts)
  -- Headless Neovim draws an 80 by 24 screen whatever 'columns' and
  -- 'lines' say, and a popup menu drawn outside it crashed a run. A window
  -- takes the new size only when the layout is rebuilt.
  vim.o.columns, vim.o.lines = 80, 24
  vim.cmd("vsplit")
  vim.cmd("only")
  vim.o.completeopt = "menu,menuone,noselect"
  menu = nil
  vim.keymap.set("i", "<F2>", function()
    local info = vim.fn.complete_info({ "items", "pum_visible" })
    menu = { visible = info.pum_visible == 1, words = {}, menus = {} }
    for _, it in ipairs(info.items) do
      table.insert(menu.words, it.word)
      table.insert(menu.menus, it.menu)
    end
  end)
  return env
end

local function key(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(10)
end

local function open_area(path)
  require("ado").area_view(path or "P/Team/A")
  return vim.api.nvim_get_current_buf()
end

-- Puts the cursor on the first byte of cell `index` of the row showing
-- title.
local function to_cell(title, index)
  local row = cursor_to(title)
  local ranges, offset = lines.row_ranges(vim.api.nvim_get_current_line())
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[index].first - 1 })
  return row
end

local function row_text(row)
  return lines.parse(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1])
end

test("UX3.1 <C-Space> in a state cell lists the states of the row's type, with their categories", function()
  setup()
  open_area()
  to_cell("Write API", 2)
  key("i<C-Space><F2><Esc>")
  ok(menu and menu.visible, "the menu is open")
  eq(menu.words, { "To Do", "Doing", "Done", "Discarded" })
  eq(menu.menus, { "Proposed", "InProgress", "Completed", "Removed" })
end)

test("UX3.1 the value picked replaces the state cell, from the cell's start", function()
  setup()
  local buf = open_area()
  local row = to_cell("Write API", 2)
  key("a<C-Space><C-n><C-n><C-y><Esc>")
  vim.wait(20)
  local p = row_text(row)
  eq({ p.type, p.state, p.title, p.assignee }, { "Task", "Doing", "Write API", "Me Myself" })
  ok(vim.bo[buf].modified)
end)

test("UX3.1 the menu narrows to the states starting with the text typed", function()
  setup()
  open_area()
  local row = to_cell("Write API", 2)
  key("cicD<C-Space><F2><Esc>")
  eq(menu.words, { "Doing", "Done", "Discarded" })
  eq(row_text(row).title, "Write API")
end)

test("UX3.1 a state cell follows a type typed on the line", function()
  setup()
  open_area()
  local row = to_cell("Write API", 1)
  key("ciwBug<Esc>")
  to_cell("Write API", 2)
  key("i<C-Space><F2><Esc>")
  eq(menu.words, { "New", "Active", "Resolved", "Closed" })
  eq(row_text(row).type, "Bug")
end)

test("UX3.1 <C-Space> in a type cell lists the project's configured types", function()
  setup({ projects = { { name = "P", types = { "Task", "Bug" } } } })
  open_area()
  to_cell("Write API", 1)
  key("i<C-Space><F2><Esc>")
  eq(menu.words, { "Task", "Bug" })
  eq(menu.menus, { "", "no state To Do" })
end)

test("UX3.1 <C-Space> on the item view's state: line lists its type's states", function()
  setup()
  require("ado").item_view(100)
  local row = cursor_to("state: Active")
  vim.api.nvim_win_set_cursor(0, { row, #vim.api.nvim_get_current_line() - 1 })
  key("a<C-Space><F2><Esc>")
  eq(menu.words, { "New", "Active", "Resolved", "Closed" })
end)

test("UX3.1 <C-Space> outside a type, state or assignee cell opens no menu and says what it does", function()
  local env = setup()
  open_area()
  to_cell("Write API", 3)
  key("i<C-Space><F2><Esc>")
  eq(menu.visible, false)
  eq(env.notes[#env.notes].msg, "[ado] <C-Space> lists the values of a type, state or assignee cell")
end)

test("UX3.1 a new line's state cell opens no menu and gives the save's reason", function()
  local env = setup()
  open_area()
  cursor_to("Write API")
  key("oTask │  │ A new line │  │<Esc>")
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ranges = lines.row_ranges(vim.api.nvim_get_current_line())
  vim.api.nvim_win_set_cursor(0, { row, ranges[2].from })
  key("a<C-Space><F2><Esc>")
  eq(menu.visible, false)
  eq(env.notes[#env.notes].msg, "[ado] " .. require("ado.core.choices").NEW_STATE)
end)

test("UX3.3 a project without configured types opens no type menu and names the setup() entry", function()
  local env = setup({ projects = { { name = "P" } } })
  open_area()
  to_cell("Write API", 1)
  key("i<C-Space><F2><Esc>")
  eq(menu.visible, false)
  local msg = env.notes[#env.notes].msg
  ok(msg:find('add them in setup(), for example projects = { { name = "P", types = { ... } } }', 1, true), msg)
end)

test("UX3.4 a catalog not loaded yet is loaded, and the menu opens if the cursor is still in the cell", function()
  local env = setup({ area_filters = { state = "all" } })
  open_area()
  local fake = env.fake
  fake.mode = "deferred"
  eq(require("ado.nvim.session").get():cached_catalog("P"), nil, "a view in every state loads no catalog")
  vim.keymap.set("i", "<F3>", function() fake:flush() end)
  to_cell("Write API", 2)
  key("i<C-Space><F2><Esc>")
  eq(menu.visible, false, "nothing to show until the catalog arrives")
  key("i<C-Space><F3><F2><Esc>")
  eq(menu.words, { "To Do", "Doing", "Done", "Discarded" })
  fake.mode = nil
end)

test("UX3.4 a catalog that arrives after the cursor left the cell opens no menu", function()
  local env = setup({ area_filters = { state = "all" } })
  open_area()
  local fake = env.fake
  fake.mode = "deferred"
  vim.keymap.set("i", "<F3>", function() fake:flush() end)
  to_cell("Write API", 2)
  key("i<C-Space><C-o>j<F3><F2><Esc>")
  eq(menu.visible, false)
  fake.mode = nil
end)

test("UX3.5 <C-x><C-u> opens the same menu through the buffer's completefunc", function()
  setup()
  local buf = open_area()
  eq(vim.bo[buf].completefunc, "v:lua.require'ado.nvim.complete'.completefunc")
  to_cell("Write API", 2)
  key("i<C-x><C-u><F2><Esc>")
  eq(menu.words, { "To Do", "Doing", "Done", "Discarded" })
end)

test("UX3.5 <C-Space> and <C-@> call complete() from a plain mapping, not an expression", function()
  setup()
  open_area()
  for _, lhs in ipairs({ "<C-Space>", "<C-@>", "<Nul>" }) do
    local m = vim.fn.maparg(lhs, "i", false, true)
    eq(m.buffer, 1, lhs .. " is buffer-local")
    eq(m.expr, 0, lhs .. " is not an expression mapping")
    ok(m.callback, lhs .. " calls Lua")
  end
end)

test("UX3.5 the views turn nvim-cmp off and ask blink.cmp to stay off", function()
  setup()
  local calls = {}
  package.loaded.cmp = { setup = { buffer = function(c)
    table.insert(calls, { buf = vim.api.nvim_get_current_buf(), config = c })
  end } }
  local ok_run, err = pcall(function()
    local buf = open_area()
    eq(vim.b[buf].completion, false)
    eq(calls, { { buf = buf, config = { enabled = false } } })
    local other = open_area("P/Team/B")
    eq(#calls, 2)
    eq(calls[2].buf, other)
  end)
  package.loaded.cmp = nil
  assert(ok_run, err)
end)

test("UX3.5 nvim-cmp loaded after the view opened is turned off on InsertEnter", function()
  setup()
  local buf = open_area()
  local calls = {}
  package.loaded.cmp = { setup = { buffer = function(c)
    table.insert(calls, { buf = vim.api.nvim_get_current_buf(), config = c })
  end } }
  local ok_run, err = pcall(function()
    key("i<Esc>")
    key("i<Esc>")
    eq(calls, { { buf = buf, config = { enabled = false } } }, "once per buffer")
  end)
  package.loaded.cmp = nil
  assert(ok_run, err)
end)

test("UX3.1 the menu starts at the cell's first byte, and colours each state where Neovim can", function()
  setup()
  vim.o.termguicolors = true
  open_area()
  local row = to_cell("Write API", 2)
  local ranges, offset = lines.row_ranges(vim.api.nvim_get_current_line())
  local complete, seen = vim.fn.complete, nil
  vim.fn.complete = function(start, items) seen = { start = start, items = items } end
  local ok_run, err = pcall(key, "i<C-Space><Esc>")
  vim.fn.complete = complete
  vim.o.termguicolors = false
  assert(ok_run, err)
  eq(seen.start, offset + ranges[2].first)
  eq(seen.items[2].word, "Doing")
  if vim.fn.has("nvim-0.11") == 1 then eq(seen.items[2].abbr_hlgroup, "AdoColor_007acc") end
  eq(row_text(row).state, "To Do")
end)
