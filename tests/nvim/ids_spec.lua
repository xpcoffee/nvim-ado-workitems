-- Visible work item IDs: the id column of every row view and the `id:`
-- line of the item buffer. They are shown for copying and never edit
-- anything: a changed ID rejects the save with nothing sent, a typed line
-- leaves its ID empty until the save creates the item, and pasted rows
-- are still matched by their row ID prefix.
local lines = require("ado.nvim.lines")
local C = require("ado.core.table_layout").INDEX
local views = require("tests.support.views")
local cursor_to, shown = views.cursor_to, views.shown

local function setup()
  local env = views.fresh({ audit_log = vim.fn.tempname() })
  env.summaries = {}
  require("ado.nvim.save").confirm = function(text, can_apply, cb)
    local out = {}
    for _, l in ipairs(text) do table.insert(out, l.text) end
    table.insert(env.summaries, { lines = out, can_apply = can_apply })
    cb(can_apply)
  end
  require("ado.nvim.save").show_report = function() end
  return env
end

local function key(keys)
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

local function write(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  vim.wait(20)
end

local function buffer_lines(buf)
  return views.row_lines(buf)
end

-- The id cell of the line showing title.
local function id_cell(buf, title)
  for _, l in ipairs(buffer_lines(buf)) do
    local p = lines.parse(l)
    if p.title == title then return p.shown_id end
  end
  error("no row " .. title)
end

local function to_id_cell(title)
  local row = cursor_to(title)
  local ranges, offset = lines.row_ranges(vim.api.nvim_get_current_line())
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[C.id].first - 1 })
  return row
end

local function writes(env)
  return #env.fake.writes
end

test("every row view starts its rows with the ID, and the item buffer's first field line is id:", function()
  setup()
  local a = open_area()
  for _, l in ipairs(buffer_lines(a)) do
    local p = lines.parse(l)
    if p.kind == "item" then
      local reg = require("ado.nvim.registry").get(p.row_id)
      eq(p.shown_id, tostring(reg.row.id), l)
      ok(l:match("^/%d+ " .. reg.row.id .. "%s*│ "), l)
    end
  end
  require("ado").my_items()
  local q = vim.api.nvim_get_current_buf()
  eq(id_cell(q, "Write API"), "101", "the query list shows IDs too")
  local i = open_item(102)
  eq(shown(i)[1], "Add tests")
  eq(shown(i)[2], "id: 102")
  eq(id_cell(i, "Checkout story"), "100", "the parent row")
  eq(id_cell(i, "Test fixtures"), "106", "a child row")
end)

test("child rows under an expanded row keep their indent in the type column, so IDs line up", function()
  setup()
  local buf = open_item(100)
  cursor_to("Add tests")
  key("<Tab>")
  local bars = {}
  for _, title in ipairs({ "Write API", "Add tests", "Test fixtures" }) do
    local line = buffer_lines(buf)[cursor_to(title)]
    local ranges, _, body = lines.row_ranges(line)
    table.insert(bars, vim.fn.strdisplaywidth(body:sub(1, ranges[C.id].bar - 1)))
    if title == "Test fixtures" then
      ok(body:sub(ranges[C.type].first, ranges[C.type].last):match("^  Task$"), body)
    end
  end
  eq(bars[1], bars[2])
  eq(bars[2], bars[3])
end)

test("an edited ID cell rejects the save with nothing sent, marks the row, and u restores it", function()
  local env = setup()
  local buf = open_area()
  local row = to_id_cell("Fix login")
  key("ciw999<Esc>")
  eq(id_cell(buf, "Fix login"), "999")
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_decorations, { row - 1, 0 },
    { row - 1, -1 }, { details = true })
  local signed = false
  for _, m in ipairs(marks) do if m[4].sign_text then signed = true end end
  ok(signed, "the row is marked changed")
  local calls = #env.fake.calls
  write(buf)
  eq(env.summaries[1].can_apply, false)
  local text = table.concat(env.summaries[1].lines, "\n")
  ok(text:find("#103 (line " .. row .. ") in ado://area/P/Team/A", 1, true), text)
  ok(text:find("the ID is read-only; put 103 back, or reload", 1, true), text)
  eq(writes(env), 0)
  eq(#env.fake.calls, calls, "the rejected save made no call")
  eq(vim.bo[buf].modified, true, "the edits are kept")
  key("u")
  eq(id_cell(buf, "Fix login"), "103")
  eq(vim.bo[buf].modified, false, "u is back at the loaded text")
end)

test("an edited ID beside a title edit rejects the whole row, so the title is not sent either", function()
  local env = setup()
  local buf = open_area()
  to_id_cell("Fix login")
  key("ciw104<Esc>")
  cursor_to("Fix login")
  key("0f│;;wcwMend<Esc>")
  eq(lines.parse(buffer_lines(buf)[cursor_to("Mend login")]).shown_id, "104")
  write(buf)
  eq(env.summaries[1].can_apply, false)
  eq(writes(env), 0)
  eq(env.fake.items[103].fields["System.Title"], "Fix login")
end)

test("an edited id: line in the item buffer rejects the save with nothing sent", function()
  local env = setup()
  local buf = open_item(102)
  local row = cursor_to("id: 102")
  vim.api.nvim_win_set_cursor(0, { row, #vim.api.nvim_get_current_line() - 1 })
  key("ciw101<Esc>")
  eq(shown(buf)[2], "id: 101")
  write(buf)
  eq(env.summaries[1].can_apply, false)
  ok(table.concat(env.summaries[1].lines, "\n"):find("the ID is read-only; put 102 back, or reload", 1, true),
    table.concat(env.summaries[1].lines, "\n"))
  eq(writes(env), 0)
end)

test("a typed line leaves its ID empty; the save creates it, and its ID shows after the reload", function()
  local env = setup()
  local buf = open_area()
  cursor_to("Write API")
  key("o │ Task │ │ Write the changelog │ │<Esc>")
  eq(id_cell(buf, "Write the changelog"), "")
  write(buf)
  eq(env.summaries[1].can_apply, true)
  eq(env.summaries[1].lines[3], "  new Task 'Write the changelog' in P\\Team\\A, no parent")
  eq(env.fake.counts.create_work_item, 1)
  eq(vim.bo[buf].modified, false)
  eq(id_cell(buf, "Write the changelog"), "1000")
end)

test("a typed line with text in its id column is rejected, since ADO gives the ID", function()
  local env = setup()
  local buf = open_area()
  cursor_to("Write API")
  key("o101 │ Task │ │ Not a copy │ │<Esc>")
  write(buf)
  eq(env.summaries[1].can_apply, false)
  ok(table.concat(env.summaries[1].lines, "\n"):find("leave its id column empty", 1, true),
    table.concat(env.summaries[1].lines, "\n"))
  eq(writes(env), 0)
end)

test("dd and p move a row by its row ID prefix; the pasted row keeps its ID text and lines up", function()
  local env = setup()
  local a = open_area("P/Team/A")
  cursor_to("Fix login")
  vim.cmd("normal! dd")
  local b = open_area("P/Team/B")
  cursor_to("Update docs")
  key("p")
  eq(id_cell(b, "Fix login"), "103")
  local bars = {}
  for _, l in ipairs(buffer_lines(b)) do
    local ranges, _, body = lines.row_ranges(l)
    if ranges then bars[vim.fn.strdisplaywidth(body:sub(1, ranges[C.id].bar - 1))] = true end
  end
  eq(vim.tbl_count(bars), 1, "one id column")
  write(b)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "Parent and area changes",
    "  #103 'Fix login' area: P\\Team\\A -> P\\Team\\B" })
  eq(env.fake.items[103].fields["System.AreaPath"], "P\\Team\\B")
  eq(vim.bo[a].modified, false)
end)

test("yyp copies a row, which shows the original's ID until the save gives the copy its own", function()
  local env = setup()
  local buf = open_area()
  cursor_to("Write API")
  key("yyp")
  local copies = 0
  for _, l in ipairs(buffer_lines(buf)) do
    local p = lines.parse(l)
    if p.title == "Write API" then
      copies = copies + 1
      eq(p.shown_id, "101")
    end
  end
  eq(copies, 2)
  write(buf)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "Copies: check these",
    "  copy of #101 'Write API' (Task) in P\\Team\\A, parent #100" })
  local ids = {}
  for _, l in ipairs(buffer_lines(buf)) do
    local p = lines.parse(l)
    if p.title == "Write API" then table.insert(ids, p.shown_id) end
  end
  table.sort(ids)
  eq(ids, { "1000", "101" })
end)

test("a row pasted with an edited ID is rejected, though its row ID prefix names the item", function()
  local env = setup()
  open_area("P/Team/A")
  cursor_to("Fix login")
  vim.cmd("normal! dd")
  local b = open_area("P/Team/B")
  cursor_to("Update docs")
  key("p")
  to_id_cell("Fix login")
  key("ciw104<Esc>")
  write(b)
  eq(env.summaries[1].can_apply, false)
  eq(writes(env), 0)
  eq(env.fake.items[103].fields["System.AreaPath"], "P\\Team\\A")
end)

test("<leader>wx on an ID cell says it is shown in full and changes nothing", function()
  local env = setup()
  vim.g.mapleader = "\\"
  local buf = open_area()
  to_id_cell("Fix login")
  key("<leader>wx")
  eq(env.notes[#env.notes].msg, "[ado] the id is shown in full")
  eq(vim.bo[buf].modified, false)
end)

test("the cursor never rests in a row's hidden row ID prefix, so yiw after 0 or G yanks the ID", function()
  setup()
  local buf = open_area()
  local row = cursor_to("Fix login")
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  eq(vim.api.nvim_win_get_cursor(0)[2], lines.prefix_length(vim.api.nvim_get_current_line()))
  vim.fn.setreg('"', "")
  vim.cmd("normal! yiw")
  eq(vim.fn.getreg('"'), "103")
  local i = open_item(102)
  local readonly_row = require("ado.nvim.region").last_row(i) + 1
  vim.api.nvim_win_set_cursor(0, { readonly_row, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = i })
  eq(vim.api.nvim_win_get_cursor(0), { readonly_row, 0 }, "the read-only region has no prefixes to skip")
end)
