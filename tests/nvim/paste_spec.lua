-- Structural edits made with ordinary Vim commands across view buffers
-- (RFC 0001 R5.1, R5.2): a line yanked or deleted in one view and put in
-- another keeps its row ID, so the save plans a move or a copy of that item
-- rather than a new line.
local views = require("tests.support.views")
local key, shown, cursor_to = views.key, views.shown, views.cursor_to

local function setup()
  local log = vim.fn.tempname()
  local env = views.fresh({ audit_log = log })
  env.log = log
  env.summaries = {}
  require("ado.nvim.save").confirm = function(lines, can_apply, cb)
    local text = {}
    for _, l in ipairs(lines) do table.insert(text, l.text) end
    table.insert(env.summaries, { lines = text, can_apply = can_apply })
    cb(true)
  end
  env.reports = {}
  require("ado.nvim.save").show_report = function(lines) table.insert(env.reports, lines) end
  return env
end

local function open_area(path)
  require("ado").area_view(path)
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

local function normal(keys)
  vim.cmd("normal! " .. keys)
end

test("a line deleted in one area view and put in another moves the item to that area (spike S3)", function()
  local env = setup()
  local a = open_area("P/Team/A")
  cursor_to("Fix login")
  normal("dd")
  local b = open_area("P/Team/B")
  cursor_to("Update docs")
  normal("p")
  write(b)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "Parent and area changes",
    "  #103 'Fix login' area: P\\Team\\A -> P\\Team\\B" })
  eq(env.fake.items[103].fields["System.AreaPath"], "P\\Team\\B")
  eq(env.fake.counts.create_work_item, nil, "a move creates nothing")
  eq(vim.bo[a].modified, false)
  eq(vim.bo[b].modified, false)
  ok(not vim.tbl_contains(shown(a), "Fix login"))
  ok(vim.tbl_contains(shown(b), "Fix login"))
end)

test("a line yanked in one area view and put in another copies the item there", function()
  local env = setup()
  open_area("P/Team/A")
  cursor_to("Write API")
  normal("yy")
  local b = open_area("P/Team/B")
  normal("G")
  normal("p")
  write(b)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "Copies: check these",
    "  copy of #101 'Write API' (Task) in P\\Team\\B, parent #100" })
  local copy = env.fake.items[1000].fields
  eq({ copy["System.Title"], copy["System.AreaPath"], copy["System.Parent"] }, { "Write API", "P\\Team\\B", 100 })
  eq(env.fake.items[101].fields["System.AreaPath"], "P\\Team\\A", "the original stays")
  ok(vim.tbl_contains(shown(b), "Write API"))
end)

test("a child deleted in one item view and put under another item's children changes its parent", function()
  local env = setup()
  local from = open_item(100)
  cursor_to("Write API")
  normal("dd")
  local to = open_item(105)
  cursor_to("Children: 0 open of 1")
  normal("p")
  write(to)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "Parent and area changes",
    "  #101 'Write API' parent: #100 -> #105" })
  eq(env.fake.items[101].fields["System.Parent"], 105)
  eq(vim.bo[from].modified, false)
  ok(vim.tbl_contains(shown(to), "Write API"))
end)

test("a title typed on a new line under Children creates a child with the default type", function()
  local env = setup()
  local buf = open_item(100)
  cursor_to("Children: 2")
  key("oWrite the changelog<Esc>")
  write(buf)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "New items",
    "  new Task 'Write the changelog' in P\\Team\\A, parent #100" })
  eq(env.fake.items[1000].fields["System.Parent"], 100)
  ok(vim.tbl_contains(shown(buf), "Write the changelog"), "the view reloads with the new child")
  eq(env.notes[#env.notes].msg, "[ado] saved 1 change to 1 work item: 1 created (#1000)")
  local logged = vim.json.decode(vim.fn.readfile(env.log)[1])
  local c = logged.changes[1]
  eq({ c.op, c.type, c.title, c.area, c.parent, logged.created, logged.result },
    { "create", "Task", "Write the changelog", "P\\Team\\A", 100, 1000, "ok" })
end)

test("the item view's own title line put in an area view copies that item", function()
  local env = setup()
  open_item(100)
  cursor_to("Checkout story")
  normal("yy")
  local b = open_area("P/Team/B")
  normal("G")
  normal("p")
  write(b)
  eq(env.summaries[1].lines[3], "  copy of #100 'Checkout story' (User Story) in P\\Team\\B, no parent")
end)

test("deleting a Related row lists a link removal, which the summary marks to stand out", function()
  local env = setup()
  local buf = open_item(100)
  cursor_to("Payments story")
  normal("dd")
  local kinds
  require("ado.nvim.save").confirm = function(lines, _, cb)
    kinds = {}
    for _, l in ipairs(lines) do table.insert(kinds, { l.text, l.kind }) end
    cb(false)
  end
  write(buf)
  eq(kinds, { { "Save 1 change to Azure DevOps?", "title" }, { "Link removals: check these", "heading" },
    { "  #100: remove Related link to #105 'Payments story'", "removal" } })
  eq(#env.fake.writes, 0)
end)

test("undo right after an expansion leaves the expanded rows, so it cannot plan link removals (risk 3)", function()
  local env = setup()
  local buf = open_item(100)
  cursor_to("Add tests")
  key("<Tab>")
  local expanded = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.cmd("silent! undo")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expanded)
  eq(vim.bo[buf].modified, false)
  write(buf)
  eq(#env.summaries, 0)
  eq(#env.fake.writes, 0)
end)

test("a line yanked before its view reloaded is rejected with its line number", function()
  local env = setup()
  open_area("P/Team/A")
  cursor_to("Fix login")
  normal("yy")
  key("<leader>wr")
  local b = open_area("P/Team/B")
  normal("G")
  normal("p")
  local line = vim.api.nvim_win_get_cursor(0)[1]
  write(b)
  eq(env.summaries[1].can_apply, false)
  ok(env.summaries[1].lines[3]:find("line " .. line .. " in ado://area/P/Team/B", 1, true), env.summaries[1].lines[3])
  ok(env.summaries[1].lines[3]:find("this row's ID is not known", 1, true), env.summaries[1].lines[3])
  eq(#env.fake.writes, 0)
end)

test("a pasted line's row ID prefix is concealed like the lines the view drew", function()
  views.fresh()
  require("ado").area_view("P/Team/A")
  local buf = vim.api.nvim_get_current_buf()
  cursor_to("Fix login")
  key("yyP")
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  local ns = vim.api.nvim_get_namespaces().ado_view
  local concealed = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].conceal == "" then concealed[m[2]] = true end
  end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^/%d+ ") then ok(concealed[i - 1], "line " .. i .. " is concealed: " .. line) end
  end
  eq(vim.api.nvim_buf_line_count(buf), #views.parsed(buf))
end)
