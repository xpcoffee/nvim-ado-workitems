-- Fitting the views to their window (plan 0002 phase 5, option T): long
-- cells are cut in the buffer, the save restores their full values, and
-- a cell it cannot restore rejects the save with nothing sent. Headless
-- Neovim draws an 80-column screen, so each spec lays the windows out
-- inside it (plan 0002 section 4), and fires TextChanged itself after keys.
local fit = require("ado.nvim.fit")
local lines = require("ado.nvim.lines")
local C = require("ado.core.table_layout").INDEX
local screen = require("tests.support.screen")
local views = require("tests.support.views")

local LONG = {
  [101] = "Write the public API for the checkout service and document every endpoint",
  [102] = "Add integration tests for the payment provider callbacks and retries",
  [103] = "Fix login redirect loop after the session token refresh on mobile",
}

local function buffer_lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

local function change(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(10)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_get_current_buf() })
end

-- A fresh editor whose current window is `width` columns wide.
local function setup(width)
  local env = views.fresh({ seed = require("tests.fixtures.long_seed"), audit_log = vim.fn.tempname() })
  vim.o.columns, vim.o.lines = 80, 24
  vim.cmd("vsplit")
  vim.cmd("only")
  if width and width < 80 then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, width)
  end
  env.summaries = {}
  require("ado.nvim.save").confirm = function(text, can_apply, cb)
    local out = {}
    for _, l in ipairs(text) do table.insert(out, l.text) end
    table.insert(env.summaries, { lines = out, can_apply = can_apply })
    cb(env.answer)
  end
  return env
end

local function open_area(path)
  require("ado").area_view(path or "P/Team/A")
  return vim.api.nvim_get_current_buf()
end

-- The line (1-based) whose row shows work item id.
local function line_of(buf, id)
  for i, l in ipairs(buffer_lines(buf)) do
    local rid = tonumber(l:match("^/(%d+) "))
    local reg = rid and require("ado.nvim.registry").get(rid)
    if reg and reg.row.kind == "item" and reg.row.id == id then return i end
  end
  error("no row for #" .. id)
end

-- The values the save reads from a line.
local function values(buf, id)
  return fit.read(buffer_lines(buf)[line_of(buf, id)])
end

-- Puts the cursor on byte `offset` (0-based) of cell `index` (table_layout.INDEX) of item id's
-- row.
local function to_cell(buf, id, index, offset)
  local row = line_of(buf, id)
  local line = buffer_lines(buf)[row]
  local ranges, prefix = lines.row_ranges(line)
  vim.api.nvim_win_set_cursor(0, { row, prefix + ranges[index].first - 1 + (offset or 0) })
  return row
end

local function save(env, buf, answer)
  env.answer = answer
  vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  vim.wait(30)
  return env.summaries[#env.summaries]
end

-- The width a line takes towards sideways scrolling: its text including
-- the concealed prefix, and the state dot.
local function scroll_width(line)
  return vim.fn.strdisplaywidth(line) + (lines.row_ranges(line) and 2 or 0)
end

local function text_width(win)
  local info = vim.fn.getwininfo(win or vim.api.nvim_get_current_win())[1]
  return info.width - info.textoff
end

-- The id column takes 6 columns for the seed's 3-digit IDs; 66 leaves
-- room for a row ID prefix of up to 5 digits, which grows with the specs
-- run before this one.
test("UX4.1 rows fit 66 and 78 column windows, and $ on every row leaves the window unscrolled", function()
  for _, width in ipairs({ 66, 78 }) do
    setup(width)
    local buf = open_area()
    local tw = text_width()
    for i, line in ipairs(buffer_lines(buf)) do
      ok(scroll_width(line) < tw, string.format("%d columns, line %d is %d wide: %s", width, i, scroll_width(line), line))
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! $")
      eq(vim.fn.winsaveview().leftcol, 0, width .. " columns, $ on line " .. i)
    end
    local cols
    for _, row in ipairs(screen.rows(0)) do
      if row:find("│") then
        local found = screen.columns(row, "│")
        if cols then eq({ unpack(found, 1, 3) }, { unpack(cols, 1, 3) }, width .. " columns: " .. row) end
        cols = found
      end
    end
  end
end)

test("UX4.1 a 40 column window keeps the title at 20 and shows types as letters", function()
  setup(40)
  local buf = open_area()
  local r = values(buf, 103)
  eq(r.cells[C.type].text, "T")
  eq(r.values.type, "Task", "the letter stands for the type")
  eq(vim.fn.strdisplaywidth(r.cells[C.title].text), 20)
  eq(r.values.title, LONG[103])
  eq(fit.read(buffer_lines(buf)[line_of(buf, 100)]).cells[C.type].text, "S", "User Story shows as S")
end)

test("UX4.2 type letters come from setup", function()
  local env = setup(40)
  require("ado.config").setup({ ui = { type_letters = { ["User Story"] = "U" } } })
  local buf = open_area()
  eq(values(buf, 100).cells[C.type].text, "U")
  ok(env)
end)

test("UX5.1 x in a cut title, then :w plans the full title with one letter removed, shown in full", function()
  local env = setup(60)
  local buf = open_area()
  local before = values(buf, 103).cells[C.title].text
  ok(before:find("…", 1, true), before)
  to_cell(buf, 103, C.title, 0)
  change("x")
  local r = values(buf, 103)
  eq(r.values.title, LONG[103]:sub(2))
  ok(r.cells[C.title].text:find("…", 1, true), "cut again: " .. r.cells[C.title].text)
  local writes = #env.fake.writes
  local s = save(env, buf, false)
  eq(s.can_apply, true)
  eq(s.lines[3], "  #103 title: '" .. LONG[103] .. "' -> '" .. LONG[103]:sub(2) .. "'",
    "the summary shows the whole title before y")
  eq(#env.fake.writes, writes)
end)

test("UX5.1 u and <C-r> across edits of a cut title find the right full value each time", function()
  setup(60)
  local buf = open_area()
  to_cell(buf, 103, C.title, 0)
  local states = { { lines = buffer_lines(buf), title = LONG[103] } }
  change("x")
  table.insert(states, { lines = buffer_lines(buf), title = LONG[103]:sub(2) })
  change("x")
  table.insert(states, { lines = buffer_lines(buf), title = LONG[103]:sub(3) })
  change("iXY<Esc>")
  table.insert(states, { lines = buffer_lines(buf), title = "XY" .. LONG[103]:sub(3) })
  for i = #states - 1, 1, -1 do
    change("u")
    eq(buffer_lines(buf), states[i].lines, "u to state " .. i)
    eq(values(buf, 103).values.title, states[i].title, "u to state " .. i)
  end
  eq(vim.bo[buf].modified, false)
  for i = 2, #states do
    change("<C-r>")
    eq(values(buf, 103).values.title, states[i].title, "<C-r> to state " .. i)
  end
end)

test("UX5.1 Insert mode in a cut title keeps its hidden part and cuts it again, in one undo step", function()
  setup(60)
  local buf = open_area()
  local loaded = buffer_lines(buf)
  to_cell(buf, 102, C.title, 4)
  change("iworking <Esc>")
  eq(values(buf, 102).values.title, "Add working integration tests for the payment provider callbacks and retries")
  local line = buffer_lines(buf)[line_of(buf, 102)]
  eq(vim.fn.strdisplaywidth(line), vim.fn.strdisplaywidth(loaded[line_of(buf, 102)]), "cut again to its column")
  change("u")
  eq(buffer_lines(buf), loaded)
end)

test("UX5.4 deleting the … rejects the save, naming the row, and nothing is sent", function()
  local env = setup(60)
  local buf = open_area()
  local row = line_of(buf, 103)
  local cell = values(buf, 103).cells[C.title]
  vim.api.nvim_win_set_cursor(0, { row, cell.last - #"…" })
  change("x")
  eq(values(buf, 103).ambiguous, { "title" })
  local writes, calls = #env.fake.writes, #env.fake.calls
  local s = save(env, buf, true)
  eq(s.can_apply, false)
  eq(s.lines[1], "Save rejected: 1 problem, nothing will be sent")
  ok(s.lines[3]:find("#103 (line " .. row .. ")", 1, true), s.lines[3])
  ok(s.lines[3]:find("the title was cut to fit the window and the … was edited", 1, true), s.lines[3])
  eq(#env.fake.writes, writes, "nothing was written")
  eq(#env.fake.calls, calls, "no call at all")
  eq(vim.bo[buf].modified, true, "the view keeps its edit")
  change("u")
  eq(values(buf, 103).ambiguous, nil, "u restores a cell with a known value")
end)

test("UX5.4 an edit made from an undo state the re-pad never saw cannot be restored, and rejects", function()
  local env = setup(60)
  local buf = open_area()
  to_cell(buf, 103, C.title, 0)
  change("x")
  -- A `u` whose TextChanged never fired, then an edit of the cut title:
  -- the text before that edit is not the one the re-pad last saw, so the
  -- hidden part of the title is not known for sure.
  vim.cmd("undo")
  to_cell(buf, 103, C.title, 1)
  change("x")
  eq(values(buf, 103).ambiguous, { "title" })
  local writes = #env.fake.writes
  local s = save(env, buf, true)
  eq(s.can_apply, false)
  ok(s.lines[3]:find("the title was cut", 1, true), s.lines[3])
  eq(#env.fake.writes, writes)
end)

test("UX5.3 cic on a cut title takes the text typed as the whole title", function()
  local env = setup(60)
  local buf = open_area()
  to_cell(buf, 103, C.title, 2)
  change("cicMend login<Esc>")
  eq(values(buf, 103).values.title, "Mend login")
  eq(values(buf, 103).ambiguous, nil)
  local s = save(env, buf, false)
  eq(s.lines[3], "  #103 title: '" .. LONG[103] .. "' -> 'Mend login'")
end)

test("UX5.3 a value written by <leader>we replaces a cut cell whole", function()
  setup(60)
  local buf = open_area()
  local row = line_of(buf, 101)
  require("ado.nvim.cells").write(buf, { row }, C.tags, "release")
  require("ado.nvim.realign").run(buf)
  eq(values(buf, 101).values.tags, "release")
  eq(values(buf, 101).ambiguous, nil)
end)

test("UX5.2 <leader>wx shows a cut title in full; an edit at its end saves, and u cuts it again", function()
  local env = setup(60)
  local buf = open_area()
  local loaded = buffer_lines(buf)
  to_cell(buf, 103, C.title, 0)
  vim.g.mapleader = "\\"
  require("ado.nvim.reveal").show(false)
  local r = values(buf, 103)
  eq(r.cells[C.title].text, LONG[103])
  vim.api.nvim_win_set_cursor(0, { line_of(buf, 103), r.cells[C.title].last - 1 })
  change("x")
  eq(values(buf, 103).cells[C.title].text, LONG[103]:sub(1, -2), "shown in full, not cut again")
  eq(values(buf, 103).values.title, LONG[103]:sub(1, -2))
  local s = save(env, buf, false)
  eq(s.lines[3], "  #103 title: '" .. LONG[103] .. "' -> '" .. LONG[103]:sub(1, -2) .. "'")
  change("u")
  change("u")
  eq(buffer_lines(buf), loaded)
end)

test("UX5.2 <leader>wx on a cell whose … was edited shows the title it was loaded with", function()
  local env = setup(60)
  local buf = open_area()
  local cell = values(buf, 103).cells[C.title]
  vim.api.nvim_win_set_cursor(0, { line_of(buf, 103), cell.last - #"…" })
  change("x")
  require("ado.nvim.reveal").show(false)
  eq(values(buf, 103).values.title, LONG[103])
  eq(values(buf, 103).ambiguous, nil)
  ok(env.notes[#env.notes].msg:find("full text was not known", 1, true), env.notes[#env.notes].msg)
end)

test("UX4.3 resizing an unmodified view lays it out again, unmodified and with no undo step", function()
  setup(78)
  local buf = open_area()
  local wide = buffer_lines(buf)
  vim.api.nvim_win_set_width(0, 66)
  local view_refit = require("ado.nvim.view_buffer").refit
  view_refit(buf)
  local narrow = buffer_lines(buf)
  ok(not vim.deep_equal(wide, narrow), "the rows changed")
  for _, line in ipairs(narrow) do ok(scroll_width(line) < text_width(), line) end
  eq(vim.bo[buf].modified, false)
  eq(#vim.fn.undotree().entries, 0, "no undo step")
  eq(values(buf, 103).values.title, LONG[103])
end)

test("UX4.3 a modified view keeps its layout on resize, and its window bar says why", function()
  setup(78)
  local buf = open_area()
  to_cell(buf, 103, C.title, 0)
  change("x")
  local before = buffer_lines(buf)
  vim.api.nvim_win_set_width(0, 60)
  require("ado.nvim.view_buffer").refit(buf)
  eq(buffer_lines(buf), before)
  ok(vim.wo.winbar:find("fits the window after :w or <leader>wr", 1, true), vim.wo.winbar)
  vim.api.nvim_win_set_width(0, 78)
  require("ado.nvim.view_buffer").refit(buf)
  ok(not vim.wo.winbar:find("fits the window", 1, true), "back at its width: " .. vim.wo.winbar)
end)

test("UX4.3 a resize event re-fits the view on its own", function()
  setup(78)
  local buf = open_area()
  local wide = buffer_lines(buf)
  vim.api.nvim_win_set_width(0, 60)
  vim.api.nvim_exec_autocmds("WinResized", {})
  vim.wait(20)
  ok(not vim.deep_equal(buffer_lines(buf), wide))
end)

test("UX5.1 a row with a cut title pasted into a view of another width is cut to its layout and keeps its title", function()
  local env = setup(78)
  local area = open_area("P/Team/A")
  local area_win = vim.api.nvim_get_current_win()
  require("ado").item_view(100)
  local item = vim.api.nvim_get_current_buf()
  -- Show the item view in a 40-column window too, so it is laid out for 40.
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, 40)
  require("ado.nvim.view_buffer").refit(item)
  vim.api.nvim_set_current_win(area_win)
  local row = line_of(area, 103)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  change("dd")
  vim.api.nvim_set_current_win(vim.fn.win_findbuf(item)[1])
  vim.api.nvim_win_set_cursor(0, { line_of(item, 101), 0 })
  change("p")
  local pasted = values(item, 103)
  eq(pasted.values.title, LONG[103])
  eq(pasted.ambiguous, nil)
  eq(pasted.cells[C.type].text, "T", "cut to the item view's layout")
  local s = save(env, item, false)
  eq(s.can_apply, true, table.concat(s.lines, "\n"))
  ok(table.concat(s.lines, "\n"):find(LONG[103], 1, true), "the summary names the whole title")
  ok(not table.concat(s.lines, "\n"):find("title:", 1, true), "no title change")
end)

test("UX4.2 child rows indent their type letter, and the columns stay aligned", function()
  setup(60)
  require("ado").item_view(100)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { line_of(buf, 102), 0 })
  require("ado.nvim.item_view").actions.expand()
  vim.wait(20)
  local child = values(buf, 106)
  eq(child.cells[C.type].indent .. child.cells[C.type].text, "  T")
  local parent = values(buf, 102)
  local function bar(r) return vim.fn.strdisplaywidth(r.body:sub(1, r.ranges[C.type].bar - 1)) end
  eq(bar(child), bar(parent))
  eq(child.values.title, "Test fixtures for the payment provider sandbox and its error codes")
end)

test("UX4.5 the item view cuts its own title line and keeps the full title", function()
  local env = setup(40)
  require("ado").item_view(101)
  local buf = vim.api.nvim_get_current_buf()
  local own = fit.read(buffer_lines(buf)[1])
  eq(own.kind, "self")
  ok(own.cells[1].text:find("…", 1, true), own.cells[1].text)
  eq(own.values.title, LONG[101])
  vim.api.nvim_win_set_cursor(0, { 1, lines.prefix_length(buffer_lines(buf)[1]) })
  change("x")
  eq(fit.read(buffer_lines(buf)[1]).values.title, LONG[101]:sub(2))
  local s = save(env, buf, false)
  eq(s.lines[3], "  #101 title: '" .. LONG[101] .. "' -> '" .. LONG[101]:sub(2) .. "'")
end)

test("UX5.1 a copy of a row with a cut title (yyp), edited, saves the copy's full title", function()
  local env = setup(60)
  local buf = open_area()
  vim.api.nvim_win_set_cursor(0, { line_of(buf, 103), 0 })
  change("yyp")
  local copy = vim.fn.line(".")
  local prefix = lines.prefix_length(buffer_lines(buf)[copy])
  local ranges = lines.row_ranges(buffer_lines(buf)[copy])
  vim.api.nvim_win_set_cursor(0, { copy, prefix + ranges[C.title].first - 1 })
  change("x")
  local r = fit.read(buffer_lines(buf)[copy])
  eq(r.values.title, LONG[103]:sub(2))
  eq(fit.read(buffer_lines(buf)[copy - 1]).values.title, LONG[103], "the original keeps its title")
  local s = save(env, buf, false)
  eq(s.can_apply, true, table.concat(s.lines, "\n"))
  ok(table.concat(s.lines, "\n"):find("copy of #103 '" .. LONG[103]:sub(2) .. "'", 1, true), table.concat(s.lines, "\n"))
end)

test("UX5.1 a blockwise change in the heads of two cut titles restores both", function()
  setup(60)
  local buf = open_area()
  local first, second = line_of(buf, 102), line_of(buf, 103)
  eq(second, first - 1, "103 sits just above 102 in the seed's order")
  to_cell(buf, 103, C.title, 0)
  change("<C-v>jlcNo<Esc>")
  vim.wait(20)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(values(buf, 103).values.title, "No" .. LONG[103]:sub(3))
  eq(values(buf, 102).values.title, "No" .. LONG[102]:sub(3))
  eq(values(buf, 103).ambiguous, nil)
end)

-- Visible work item IDs: the id column is never cut and lines up in one
-- column at every width.
local function with_long_id()
  local seed = vim.deepcopy(require("tests.fixtures.long_seed"))
  table.insert(seed.items, { id = 900033, type = "Task", title = "A long title for the item with a six digit ID",
    state = "To Do", area = "P\\Team\\A", tags = "api; backend" })
  return seed
end

test("IDs are never cut: at 100, 60 and 40 columns every row shows its whole ID, in one aligned column", function()
  for _, width in ipairs({ 100, 60, 40 }) do
    views.fresh({ seed = with_long_id() })
    vim.o.columns, vim.o.lines = 120, 24
    vim.cmd("vsplit")
    vim.cmd("only")
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, width)
    local buf = open_area()
    local bars = {}
    for _, id in ipairs({ 101, 103, 900033 }) do
      local r = values(buf, id)
      eq(r.cells[C.id].text, tostring(id), width .. " columns, #" .. id)
      eq(r.values.id, tostring(id))
      table.insert(bars, vim.fn.strdisplaywidth(r.body:sub(1, r.ranges[C.id].bar - 1)))
      ok(vim.fn.strdisplaywidth(r.cells[C.title].text) >= 20, width .. " columns: the title keeps 20 columns")
    end
    eq(bars, { 7, 7, 7 }, width .. " columns: the separator after the ID lines up")
  end
end)

test("yic and yiw on an ID cell yank just the number", function()
  setup(60)
  local buf = open_area()
  local row = line_of(buf, 103)
  vim.api.nvim_win_set_cursor(0, { row, lines.prefix_length(buffer_lines(buf)[row]) })
  vim.fn.setreg('"', "")
  change("yic")
  eq(vim.fn.getreg('"'), "103")
  change("yiw")
  eq(vim.fn.getreg('"'), "103")
  eq(vim.bo[buf].modified, false)
end)
