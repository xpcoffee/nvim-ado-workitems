-- <leader>we, which picks a type or state for a cell or a column of rows
-- (plan 0002 UX3.2). vim.ui.select is replaced by a stub that records the
-- list and picks from it.
local lines = require("ado.nvim.lines")
local C = require("ado.core.table_layout").INDEX
local plan = require("ado.core.plan")
local session = require("ado.nvim.session")
local summary = require("ado.core.summary")
local views = require("tests.support.views")
local cursor_to = views.cursor_to

local asked

-- pick: the word to choose, or nil to cancel.
local function setup(pick, opts)
  local env = views.fresh(opts)
  vim.g.mapleader = "\\"
  asked = nil
  vim.ui.select = function(items, o, on_choice)
    asked = { prompt = o.prompt, words = {}, labels = {} }
    local chosen
    for _, it in ipairs(items) do
      table.insert(asked.words, it.word)
      table.insert(asked.labels, o.format_item(it))
      if it.word == pick then chosen = it end
    end
    on_choice(chosen)
  end
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

local function to_cell(title, index)
  local row = cursor_to(title)
  local ranges, offset = lines.row_ranges(vim.api.nvim_get_current_line())
  vim.api.nvim_win_set_cursor(0, { row, offset + ranges[index].first - 1 })
  return row
end

-- Selects lines first to last linewise, the cursor ending in cell
-- `index` of the last.
local function select_rows(first, last, index)
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  vim.cmd("normal! V")
  local ranges, offset = lines.row_ranges(vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1])
  vim.api.nvim_win_set_cursor(0, { last, offset + ranges[index].first - 1 })
end

local function row_text(row)
  return lines.parse(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1])
end

local function separators_aligned(buf)
  local columns
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local ranges, _, body = lines.row_ranges(line)
    if ranges then
      local cols = {}
      for i = 1, #ranges - 1 do cols[i] = lines.measure(body:sub(1, ranges[i].bar - 1)) end
      if columns and not vim.deep_equal(cols, columns) then return false end
      columns = cols
    end
  end
  return true
end

-- The save summary's lines for the view, as :w would show them.
local function summary_texts(env, buf)
  local record = env.area_view.record(buf)
  local prepared
  plan.prepare({ record }, session.get(), function(err, p) assert(not err, err and err.message) prepared = p end)
  local out = {}
  for _, l in ipairs(summary.lines(plan.compute({ record }, prepared))) do table.insert(out, l.text) end
  return out
end

test("UX3.2 <leader>we on a state cell writes the state picked, which the save summary lists", function()
  local env = setup("Doing")
  local buf = open_area()
  local row = to_cell("Write API", C.state)
  key("<leader>we")
  eq(asked.prompt, "State")
  eq(asked.words, { "To Do", "Doing", "Done", "Discarded" })
  eq(asked.labels[2], "Doing  (InProgress)")
  local p = row_text(row)
  eq({ p.type, p.state, p.title, p.assignee }, { "Task", "Doing", "Write API", "Me Myself" })
  ok(vim.bo[buf].modified)
  ok(separators_aligned(buf), "the write is re-padded")
  ok(vim.tbl_contains(summary_texts(env, buf), "  #101 state: To Do -> Doing"), vim.inspect(summary_texts(env, buf)))
  key("u")
  eq(row_text(row).state, "To Do")
  ok(separators_aligned(buf))
  eq(vim.bo[buf].modified, false)
end)

test("UX3.2 <leader>we on a type cell offers the configured types", function()
  setup("Bug", { projects = { { name = "P", types = { "Task", "Bug" } } } })
  open_area()
  local row = to_cell("Write API", C.type)
  key("<leader>we")
  eq(asked.prompt, "Type")
  eq(asked.labels, { "Task", "Bug  (no state To Do)" })
  eq(row_text(row).type, "Bug")
end)

test("UX3.2 Visual <leader>we writes the state into every selected row as one undo step", function()
  local env = setup("Done")
  local buf = open_area()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rows
  for i = 1, #before - 2 do
    local all_tasks = true
    for j = i, i + 2 do all_tasks = all_tasks and lines.parse(before[j]).type == "Task" end
    if all_tasks then rows = { i, i + 1, i + 2 } break end
  end
  ok(rows, "three Task rows in a row")
  local first = rows[1]
  select_rows(first, rows[3], C.state)
  key("<leader>we")
  eq(asked.prompt, "State for 3 rows")
  eq(asked.words, { "To Do", "Doing", "Done", "Discarded" })
  for _, r in ipairs(rows) do eq(row_text(r).state, "Done", "row " .. r) end
  ok(separators_aligned(buf))
  local texts = summary_texts(env, buf)
  local changes = 0
  for _, t in ipairs(texts) do if t:find("state: .* %-> Done") then changes = changes + 1 end end
  eq(changes, 3, vim.inspect(texts))
  key("u")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "one u restores every row")
  key("<C-r>")
  for _, r in ipairs(rows) do eq(row_text(r).state, "Done") end
  ok(separators_aligned(buf))
end)

test("UX3.2 Visual <leader>we over rows whose types share no state says which types", function()
  local env = setup("Done")
  local buf = open_area()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local story = cursor_to("Checkout story")
  local task = cursor_to("Write API")
  select_rows(math.min(story, task), math.max(story, task), C.state)
  key("<leader>we")
  eq(asked, nil, "no list to pick from")
  eq(env.notes[#env.notes].msg, string.format("[ado] the selected rows' types (%s) have no state in common",
    story < task and "User Story, Task" or "Task, User Story"))
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
end)

test("UX3.2 Visual <leader>we offers only the states every selected row's type shares", function()
  local seed = vim.deepcopy(require("tests.fixtures.seed"))
  for _, it in ipairs(seed.items) do
    if it.id == 114 then it.area = "P\\Team\\D" end
  end
  local env = setup("Closed", { seed = seed, area_filters = { state = "all" } })
  local buf = open_area("P/Team/C")
  local bug, story = cursor_to("Resolved bug"), cursor_to("Resolved story")
  local first, last = math.min(bug, story), math.max(bug, story)
  eq(last - first, 1, "the two rows are next to each other")
  select_rows(first, last, C.state)
  key("<leader>we")
  ok(asked, "a list opens once the catalog has loaded: " .. vim.inspect(env.notes))
  eq(asked.words, { "New", "Active", "Resolved", "Closed" })
  eq(asked.labels[3], "Resolved", "Resolved is in a different category for each type")
  for r = first, last do
    local p = row_text(r)
    if p.type == "Bug" or p.type == "User Story" then eq(p.state, "Closed") end
  end
  ok(vim.bo[buf].modified)
end)

test("UX3.2 <leader>we on the item view's state: line writes the state", function()
  setup("Closed")
  require("ado").item_view(100)
  local row = cursor_to("state: Active")
  key("<leader>we")
  eq(asked.words, { "New", "Active", "Resolved", "Closed" })
  eq(views.shown()[row], "state: Closed")
end)

test("UX3.2 <leader>we on an ID cell explains what it does and opens nothing", function()
  local env = setup("Doing")
  local buf = open_area()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  to_cell("Write API", C.id)
  key("<leader>we")
  eq(asked, nil)
  ok(env.notes[#env.notes].msg:find("the cursor is on the id cell", 1, true), env.notes[#env.notes].msg)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
end)

test("UX3.2 <leader>we on a title cell explains what it does and opens nothing", function()
  local env = setup("Doing")
  local buf = open_area()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  to_cell("Write API", C.title)
  key("<leader>we")
  eq(asked, nil)
  eq(env.notes[#env.notes].msg, "[ado] <leader>we picks a type, state or assignee from a list and writes it into"
    .. " that cell, or into that column of every selected row in Visual mode; the cursor is on the title cell")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
end)

test("UX3.2 cancelling the list writes nothing", function()
  setup(nil)
  local buf = open_area()
  to_cell("Write API", C.state)
  key("<leader>we")
  ok(asked)
  eq(vim.bo[buf].modified, false)
end)

test("UX3.2 an empty state cell takes the value where its text would start", function()
  setup("Doing")
  local buf = open_area()
  local row = to_cell("Write API", C.state)
  key("dic")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(row_text(row).state, "")
  key("<leader>we")
  eq(row_text(row).state, "Doing")
  ok(separators_aligned(buf))
end)
