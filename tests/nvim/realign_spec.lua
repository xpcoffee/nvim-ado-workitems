-- Re-padding the views' item rows after an edit (plan 0002 UX1.1 to UX1.6,
-- UX1.8). Headless Neovim does not fire TextChanged after keys fed with
-- nvim_feedkeys (plan 0002 section 4), so change() fires it, as the editor
-- does once a Normal-mode command ends.
local lines = require("ado.nvim.lines")
local C = require("ado.core.table_layout").INDEX
local screen = require("tests.support.screen")
local seed = require("tests.fixtures.seed")
local ux_stats = require("ado.nvim.ux_stats")
local views = require("tests.support.views")
local cursor_to = views.cursor_to

local function buffer_lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

-- Runs keys as typed, then lets the InsertLeave re-pad run and fires
-- TextChanged.
local function change(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(10)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_get_current_buf() })
end

local function open_area(path)
  require("ado").area_view(path or "P/Team/A")
  return vim.api.nvim_get_current_buf()
end

local function open_item(id)
  require("ado").item_view(id)
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

-- The display column of each separator on every item row; nil when the
-- rows disagree.
local function separator_columns(buf)
  local columns
  for _, line in ipairs(buffer_lines(buf)) do
    local ranges, offset, body = lines.row_ranges(line)
    if ranges then
      local cols = {}
      for i = 1, #ranges - 1 do cols[i] = lines.measure(body:sub(1, ranges[i].bar - 1)) end
      if columns and not vim.deep_equal(cols, columns) then return nil, line end
      columns = cols
    end
  end
  return columns
end

local function assert_aligned(buf, message)
  local cols, line = separator_columns(buf)
  ok(cols, (message or "rows misaligned") .. ": " .. tostring(line))
end

local function cell_texts(buf)
  local out = {}
  for i, line in ipairs(buffer_lines(buf)) do
    local p = lines.parse(line)
    out[i] = { p.type, p.state, p.title, p.assignee, p.tags, p.shown_id }
  end
  return out
end

local function setup(opts)
  ux_stats.reset()
  return views.fresh(opts)
end

test("UX1.1 a change that widens a column re-pads every row on <Esc>", function()
  setup()
  local buf = open_area()
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  eq(lines.parse(buffer_lines(buf)[vim.fn.line(".")]).state, "In Progress")
  assert_aligned(buf)
  eq(lines.row_ranges(buffer_lines(buf)[1])[C.state].to - lines.row_ranges(buffer_lines(buf)[1])[C.state].from + 1,
    #" In Progress ", "the state column is as wide as its widest cell")
end)

test("UX1.1 only the lines whose padding is wrong are rewritten", function()
  setup()
  local buf = open_area()
  local before = buffer_lines(buf)
  local row = to_cell("Add tests", C.state)
  change("ceDone<Esc>")
  local after = buffer_lines(buf)
  for i = 1, #before do
    if i ~= row then eq(after[i], before[i], "line " .. i) end
  end
  assert_aligned(buf)
  eq(ux_stats.get().repad.lines, 1)
end)

test("UX1.2 one u undoes an edit and its re-pad; <C-r> redoes both", function()
  setup()
  local buf = open_area()
  local before = buffer_lines(buf)
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  local after = buffer_lines(buf)
  change("u")
  eq(buffer_lines(buf), before)
  eq(vim.bo[buf].modified, false)
  change("<C-r>")
  eq(buffer_lines(buf), after)
  change("u")
  eq(buffer_lines(buf), before)
end)

test("UX1.3 during Insert mode only the edited line drifts", function()
  setup()
  local buf = open_area()
  local before = buffer_lines(buf)
  local row = to_cell("Add tests", C.state)
  local during
  vim.api.nvim_create_autocmd("InsertLeave", { buffer = buf, once = true,
    callback = function() during = buffer_lines(buf) end })
  change("ceIn Progress<Esc>")
  for i = 1, #before do
    if i ~= row then eq(during[i], before[i], "line " .. i) end
  end
  ok(during[row] ~= before[row])
  assert_aligned(buf)
end)

test("UX1.3 a blockwise change over the state column of 3 rows works on every row", function()
  setup()
  local buf = open_area()
  local before = cell_texts(buf)
  to_cell("Support issue", C.state)
  -- The block covers the state column's width, "Active".
  change("<C-v>2j5lcClosed<Esc>")
  local after = cell_texts(buf)
  for i = 1, 3 do eq(after[i][2], "Closed", "row " .. i) end
  for i = 4, #after do eq(after[i], before[i], "row " .. i .. " is untouched") end
  for i = 1, 3 do eq(after[i][3], before[i][3], "row " .. i .. " keeps its title") end
  assert_aligned(buf)
  change("u")
  eq(cell_texts(buf), before)
end)

test("dd then p keeps the rows aligned as the widest state leaves and comes back", function()
  setup()
  local buf = open_area()
  local before = buffer_lines(buf)
  cursor_to("Checkout story")
  change("dd")
  assert_aligned(buf)
  ok(not buffer_lines(buf)[1]:find("To Do  │"), "the state column narrowed to 'To Do'")
  change("ggP")
  assert_aligned(buf)
  eq(lines.parse(buffer_lines(buf)[1]).title, "Checkout story")
  change("u")
  change("u")
  eq(buffer_lines(buf), before)
end)

test("a row pasted from another view with different widths is re-padded to this one", function()
  setup()
  local other = open_area("P/Team/B")
  local pasted
  for _, l in ipairs(buffer_lines(other)) do
    if lines.parse(l).title == "Update docs" then pasted = l end
  end
  local buf = open_area("P/Team/A")
  ok(buf ~= other)
  vim.fn.setreg("a", pasted, "l")
  change('G"ap')
  eq(lines.parse(buffer_lines(buf)[#buffer_lines(buf)]).title, "Update docs")
  assert_aligned(buf)
end)

test(":s over a range re-pads the rows it changed and the rest", function()
  setup()
  local buf = open_area()
  change(":%s/To Do/Waiting for review/<CR>")
  local states = {}
  for _, row in ipairs(cell_texts(buf)) do states[row[2]] = true end
  ok(states["Waiting for review"])
  assert_aligned(buf)
end)

test("a macro's changes are re-padded once it ends; u steps back through them", function()
  setup()
  local buf = open_area()
  local before = buffer_lines(buf)
  to_cell("Support issue", C.state)
  vim.fn.setreg("q", vim.keycode("ceBlocked<Esc>j02f│w"))
  change("2@q")
  local after = cell_texts(buf)
  eq({ after[1][2], after[2][2] }, { "Blocked Do", "Blocked Do" })
  assert_aligned(buf)
  change("u")
  change("u")
  eq(buffer_lines(buf), before)
end)

test("<C-c> leaves Insert mode without InsertLeave; the TextChanged after it re-pads", function()
  setup()
  local buf = open_area()
  to_cell("Add tests", C.state)
  change("ceIn Progress<C-c>")
  assert_aligned(buf)
end)

test("UX1.4 a load and an expansion leave the modified flag off, also when a child widens a column", function()
  local deeper = {}
  for k, v in pairs(seed) do deeper[k] = v end
  deeper.items = {}
  for _, it in ipairs(seed.items) do table.insert(deeper.items, it) end
  table.insert(deeper.items, { id = 116, type = "Task", title = "A much longer title than any shown before",
    state = "To Do", area = "P\\Team\\A", parent = 102, changed = "2026-10-12T10:00:00Z" })
  setup({ seed = deeper })
  local buf = open_item(100)
  local tick = vim.b[buf].changedtick
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(vim.b[buf].changedtick, tick, "nothing to re-pad after a load")
  eq(vim.bo[buf].modified, false)
  cursor_to("Add tests")
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "xt", false)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  ok(vim.tbl_contains(views.parsed(buf), "A much longer title than any shown before"))
  eq(vim.bo[buf].modified, false)
  assert_aligned(buf, "the rows shown before the expansion widen with it")
  change("u")
  ok(vim.tbl_contains(views.parsed(buf), "A much longer title than any shown before"), "u cannot undo an expansion")
end)

test("UX1.4 a re-pad changes nothing the save plans: an edit typed back is nothing to save", function()
  local env = setup()
  local buf = open_area()
  local record = env.area_view.record(buf)
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  local edited = env.area_view.record(buf)
  for i, c in ipairs(edited.current) do
    local s = record.current[i]
    for _, f in ipairs({ "type", "title", "assignee", "tags" }) do eq(c[f], s[f], "row " .. i .. " " .. f) end
    if c.title ~= "Add tests" then eq(c.state, s.state, "row " .. i .. " state") end
  end
  to_cell("Add tests", C.state)
  change("cicDoing<Esc>")
  ok(vim.bo[buf].modified)
  vim.cmd("write")
  vim.wait(20)
  eq(env.notes[#env.notes].msg, "[ado] nothing to save")
  eq(#env.fake.writes, 0)
end)

test("UX1.5 the cursor stays in the same cell, at the same offset in it", function()
  setup()
  local buf = open_area()
  local row = to_cell("Add tests", C.title)
  local ranges, offset = lines.row_ranges(buffer_lines(buf)[row])
  -- A change made by a command that leaves the cursor in the title.
  vim.api.nvim_buf_set_text(buf, row - 1, offset + ranges[C.state].first - 1, row - 1, offset + ranges[C.state].last,
    { "In Progress" })
  ranges = lines.row_ranges(buffer_lines(buf)[row])
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[C.title].first - 1 + 4 })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  assert_aligned(buf)
  local now = buffer_lines(buf)[row]
  local new_ranges = lines.row_ranges(now)
  eq(vim.api.nvim_win_get_cursor(0), { row, offset + new_ranges[C.title].first - 1 + 4 })
  eq(now:sub(vim.fn.col("."), vim.fn.col(".")), "t", "still on the t of 'Add tests'")
end)

test("UX1.6 end-of-line labels and concealed prefixes survive a re-pad; field and title lines are left alone", function()
  setup()
  local buf = open_item(100)
  local labels = vim.api.nvim_create_namespace("ado_view_labels")
  local function label_rows()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, labels, 0, -1, { details = true })) do
      out[m[2]] = m[4].virt_text[1][1]
    end
    return out
  end
  local before_labels = label_rows()
  local before = buffer_lines(buf)
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  assert_aligned(buf)
  eq(label_rows(), before_labels)
  local concealed = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_view, 0, -1, {})
  eq(#concealed, #views.row_lines(buf), "every row line keeps its concealed prefix")
  for i, l in ipairs(before) do
    if not lines.row_ranges(l) then eq(buffer_lines(buf)[i], l, "line " .. i) end
  end
end)

test("UX1.1 the item view's own title is never padded, even when it holds four separators", function()
  local odd = {}
  for k, v in pairs(seed) do odd[k] = v end
  odd.items = {}
  for _, it in ipairs(seed.items) do
    if it.id == 100 then
      it = vim.deepcopy(it)
      it.title = "a│b│c│d│e"
    end
    table.insert(odd.items, it)
  end
  setup({ seed = odd })
  local buf = open_item(100)
  eq(buffer_lines(buf)[1]:match("^/%d+ (.*)$"), "a│b│c│d│e")
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  eq(buffer_lines(buf)[1]:match("^/%d+ (.*)$"), "a│b│c│d│e")
end)

test("separators sit in the same screen column on every row, in 40, 60 and 78 column splits", function()
  setup()
  -- Headless Neovim draws an 80-column screen whatever 'columns' says,
  -- and screenstring() reads that screen, so the windows must fit inside
  -- it. A window takes the new width only when the layout is rebuilt.
  vim.o.columns = 80
  vim.cmd("vsplit")
  vim.cmd("only")
  local buf = open_area()
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  for _, width in ipairs({ 40, 60, 78 }) do
    vim.cmd("vsplit")
    vim.api.nvim_win_set_width(0, width)
    local cols
    for _, row in ipairs(screen.rows(0)) do
      if row:find("│") then
        local found = screen.columns(row, "│")
        if cols then eq(found, cols, width .. " columns: " .. row) end
        cols = found
      end
    end
    ok(cols and #cols >= 2, width .. " columns: separators drawn")
    vim.cmd("close")
  end
  ok(vim.api.nvim_get_current_buf() == buf)
end)

-- The state dots of plan 0002 phase 2 are inline virtual text, which
-- shifts the screen columns after it on every row by the same amount.
local function dots(buf)
  local ns = vim.api.nvim_get_namespaces().ado_decorations
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text_pos == "inline" then n = n + 1 end
  end
  return n
end

test("UX2.2 with the state dots drawn, separators and dots share their screen columns on every row", function()
  setup()
  vim.o.columns = 80
  vim.cmd("vsplit")
  vim.cmd("only")
  local buf = open_area()
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  ok(dots(buf) >= 4, "the rows have dots")
  local seps, marks
  for _, row in ipairs(screen.rows(0)) do
    if row:find("│") then
      local found, dot = screen.columns(row, "│"), screen.columns(row, "●")
      if seps then
        eq(found, seps, row)
        eq(dot, marks, row)
      end
      seps, marks = found, dot
    end
  end
  eq(#marks, 1)
  ok(marks[1] > seps[C.state - 1] and marks[1] < seps[C.state], "the dot sits in the state column")
end)

test("UX2.2 a blockwise change over the state column works with the dots in place", function()
  setup()
  local buf = open_area()
  ok(dots(buf) >= 3, "the rows have dots")
  local before = cell_texts(buf)
  to_cell("Support issue", C.state)
  change("<C-v>2j5lcClosed<Esc>")
  local after = cell_texts(buf)
  for i = 1, 3 do eq(after[i][2], "Closed", "row " .. i) end
  for i = 1, 3 do eq(after[i][3], before[i][3], "row " .. i .. " keeps its title") end
  assert_aligned(buf)
  ok(dots(buf) >= 3, "the dots are drawn again")
  change("u")
  eq(cell_texts(buf), before)
end)

test("UX1.8 each re-pad is timed; a slow one warns once", function()
  local env = setup()
  local buf = open_area()
  ux_stats.SLOW_MS.repad = -1
  to_cell("Add tests", C.state)
  change("ceIn Progress<Esc>")
  change("ceDoing<Esc>")
  ux_stats.SLOW_MS.repad = 50
  local stats = ux_stats.get().repad
  eq(stats.count, 2)
  ok(stats.max_ms >= stats.last_ms)
  local warnings = vim.tbl_filter(function(n) return n.msg:find("re%-pad took") ~= nil end, env.notes)
  eq(#warnings, 1)
  local printed = table.concat(require("ado").ux_stats(), "\n")
  ok(printed:find("\nrepad: 2 runs, last [%d.]+ ms, largest [%d.]+ ms"), printed)
  ok(vim.api.nvim_buf_is_valid(buf))
end)
