-- The query list buffer on the fake gateway (RFC 0001 R9): "my work
-- items" opens it in the top window, selecting a row opens the item as
-- the area view does, the filters, reload, browser URL and toggle, and :w
-- with a row cut from it.
local views = require("tests.support.views")
local key, shown, cursor_to = views.key, views.shown, views.cursor_to

local MINE = "ado://query/mine?state=open&type=&tag="

local function mine()
  require("ado").my_items()
  return vim.api.nvim_get_current_buf()
end

local function confirm_all(env)
  env.summaries = {}
  require("ado.nvim.save").confirm = function(lines, can_apply, cb)
    local text = {}
    for _, l in ipairs(lines) do table.insert(text, l.text) end
    table.insert(env.summaries, { lines = text, can_apply = can_apply })
    cb(can_apply)
  end
  require("ado.nvim.save").show_report = function() end
end

test("A0001-31 my_items() opens the open items assigned to the user in an editable list named by its location",
  function()
    local env = views.fresh()
    local buf = mine()
    eq(vim.api.nvim_buf_get_name(buf), MINE)
    eq(vim.bo[buf].filetype, "adoquery")
    eq(vim.bo[buf].buftype, "acwrite")
    eq(vim.bo[buf].modifiable, true)
    eq(shown(buf), { "Resolved bug", "Fix login", "Write API", "Checkout story" })
    eq(vim.wo.winbar, "My work items  ·  state: open  ·  assignee: @Me  ·  type: any  ·  tag: any%=%#AdoCount#4 items%*")
    eq(env.layout.window("list"), vim.api.nvim_get_current_win())
    local first = require("ado.nvim.lines").parse(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    eq({ first.type, first.state, first.title, first.assignee, first.tags },
      { "Bug", "Resolved", "Resolved bug", "Me Myself", "" })
  end)

test("selecting a row opens its item buffer beneath the list, as the area view does", function()
  views.fresh()
  local list_win = vim.api.nvim_get_current_win()
  local buf = mine()
  cursor_to("Fix login")
  key("<CR>")
  eq(#vim.api.nvim_list_wins(), 2)
  local panel = vim.api.nvim_get_current_win()
  eq(views.buf_name(panel), "ado://item/103")
  eq(vim.api.nvim_win_get_buf(list_win), buf)
  local order = vim.fn.winlayout()
  eq({ order[2][1][2], order[2][2][2] }, { list_win, panel })
  key("[h")
  eq(vim.api.nvim_get_current_win(), list_win)
  eq(views.buf_name(), MINE)
end)

test("<leader>wf offers state, types and tag, and keeps the assignee fixed", function()
  local env = views.fresh()
  mine()
  local offered
  vim.ui.select = function(items, _, choose)
    offered = items
    choose("types")
  end
  vim.ui.input = function(_, answer) answer("Task") end
  key("<leader>wf")
  eq(offered, { "state", "types", "tag", "reset to defaults" })
  eq(views.buf_name(), "ado://query/mine?state=open&type=Task&tag=")
  eq(shown(0), { "Fix login", "Write API" })
  eq(env.query_view.state(0).location.filters.assignee, "@Me")
end)

test("<leader>wb opens the list's query in the browser; <leader>wr reloads with 1 call", function()
  local env = views.fresh()
  mine()
  key("<leader>wb")
  eq(#env.urls, 1)
  ok(env.urls[1]:find("^https://dev%.azure%.com/test%-org/P/_queries/query/%?wiql=SELECT"), env.urls[1])
  ok(env.urls[1]:find("%40Me", 1, true), env.urls[1])
  local calls = #env.fake.calls
  key("<leader>wr")
  eq(#env.fake.calls, calls + 1, "the catalog is cached")
end)

test("A0001-42 toggling the top window closes and reopens whichever list it showed last", function()
  local env = views.fresh()
  mine()
  cursor_to("Fix login")
  key("<CR>")
  require("ado").toggle_area_view()
  eq(env.layout.window("list"), nil)
  require("ado").toggle_area_view()
  local top = env.layout.window("list")
  eq(views.buf_name(top), MINE)
  eq(vim.fn.winlayout()[2][1][2], top, "on top")
  vim.api.nvim_set_current_win(top)
  require("ado").area_view("P/Team/A")
  eq(env.layout.window("list"), top, "the area view takes the same window")
  require("ado").toggle_area_view()
  require("ado").toggle_area_view()
  eq(views.buf_name(env.layout.window("list")), "ado://area/P/Team/A?state=open&type=&assignee=&tag=&sub=0")
end)

test("A0001-36 :w after cutting a row from the list and putting it in an area view moves the item there", function()
  local env = views.fresh()
  confirm_all(env)
  local q = mine()
  cursor_to("Fix login")
  vim.cmd("normal! dd")
  require("ado").area_view("P/Team/B")
  local b = vim.api.nvim_get_current_buf()
  cursor_to("Update docs")
  vim.cmd("normal! p")
  vim.api.nvim_buf_call(b, function() vim.cmd("write") end)
  vim.wait(20)
  eq(env.summaries[1].lines, { "Save 1 change to Azure DevOps?", "Parent and area changes",
    "  #103 'Fix login' area: P\\Team\\A -> P\\Team\\B" })
  eq(env.fake.items[103].fields["System.AreaPath"], "P\\Team\\B")
  eq(vim.bo[q].modified, false, "the list reloaded")
  ok(vim.tbl_contains(shown(q), "Fix login"), "the item is still mine, so the list shows it again")
end)

test("A0001-35 :w after putting a row into the list is rejected and sends nothing", function()
  local env = views.fresh()
  confirm_all(env)
  require("ado").area_view("P/Team/B")
  cursor_to("Update docs")
  vim.cmd("normal! yy")
  local q = mine()
  vim.cmd("normal! p")
  vim.api.nvim_buf_call(q, function() vim.cmd("write") end)
  vim.wait(20)
  eq(env.summaries[1].can_apply, false)
  ok(table.concat(env.summaries[1].lines, "\n"):find("a query list has no place to put an item", 1, true),
    table.concat(env.summaries[1].lines, "\n"))
  eq(#env.fake.writes, 0)
  eq(vim.bo[q].modified, true, "the edits stay")
end)
