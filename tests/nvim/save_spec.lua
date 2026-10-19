-- :w in the views (RFC 0001 R5.2, R5.3, R5.15, R6.8, R7.4): the summary,
-- accept and cancel, the reload after a save, and the edits that survive
-- other buffers' writes, expansions and reloads.
local views = require("tests.support.views")
local key, shown, cursor_to = views.key, views.shown, views.cursor_to

local function setup(opts)
  opts = opts or {}
  local log = vim.fn.tempname()
  local env = views.fresh({ audit_log = log, seed = opts.seed })
  env.log = log
  env.summaries = {}
  env.reports = {}
  env.answer = opts.answer
  require("ado.nvim.save").confirm = function(lines, can_apply, cb)
    local text = {}
    for _, l in ipairs(lines) do table.insert(text, l.text) end
    table.insert(env.summaries, { lines = text, can_apply = can_apply })
    cb(env.answer)
  end
  require("ado.nvim.save").show_report = function(lines)
    local text = {}
    for _, l in ipairs(lines) do table.insert(text, l.text) end
    table.insert(env.reports, text)
  end
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

-- Replaces `from` with `to` on the first line of buf that shows `from`.
local function edit(buf, from, to)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local s, e = l:find(from, 1, true)
    if s then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { l:sub(1, s - 1) .. to .. l:sub(e + 1) })
      return
    end
  end
  error("no line shows " .. from)
end

-- :w starts the save on the next event loop turn (view_buffer.lua), so
-- the spec lets that turn run.
local function write(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  vim.wait(20)
end

local function audit_lines(env)
  if vim.fn.filereadable(env.log) == 0 then return {} end
  local out = {}
  for _, l in ipairs(vim.fn.readfile(env.log)) do table.insert(out, vim.json.decode(l)) end
  return out
end

local function last_note(env)
  return env.notes[#env.notes].msg
end

test("accept: a retitle makes 1 write, the view reloads unmodified, and the audit log has its line", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit(buf, "Write API", "Write the API")
  eq(vim.bo[buf].modified, true)
  write(buf)
  eq(env.summaries[1], { lines = { "Save 1 change to Azure DevOps?", "Field changes",
    "  #101 title: 'Write API' -> 'Write the API'" }, can_apply = true })
  eq(#env.fake.writes, 1)
  eq(env.fake.items[101].fields["System.Title"], "Write the API")
  eq(vim.bo[buf].modified, false)
  ok(vim.tbl_contains(shown(buf), "Write the API"))
  eq(last_note(env), "[ado] saved 1 change to 1 work item: 1 field update")
  eq(env.reports, {}, "a full save opens no report")
  local logged = audit_lines(env)
  eq(#logged, 1)
  eq({ logged[1].id, logged[1].result, logged[1].rev }, { 101, "ok", 2 })
  eq(logged[1].changes, { { op = "update", field = "System.Title", from = "Write API", to = "Write the API" } })
  ok(logged[1].time:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), logged[1].time)
  ok(vim.tbl_contains(env.echoes, "saving 1/1: #101 (1 change)"), vim.inspect(env.echoes))
end)

test("cancel: 0 writes, and the view keeps its edits and stays modified", function()
  local env = setup({ answer = false })
  local buf = open_area("P/Team/A")
  edit(buf, "Fix login", "Fix the login")
  local edited = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local calls = #env.fake.calls
  write(buf)
  eq(#env.summaries, 1)
  eq(#env.fake.writes, 0)
  eq(#env.fake.calls, calls, "planning made no calls: the catalog was cached")
  eq(vim.bo[buf].modified, true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), edited)
  eq(env.summaries[1].can_apply, true)
  eq(last_note(env), "[ado] save cancelled; nothing was sent and the views keep their edits")
  eq(audit_lines(env), {})
end)

test("a rejected plan sends nothing and ends in one line naming the problem count", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit(buf, "To Do", "Doing")
  write(buf)
  eq(env.summaries[1].can_apply, false, "the first To Do row is an Issue, which has no Doing")
  eq(#env.fake.writes, 0)
  eq(#env.notes, 1)
  eq(last_note(env), "[ado] save rejected: 1 problem, nothing was sent; the views keep their edits")
end)

test("writing an ordinary file leaves a view's unsaved edits alone (R6.8)", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit(buf, "Write API", "Write the API")
  local edited = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local file = vim.fn.tempname()
  vim.cmd("new " .. file)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "notes" })
  vim.cmd("silent write")
  eq(#env.summaries, 0)
  eq(#env.fake.writes, 0)
  eq(vim.bo[buf].modified, true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), edited)
end)

test(":w in one view saves the edits of every modified view in one plan (R5.2)", function()
  local env = setup({ answer = true })
  local area = open_area("P/Team/B")
  edit(area, "Update docs", "Update the docs")
  local item = open_item(100)
  edit(item, "Write API", "Write the API")
  write(item)
  eq(env.summaries[1].lines, { "Save 2 changes to Azure DevOps?", "Field changes",
    "  #101 title: 'Write API' -> 'Write the API'", "  #104 title: 'Update docs' -> 'Update the docs'" })
  eq(#env.fake.writes, 2)
  eq(vim.bo[area].modified, false)
  eq(vim.bo[item].modified, false)
end)

test("saving one view never discards unsaved edits in a view outside the save", function()
  local env = setup({ answer = false })
  local a = open_area("P/Team/A")
  edit(a, "Write API", "Write the API")
  local b = open_area("P/Team/B")
  write(b)
  eq(#env.fake.writes, 0)
  eq(vim.bo[a].modified, true)
  ok(vim.tbl_contains(shown(a), "Write the API"))
end)

test("the item view's title line and state line save the title and the state", function()
  local env = setup({ answer = true })
  local buf = open_item(102)
  edit(buf, "Add tests", "Add more tests")
  edit(buf, "state:    Doing", "state:    Done")
  write(buf)
  eq(env.summaries[1].lines, { "Save 2 changes to Azure DevOps?", "Field changes",
    "  #102 title: 'Add tests' -> 'Add more tests'", "  #102 state: Doing -> Done" })
  eq(env.fake.items[102].fields["System.Title"], "Add more tests")
  eq(env.fake.items[102].fields["System.State"], "Done")
  eq(env.fake.counts.patch_work_item, 1, "both changes to #102 are one write")
  eq(shown(buf)[1], "Add more tests")
  eq(shown(buf)[4], "state: Done")
end)

test("a type line edit whose current state the new type lacks is rejected, with no calls (R5.22)", function()
  local env = setup({ answer = true })
  local buf = open_item(102)
  edit(buf, "type:     Task", "type:     Bug")
  local calls = #env.fake.calls
  write(buf)
  eq(env.summaries[1].can_apply, false)
  eq(env.summaries[1].lines[1], "Save rejected: 1 problem, nothing will be sent")
  ok(env.summaries[1].lines[3]:find("Bug has no state 'Doing'", 1, true), env.summaries[1].lines[3])
  eq(#env.fake.calls, calls)
  eq(vim.bo[buf].modified, true)
end)

-- Replaces `from` with `to` in the line that shows the title `title`.
local function edit_row(buf, title, from, to)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(" │ " .. title .. " ", 1, true) then
      local s, e = l:find(from, 1, true)
      assert(s, "no " .. from .. " in " .. l)
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { l:sub(1, s - 1) .. to .. l:sub(e + 1) })
      return
    end
  end
  error("no row " .. title)
end

test("assignee and tags edits in an area view resolve, save, and reload showing the new values", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit_row(buf, "Write API", "Me Myself", "alex j")
  edit_row(buf, "Write API", "api; backend", "backend; urgent")
  write(buf)
  eq(env.summaries[1], { lines = { "Save 2 changes to Azure DevOps?", "Field changes",
    "  #101 assignee: 'Me Myself' -> 'Alex Jones <alex.jones@example.com>'",
    "  #101 tags: added 'urgent'; removed 'api'" }, can_apply = true })
  eq(#env.fake.writes, 1)
  eq(env.fake.items[101].fields["System.AssignedTo"].uniqueName, "alex.jones@example.com")
  eq(vim.bo[buf].modified, false)
  local line
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find("Write API", 1, true) then line = l end
  end
  ok(line:find("Alex Jones", 1, true) and line:find("backend; urgent", 1, true), line)
end)

test("an ambiguous assignee rejects the save before the summary can apply, with no writes", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit_row(buf, "Write API", "Me Myself", "Alex")
  write(buf)
  eq(env.summaries[1].can_apply, false)
  ok(env.summaries[1].lines[3]:find("'Alex' matches 2 identities", 1, true), env.summaries[1].lines[3])
  eq(#env.fake.writes, 0)
  eq(vim.bo[buf].modified, true)
end)

test("a type column edit saves as a type change, and the audit log records it", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit_row(buf, "Write API", "Task", "Bug ")
  edit_row(buf, "Write API", "To Do", "New")
  write(buf)
  eq(env.summaries[1].lines[2], "Type changes: check these, ADO drops fields the new type does not have")
  eq(env.summaries[1].lines[3], "  #101 type: Task -> Bug, state: To Do -> New")
  eq(#env.fake.writes, 1)
  local logged = audit_lines(env)
  local c = logged[1].changes[1]
  eq({ c.op, c.from, c.to, c.state_from, c.state_to }, { "set_type", "Task", "Bug", "To Do", "New" })
end)

test("an area view's record carries its filters, so the plan can warn about items they hide (R5.13)", function()
  local env = setup({ answer = false })
  local buf = open_area("P/Team/B")
  env.area_view.open(require("ado.core.location").with_filters(env.area_view.state(buf).location,
    { types = { "Task" } }))
  local typed = vim.api.nvim_get_current_buf()
  local record = env.area_view.record(typed)
  eq(record.filters.types, { "Task" })
end)

test("A0001-9 in the views: delete-only in an area view sends nothing, says no change, and reloads", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  cursor_to("Fix login")
  vim.cmd("normal! dd")
  write(buf)
  eq(#env.summaries, 0, "nothing to accept")
  eq(#env.fake.writes, 0)
  eq(#env.notes, 1)
  eq(last_note(env), "[ado] nothing to save: #103 deleted from " .. vim.api.nvim_buf_get_name(buf)
    .. " only: no change, because every work item needs an area path; paste it into another area view to move it")
  eq(vim.bo[buf].modified, false)
  ok(vim.tbl_contains(shown(buf), "Fix login"), "the row is back")
end)

test("A0001-24 in the views: a stale revision fails without writing, and the view reloads", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  env.fake:edit_remotely(101, { ["System.Title"] = "Renamed in the web UI" })
  edit(buf, "Write API", "Write the API")
  write(buf)
  eq(#env.fake.writes, 0)
  eq(#env.notes, 1)
  eq(env.notes[1].level, vim.log.levels.ERROR)
  eq(last_note(env), "[ado] save stopped at #101: 0 of 1 work item saved, 0 not attempted; the report shows why")
  eq(env.reports, { { "Save stopped: 0 of 1 work item saved, 1 failed, 0 not attempted",
    "Failed: nothing was written to #101", "  #101 title: 'Write API' -> 'Write the API'",
    "  error: #101 changed remotely (rev 1 -> 2); the view reloads to show the change" } })
  eq(vim.bo[buf].modified, false)
  ok(vim.tbl_contains(shown(buf), "Renamed in the web UI"))
  eq(audit_lines(env)[1].result, "failed")
end)

test("A0001-23 in the views: a failure part way stops, reports, and reloads the affected views", function()
  local env = setup({ answer = true })
  env.fake:fail_on("patch_work_item", 2, { kind = "failed", message = "ADO is down" })
  local a = open_area("P/Team/A")
  edit(a, "Write API", "Write the API")
  edit(a, "Add tests", "Add the tests")
  edit(a, "Fix login", "Fix the login")
  write(a)
  eq(env.fake.counts.patch_work_item, 2)
  eq(#env.notes, 1, "the transport error is in the report, not a message of its own")
  eq(last_note(env), "[ado] save stopped at #102: 1 of 3 work items saved, 1 not attempted; the report shows why")
  eq(env.reports, { { "Save stopped: 1 of 3 work items saved, 1 failed, 1 not attempted",
    "Completed", "  #101 title: 'Write API' -> 'Write the API'",
    "Failed: nothing was written to #102", "  #102 title: 'Add tests' -> 'Add the tests'", "  error: ADO is down",
    "Not attempted", "  #103 title: 'Fix login' -> 'Fix the login'" } })
  eq(vim.bo[a].modified, false, "the view shows ADO again")
  ok(vim.tbl_contains(shown(a), "Write the API"))
  ok(vim.tbl_contains(shown(a), "Add tests"))
  eq(#audit_lines(env), 2)
end)

test("an unmodified view that shows a saved item reloads too", function()
  local env = setup({ answer = true })
  local item = open_item(100)
  local area = open_area("P/Team/A")
  edit(area, "Write API", "Write the API")
  write(area)
  eq(#env.fake.writes, 1)
  ok(vim.tbl_contains(shown(item), "Write the API"))
end)

test("expanding or collapsing in a view with unsaved edits is refused and keeps the edits", function()
  local env = setup({ answer = true })
  local buf = open_item(100)
  edit(buf, "Write API", "Write the API")
  local edited = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local calls = #env.fake.calls
  cursor_to("Add tests")
  key("<Tab>")
  eq(#env.fake.calls, calls)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), edited)
  eq(vim.bo[buf].modified, true)
  eq(last_note(env), "[ado] this view has unsaved edits; save them (:w) or reload (<leader>wr)"
    .. " before expanding or collapsing rows")
  key("<leader>wt")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), edited)
end)

test("an expansion made before editing is part of the snapshot; its rows save like any other", function()
  local env = setup({ answer = true })
  local buf = open_item(100)
  cursor_to("Add tests")
  key("<Tab>")
  edit(buf, "Test fixtures", "Test fixture data")
  write(buf)
  eq(env.summaries[1].lines[3], "  #106 title: 'Test fixtures' -> 'Test fixture data'")
  eq(env.fake.items[106].fields["System.Title"], "Test fixture data")
end)

test("reload with unsaved edits asks first; keeping them makes no call", function()
  local env = setup({ answer = true })
  local buf = open_area("P/Team/A")
  edit(buf, "Write API", "Write the API")
  local choice
  vim.ui.select = function(items, _, cb)
    eq(items, { "Discard the edits and reload", "Keep editing" })
    cb(choice)
  end
  choice = "Keep editing"
  local calls = #env.fake.calls
  key("<leader>wr")
  eq(#env.fake.calls, calls)
  eq(vim.bo[buf].modified, true)
  choice = "Discard the edits and reload"
  key("<leader>wr")
  ok(#env.fake.calls > calls)
  eq(vim.bo[buf].modified, false)
  ok(vim.tbl_contains(shown(buf), "Write API"))
end)

test("going back to an item view with unsaved edits shows the edits", function()
  setup({ answer = true })
  local buf = open_item(100)
  edit(buf, "Write API", "Write the API")
  cursor_to("Payments story")
  key("<CR>")
  ok(vim.api.nvim_get_current_buf() ~= buf)
  key("[h")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(vim.bo[buf].modified, true)
  ok(vim.tbl_contains(shown(buf), "Write the API"))
end)

test("a save waits while a view is loading", function()
  local env = setup({ answer = true })
  local a = open_area("P/Team/A")
  edit(a, "Write API", "Write the API")
  env.fake.mode = "deferred"
  open_area("P/Team/B")
  write(a)
  eq(#env.summaries, 0)
  ok(last_note(env):find("finishes loading, then save again", 1, true), last_note(env))
  env.fake:flush()
  ok(vim.bo[a].modifiable)
end)

test("a view is not editable while it loads", function()
  local env = setup({ answer = true })
  env.fake.mode = "deferred"
  local buf = open_area("P/Team/A")
  eq(vim.bo[buf].modifiable, false)
  env.fake:flush()
  eq(vim.bo[buf].modifiable, true)
end)

test("u right after a load does not undo the load", function()
  setup({ answer = true })
  local buf = open_area("P/Team/A")
  local loaded = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.cmd("silent! undo")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), loaded)
  eq(vim.bo[buf].modified, false)
end)

test(":w opens the real summary float and leaves the cursor in it, so y answers it", function()
  local env = setup()
  require("ado.nvim.save").confirm = require("ado.nvim.summary_ui").open
  local buf = open_area("P/Team/A")
  edit(buf, "Fix login", "Fix the login")
  vim.api.nvim_feedkeys(vim.keycode(":w<CR>"), "tx", false)
  vim.wait(20)
  local win = vim.api.nvim_get_current_win()
  eq(vim.api.nvim_win_get_config(win).relative, "editor", "the cursor is in the float")
  local writes = #env.fake.calls
  views.key("y")
  vim.wait(20)
  ok(#env.fake.calls > writes, "y applied the save")
  eq(vim.bo[buf].modified, false)
end)

test("a save of several work items leaves exactly one line in :messages, and opens no report", function()
  local env = setup({ answer = true })
  require("ado.nvim.progress").echo = views.real_echo()
  vim.notify = views.history_notify
  local area = open_area("P/Team/A")
  edit(area, "Fix login", "Fix the login")
  edit(area, "Add tests", "Add the tests")
  open_item(100)
  cursor_to("Children: 2")
  key("oWrite the changelog<Esc>")
  vim.cmd("messages clear")
  write(area)
  eq(#env.fake.writes, 3)
  local history = vim.split(vim.api.nvim_exec2("messages", { output = true }).output, "\n", { trimempty = true })
  eq(history, { "[ado] saved 3 changes to 3 work items: 2 field updates, 1 created (#1000)" })
  eq(env.reports, {})
end)

test("a save that stops opens its report in a float that q closes, with one line in :messages", function()
  local env = setup({ answer = true })
  require("ado.nvim.save").show_report = require("ado.nvim.summary_ui").report
  vim.notify = views.history_notify
  env.fake:fail_on("patch_work_item", 1, { kind = "failed", message = "ADO is down" })
  local buf = open_area("P/Team/A")
  edit(buf, "Fix login", "Fix the login")
  vim.cmd("messages clear")
  write(buf)
  local win = vim.api.nvim_get_current_win()
  local config = vim.api.nvim_win_get_config(win)
  eq({ config.relative, config.title[1][1], config.footer[1][1] }, { "editor", " ado: save report ", " q close " })
  eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), {
    "Save stopped: 0 of 1 work item saved, 1 failed, 0 not attempted", "Failed: nothing was written to #103",
    "  #103 title: 'Fix login' -> 'Fix the login'", "  error: ADO is down" })
  local history = vim.split(vim.api.nvim_exec2("messages", { output = true }).output, "\n", { trimempty = true })
  eq(history, { "[ado] save stopped at #103: 0 of 1 work item saved, 0 not attempted; the report shows why" })
  key("q")
  eq(vim.api.nvim_win_is_valid(win), false)
end)
