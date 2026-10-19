-- The people menu of assignee cells (plan 0002 UX6.1 to UX6.3, UX6.5 to
-- UX6.7). Keys are fed with nvim_feedkeys, which leaves Insert mode once
-- they run out, so mapped keys act inside one Insert session: <F2> reads
-- the menu, <F3> delivers the fake's deferred answers, <F4> stands for
-- the TextChangedP that headless Neovim does not fire after a typed key,
-- <F5> lets the debounce timer run, and <F6> moves the cursor one line
-- down without leaving Insert mode or touching the menu.
local lines = require("ado.nvim.lines")
local C = require("ado.core.table_layout").INDEX
local people = require("ado.nvim.people")
local views = require("tests.support.views")
local cursor_to = views.cursor_to

local menu
local debounce = people.DEBOUNCE_MS

local function setup(opts)
  local env = views.fresh(opts)
  -- A popup menu drawn outside the 80 by 24 screen of headless Neovim
  -- crashed a run (complete_spec.lua).
  vim.o.columns, vim.o.lines = 80, 24
  vim.cmd("vsplit")
  vim.cmd("only")
  vim.o.completeopt = "menu,popup"
  vim.g.mapleader = "\\"
  people.DEBOUNCE_MS = 0
  menu = nil
  local fake = env.fake
  vim.keymap.set("i", "<F2>", function()
    local info = vim.fn.complete_info({ "items", "pum_visible", "selected" })
    menu = { visible = info.pum_visible == 1, words = {}, names = {}, selected = info.selected }
    for _, it in ipairs(info.items) do
      table.insert(menu.words, it.word)
      table.insert(menu.names, it.abbr)
    end
  end)
  vim.keymap.set("i", "<F3>", function() fake:flush() end)
  vim.keymap.set("i", "<F4>", function()
    vim.api.nvim_exec_autocmds("TextChangedP", { buffer = vim.api.nvim_get_current_buf() })
  end)
  vim.keymap.set("i", "<F5>", function() vim.wait(20) end)
  vim.keymap.set("i", "<F6>", function()
    local at, col = unpack(vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_win_set_cursor(0, { at + 1, col })
  end)
  return env
end

local function teardown()
  people.DEBOUNCE_MS = debounce
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

-- The row's values, as the save reads them: an email wider than the
-- assignee column is cut in the buffer (plan 0002 UX4.2).
local function row_text(row)
  return require("ado.nvim.fit").read(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]).values
end

local function searches(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do
    if c.op == "resolve_identity" then table.insert(out, c.params.text) end
  end
  return out
end

-- Runs fn, then restores the debounce, also when fn fails.
local function spec(name, fn)
  test(name, function()
    local ok_run, err = pcall(fn)
    teardown()
    assert(ok_run, err)
  end)
end

spec("UX6.1 <C-Space> in an assignee cell lists the people on loaded rows at once, with no call", function()
  local env = setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cic<C-Space><F2><Esc>")
  ok(menu.visible, "the menu is open")
  eq(menu.names, { "Alex Smith", "Me Myself" })
  eq(menu.words, { "alex.smith@example.com", "me@example.com" })
  eq(searches(env.fake), {})
end)

spec("UX6.1 a cell holding a whole name offers everyone, and searches nothing", function()
  local env = setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("i<C-Space><F5><F2><Esc>")
  eq(menu.names, { "Alex Smith", "Me Myself" })
  eq(searches(env.fake), {})
end)

spec("UX6.2 text typed before <C-Space> narrows the list, by any word of the name", function()
  setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cicsmi<C-Space><F2><Esc>")
  eq(menu.names, { "Alex Smith" })
end)

spec("UX6.2 items carry equal = 1, so Neovim keeps a name match whose email does not start with the text", function()
  setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cic<C-Space>Smi<F2><Esc>")
  ok(menu.visible, "the menu is still open")
  eq(menu.words, { "alex.smith@example.com", "me@example.com" }, "no item was dropped by Neovim's own filter")
  key("cic<C-Space>Smi<F4><F2><Esc>")
  eq(menu.names, { "Alex Smith" }, "the plugin narrows the list itself")
end)

spec("UX6.3 after the debounce, ADO's answer is merged into the open menu", function()
  local env = setup()
  local buf = open_area()
  local row = to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><F2><Esc>")
  eq(searches(env.fake), { "al" })
  eq(menu.names, { "Alex Smith", "Alex Jones" }, "the loaded row's person first, then ADO's")
  eq(menu.words, { "alex.smith@example.com", "alex.jones@example.com" })
  eq(row_text(row).assignee, "al", "nothing is inserted until a person is picked")
  ok(env.echoes[#env.echoes]:match("^people 'al': 2 found in %d+%.%d%d s$"), env.echoes[#env.echoes])
  ok(require("ado.nvim.ux_stats").get().people_search.found == 2)
  ok(vim.bo[buf].completeopt:find("noselect"), "the view's menus insert nothing until one is picked")
end)

spec("UX6.3 one character searches nothing", function()
  local env = setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cic<C-Space>a<F4><F5><F2><Esc>")
  eq(searches(env.fake), {})
  eq(menu.names, { "Alex Smith" })
end)

spec("UX6.4 while the search runs, the answer to a shorter text is filtered and shown", function()
  local env = setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><Esc>")
  env.fake.mode = "deferred"
  key("cic<C-Space>alex j<F4><F5><F2><Esc>")
  eq(menu.names, { "Alex Jones" }, "from the cached answer to al")
  eq(searches(env.fake), { "al", "alex j" })
  env.fake:flush()
  env.fake.mode = nil
end)

spec("UX6.3 a deferred answer reaches a menu still open in the same cell", function()
  local env = setup()
  open_area()
  env.fake.mode = "deferred"
  to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><F2><F3><F2><Esc>")
  eq(menu.names, { "Alex Smith", "Alex Jones" })
  env.fake.mode = nil
end)

spec("UX6.3 an answer arriving on another line, after <Esc>, or for older text changes nothing", function()
  local env = setup()
  local buf = open_area()
  env.fake.mode = "deferred"
  local row = to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><F6><F3><F2><Esc>")
  eq(menu.names, { "Alex Smith" }, "the cursor left the row, so ADO's answer was not merged")

  to_cell("Write API", C.assignee)
  key("cic<C-Space>jo<F4><F5><Esc>")
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  env.fake:flush()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
  eq(people.is_open(), false)

  to_cell("Write API", C.assignee)
  key("cic<C-Space>ale<F4><F5><BS><BS><BS>me<F4><F3><F2><Esc>")
  eq(menu.names, { "Me Myself" }, "the answer to ale no longer fits the text me")
  eq(row_text(row).assignee, "me")
  env.fake.mode = nil
end)

spec("UX6.3 a person selected with <C-n> stays selected when a key or a late answer would refresh the menu", function()
  local env = setup()
  open_area()
  env.fake.mode = "deferred"
  local row = to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><C-n><F4><F3><F2><Esc>")
  eq(menu.selected, 0)
  eq(row_text(row).assignee, "alex.smith@example.com")
  env.fake.mode = nil
end)

spec("UX6.5 picking a person inserts the email, and :w saves it with no rejection", function()
  local env = setup()
  local buf = open_area()
  local summaries = {}
  require("ado.nvim.save").confirm = function(text, can_apply, cb)
    local out = {}
    for _, l in ipairs(text) do table.insert(out, l.text) end
    table.insert(summaries, { lines = out, can_apply = can_apply })
    cb(true)
  end
  local row = to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><C-n><C-n><C-y><Esc>")
  vim.wait(20)
  eq(row_text(row).assignee, "alex.jones@example.com")
  vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  vim.wait(50)
  eq(#summaries, 1)
  ok(summaries[1].can_apply, table.concat(summaries[1].lines, "\n"))
  ok(table.concat(summaries[1].lines, "\n"):find("Alex Jones <alex.jones@example.com>", 1, true),
    table.concat(summaries[1].lines, "\n"))
  local patch = env.fake.writes[1].params.patch
  local assigned
  for _, op in ipairs(patch) do
    if op.path == "/fields/System.AssignedTo" then assigned = op.value end
  end
  eq(assigned, "alex.jones@example.com")
  eq(env.fake.items[101].fields["System.AssignedTo"].displayName, "Alex Jones")
end)

spec("UX6.1 a person picked earlier in the session is offered first", function()
  setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5><C-n><C-n><C-y><Esc>")
  to_cell("Add tests", C.assignee)
  key("cic<C-Space><F2><Esc>")
  eq(menu.names, { "Alex Jones", "Alex Smith", "Me Myself" })
end)

spec("UX6.7 a failed search writes one message per Insert session", function()
  local env = setup()
  open_area()
  vim.notify = views.history_notify
  vim.cmd("messages clear")
  for i = 1, 3 do env.fake:fail_on("resolve_identity", i) end
  to_cell("Write API", C.assignee)
  key("cic<C-Space>al<F4><F5>e<F4><F5><Esc>")
  eq(searches(env.fake), { "al", "ale" })
  local messages = vim.split(vim.trim(vim.fn.execute("messages")), "\n")
  eq(messages, { "[ado] people search failed: fake failure on resolve_identity" })
  to_cell("Write API", C.assignee)
  key("cic<C-Space>xy<F4><F5><Esc>")
  messages = vim.split(vim.trim(vim.fn.execute("messages")), "\n")
  eq(#messages, 2, "a new Insert session reports again")
end)

spec("UX6.1 <C-Space> on the item view's assignee: line opens the people menu", function()
  setup()
  require("ado").item_view(100)
  local row = cursor_to("assignee: Me Myself")
  vim.api.nvim_win_set_cursor(0, { row, #vim.api.nvim_get_current_line() - 1 })
  key("a<C-Space><F2><Esc>")
  ok(menu.visible)
  eq(menu.words[#menu.words], "me@example.com")
  key("cic<C-Space>alex j<F4><F5><C-n><C-y><Esc>")
  ok(vim.tbl_contains(views.shown(), "assignee: alex.jones@example.com"), vim.inspect(views.shown()))
end)

spec("UX6.1 <C-x><C-u> in an assignee cell opens the same people menu", function()
  setup()
  open_area()
  to_cell("Write API", C.assignee)
  key("cic<C-x><C-u><F5><F2><Esc>")
  ok(menu.visible)
  eq(menu.names, { "Alex Smith", "Me Myself" })
end)

-- vim.ui.input answers `answer`; vim.ui.select picks the label `pick`.
local function stub_pickers(answer, pick)
  local asked = {}
  vim.ui.input = function(_, cb) cb(answer) end
  vim.ui.select = function(items, o, cb)
    asked.labels, asked.prompt = {}, o.prompt
    local chosen
    for _, it in ipairs(items) do
      table.insert(asked.labels, o.format_item(it))
      if o.format_item(it) == pick then chosen = it end
    end
    cb(chosen)
  end
  return asked
end

spec("UX6.6 <leader>we on an assignee cell asks for a name and writes the email of the person picked", function()
  local env = setup()
  open_area()
  local asked = stub_pickers("alex", "Alex Jones <alex.jones@example.com>")
  local row = to_cell("Write API", C.assignee)
  key("<leader>we")
  eq(asked.labels, { "Alex Smith <alex.smith@example.com>", "Alex Jones <alex.jones@example.com>", "unassign" })
  eq(row_text(row).assignee, "alex.jones@example.com")
  eq(env.echoes[#env.echoes], "assignee Alex Jones <alex.jones@example.com> on 1 row")
  key("u")
  eq(row_text(row).assignee, "Me Myself", "one u removes the write")
end)

spec("UX6.6 Visual <leader>we writes the person on every selected row, and unassign empties the cells", function()
  setup()
  open_area()
  local asked = stub_pickers("me", "Me Myself <me@example.com>")
  local first = cursor_to("Write API")
  local last = cursor_to("Add tests")
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  vim.cmd("normal! V")
  local ranges, offset = lines.row_ranges(vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1])
  vim.api.nvim_win_set_cursor(0, { last, offset + ranges[C.assignee].first - 1 })
  key("<leader>we")
  eq(asked.prompt, "Assignee for 2 rows")
  eq({ row_text(first).assignee, row_text(last).assignee }, { "me@example.com", "me@example.com" })
  stub_pickers("", "unassign")
  to_cell("Add tests", C.assignee)
  key("<leader>we")
  eq(row_text(last).assignee, "")
end)
