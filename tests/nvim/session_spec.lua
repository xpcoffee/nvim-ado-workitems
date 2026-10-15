-- nvim/session.lua builds the session from config: the write guard and error
-- reporting wrap whichever transport config supplies.
local Fake = require("tests.support.fake_transport")
local seed = require("tests.fixtures.seed")

local function fresh(opts)
  local fake = Fake.new(seed)
  opts.transport = fake
  opts.org = "test-org"
  if opts.projects == nil then opts.projects = false end
  require("ado.config").reset()
  require("ado.config").setup(opts)
  local session = require("ado.nvim.session")
  session.reset()
  local notes = {}
  vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
  return session, fake, notes
end

test("with write_guard set, a write outside the area is refused and reported", function()
  local session, fake, notes = fresh({ write_guard = { area = "P\\Team\\B" }, project = "P" })
  local item
  session.get():get(101, function(_, it) item = it end)
  local refused
  session.get():update_if_unchanged(item, { title = "x" }, function(err) refused = err end)
  eq(refused.kind, "invalid")
  eq(#fake.writes, 0)
  eq(notes[1].level, vim.log.levels.ERROR)
  ok(notes[1].msg:find("^%[ado%] write guard refused patch_work_item"), notes[1].msg)
end)

test("with write_guard off, the same write goes through", function()
  local session, fake = fresh({ write_guard = false, project = "P" })
  local item
  session.get():get(101, function(_, it) item = it end)
  session.get():update_if_unchanged(item, { title = "x" }, function(err) eq(err, nil) end)
  eq(#fake.writes, 1)
end)

test("ensure_project picks a project once and keeps it", function()
  local session, fake = fresh({ write_guard = false, project = false })
  local prompts = 0
  vim.ui.select = function(items, opts, on_choice)
    prompts = prompts + 1
    eq(items, { "P" })
    eq(opts.prompt, "ADO project")
    on_choice("P")
  end
  local results = {}
  session.ensure_project(function(ok_) table.insert(results, ok_) end)
  session.ensure_project(function(ok_) table.insert(results, ok_) end)
  eq(results, { true, true })
  eq(prompts, 1)
  eq(session.get().project, "P")
  eq(#fake.calls, 1)
end)

test("with projects configured, ensure_project neither prompts nor calls ADO", function()
  local session, fake = fresh({ write_guard = false, project = false,
    projects = { { name = "P", types = { "Task" } } } })
  vim.ui.select = function() error("must not prompt") end
  local result
  session.ensure_project(function(ok_) result = ok_ end)
  eq(result, true)
  eq(session.get():project_names(), { "P" })
  eq(#fake.calls, 0)
end)

test("the first catalog load is progress, kept out of :messages, and shown once", function()
  local session, _, notes = fresh({ write_guard = false, project = "P" })
  local echoes = {}
  require("ado.nvim.progress").echo = function(msg) table.insert(echoes, msg) end
  session.get():my_items(function() end)
  session.get():my_items(function() end)
  eq(notes, {})
  eq(echoes, { "loaded 4 work item types for P (1 call)" })
end)

test("configured types the project lacks are warned about once in :messages", function()
  local session, _, notes = fresh({ write_guard = false, project = false,
    projects = { { name = "P", types = { "Task", "Epik", "Storey" } } } })
  session.get():my_items(function() end)
  session.get():my_items(function() end)
  local warnings = {}
  for _, n in ipairs(notes) do
    if n.level == vim.log.levels.WARN then table.insert(warnings, n.msg) end
  end
  eq(warnings, { "[ado] types configured for project P that it does not have: 'Epik', 'Storey'; its types are"
    .. " Task, User Story, Bug, Issue" })
end)

test("open_categories from setup reach the session", function()
  local session = fresh({ write_guard = false, project = "P", open_categories = { "Proposed" } })
  local got
  session.get():my_items(function(_, items) got = items end)
  local ids = {}
  for _, it in ipairs(got) do table.insert(ids, it.id) end
  table.sort(ids)
  eq(ids, { 101, 103 })
end)
