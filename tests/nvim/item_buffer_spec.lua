-- The item buffer of RFC 0003 phase 1 on the fake gateway: the details
-- below the `── Details` row, the read-only guard, the description staged
-- for :w, and adding a comment.
local views = require("tests.support.views")
local key, cursor_to = views.key, views.cursor_to

local function setup(opts)
  opts = opts or {}
  local env = views.fresh({ seed = opts.seed, write_guard = opts.write_guard })
  env.summaries = {}
  env.answer = opts.answer
  require("ado.nvim.save").confirm = function(lines, can_apply, cb)
    local text = {}
    for _, l in ipairs(lines) do table.insert(text, l.text) end
    table.insert(env.summaries, { lines = text, can_apply = can_apply })
    cb(env.answer)
  end
  require("ado.nvim.save").show_report = function() end
  return env
end

local function open_item(id)
  require("ado").item_view(id)
  return vim.api.nvim_get_current_buf()
end

local function write(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  vim.wait(20)
end

-- Runs a Normal-mode change and the TextChanged headless Neovim does not
-- fire by itself.
local function change(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_get_current_buf() })
end

local function local_minute(iso)
  return os.date("%Y-%m-%d %H:%M", require("ado.core.timestamp").parse(iso))
end

local function with_items(edit)
  local seed = require("tests.fixtures.seed")
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  d.items = {}
  for _, it in ipairs(seed.items) do
    local copy = {}
    for k, v in pairs(it) do copy[k] = v end
    table.insert(d.items, copy)
  end
  edit(d.items)
  return d
end

-- The line (1-based) of the first read-only line equal to text.
local function readonly_line(buf, text)
  local region = require("ado.nvim.region")
  for i, l in ipairs(views.readonly_lines(buf)) do
    if l == text then return region.last_row(buf) + i end
  end
  error("no read-only line " .. text)
end

-- Opens the description float, replaces its text, and confirms with <C-s>.
local function edit_description(lines)
  key("<leader>wd")
  local fbuf = vim.api.nvim_get_current_buf()
  ok(vim.api.nvim_win_get_config(0).relative ~= "", "the float has the cursor")
  eq(vim.bo[fbuf].filetype, "markdown")
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  key("<C-s>")
end

local function signs(buf)
  local out = {}
  for _, ns in ipairs({ "ado_details", "ado_decorations" }) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()[ns], 0, -1,
      { details = true })) do
      if m[4].sign_text then out[m[2] + 1] = vim.trim(m[4].sign_text) end
    end
  end
  return out
end

test("C1.1 C3.1 the header is followed by the Details row, the changed line and the description", function()
  setup()
  local buf = open_item(100)
  local shown = views.shown(buf)
  eq(shown[#shown], "Details", "the rows end with the boundary row")
  eq(views.readonly_lines(buf), {
    "    changed:   " .. local_minute("2026-10-01T09:00:00Z") .. " · rev 1",
    "    description:",
    "    <p>Let customers pay at checkout.</p>",
    "── Comments: none",
  })
  eq(vim.bo[buf].modified, false)
  open_item(105)
  eq(views.readonly_lines(0)[2], "    description: (none)")
end)

test("C2.1 the view record holds the header rows and the boundary row, nothing below", function()
  setup()
  local buf = open_item(100)
  local record = require("ado.nvim.item_view").record(buf)
  local last = record.current[#record.current]
  eq({ last.kind, last.label }, { "heading", "Details" })
  eq(#record.current, require("ado.nvim.region").last_row(buf))
  eq(record.readonly_changed, nil)
  eq(record.description, nil)
end)

test("A8 deleting a description line rejects the save and sends nothing for any view", function()
  local env = setup({ answer = true })
  require("ado").area_view("P/Team/B")
  local area = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(area, 0, -1, false, vim.tbl_map(function(l)
    return (l:gsub("Update docs", "Update the docs"))
  end, vim.api.nvim_buf_get_lines(area, 0, -1, false)))
  local buf = open_item(100)
  vim.api.nvim_win_set_cursor(0, { readonly_line(buf, "    <p>Let customers pay at checkout.</p>"), 0 })
  change("dd")
  write(buf)
  eq(#env.summaries, 1)
  eq(env.summaries[1].can_apply, false)
  ok(table.concat(env.summaries[1].lines, "\n"):find(
    "the details and comments are read-only; u undoes the change, <leader>wr reloads", 1, true),
    table.concat(env.summaries[1].lines, "\n"))
  eq(#env.fake.writes, 0, "not even the area view's retitle")
  eq(vim.bo[buf].modified, true, "the edits stay")
  change("u")
  write(buf)
  eq(env.summaries[2].can_apply, true, "after u only the area view's edit is left")
  eq(#env.fake.writes, 1)
end)

test("A9 a row pasted below the Details row rejects the save; the item gains no link", function()
  local env = setup({ answer = true })
  local buf = open_item(100)
  cursor_to("Write API")
  vim.cmd("normal! yy")
  vim.cmd("normal! G")
  change("p")
  write(buf)
  eq(env.summaries[1].can_apply, false)
  eq(#env.fake.writes, 0)
  eq(#env.fake.items[100].relations, 3, "two children and one Related link, as seeded")
end)

test("A10 deleting the Details row rejects the save as a deleted fixed line", function()
  local env = setup({ answer = true })
  local buf = open_item(100)
  cursor_to("Details")
  change("dd")
  write(buf)
  local text = table.concat(env.summaries[1].lines, "\n")
  eq(env.summaries[1].can_apply, false)
  ok(text:find("this line was deleted", 1, true), text)
  eq(#env.fake.writes, 0)
end)

test("A13 read-only lines that look like rows get no sign, re-pad or concealing", function()
  setup({ seed = with_items(function(items)
    items[1].description = "<p>Task │ To Do │ looks like a row │ │</p>"
  end) })
  local buf = open_item(100)
  local view_buffer = require("ado.nvim.view_buffer")
  local fake_row = "/1 Task │ To Do │ a row the plugin wrote │ │"
  local n = vim.api.nvim_buf_line_count(buf)
  view_buffer.replace_readonly(buf, n, n, { fake_row, "Task│To Do│x│y│z" })
  local before = views.readonly_lines(buf)
  cursor_to("Write API")
  change("A more<Esc>")
  eq(views.readonly_lines(buf), before, "a header edit re-pads no read-only line")
  local concealed = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_view, 0, -1, {})
  for _, m in ipairs(concealed) do
    ok(m[2] < require("ado.nvim.region").last_row(buf), "no conceal on read-only line " .. (m[2] + 1))
  end
  local s = signs(buf)
  for line in pairs(s) do
    ok(line <= require("ado.nvim.region").last_row(buf), "no sign on read-only line " .. line)
  end
  eq(s[cursor_to("Write API")], "~", "the edited row has its sign")
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf) - 1, 4 })
  eq(require("ado.nvim.complete").target(buf, vim.api.nvim_buf_line_count(buf) - 1, 5), nil,
    "no menu target below the header")
end)

test("A14 a changed description is staged: no write, the buffer is modified, :w sends one patch with the header edits", function()
  local env = setup({ answer = true })
  local buf = open_item(100)
  cursor_to("Checkout story")
  change("A now<Esc>")
  edit_description({ "Let customers pay at checkout.", "", "-   Cards first." })
  eq(#env.fake.writes, 0, "confirming writes nothing")
  eq(vim.bo[buf].modified, true)
  eq(views.readonly_lines(buf)[3], "    Let customers pay at checkout.")
  eq(views.readonly_lines(buf)[5], "    -   Cards first.")
  local s = signs(buf)
  local first = require("ado.nvim.region").last_row(buf) + 2
  for line = first, first + 3 do eq(s[line], "~", "line " .. line) end
  write(buf)
  local text = table.concat(env.summaries[1].lines, "\n")
  ok(text:find("#100 description changed: 3 lines added, 1 line removed", 1, true), text)
  ok(text:find("#100 title: 'Checkout story' -> 'Checkout story now'", 1, true), text)
  eq(#env.fake.writes, 1)
  local patch = env.fake.writes[1].params.patch
  eq(patch[1], { op = "test", path = "/rev", value = 1 })
  local paths = {}
  for _, p in ipairs(patch) do paths[p.path] = p.value end
  eq(paths["/fields/System.Description"], "Let customers pay at checkout.\n\n-   Cards first.",
    "without pandoc, the markdown as it is")
  eq(paths["/fields/System.Title"], "Checkout story now")
  eq(vim.bo[buf].modified, false)
  eq(views.readonly_lines(buf)[3], "    Let customers pay at checkout.", "the reload shows the saved description")
end)

test("A15 confirming the description unchanged stages nothing", function()
  local env = setup()
  local buf = open_item(100)
  edit_description({ "<p>Let customers pay at checkout.</p>" })
  eq(vim.bo[buf].modified, false)
  eq(env.notes[#env.notes].msg, "[ado] description unchanged")
  write(buf)
  eq(#env.summaries, 0)
end)

test("C3.2 <CR> on a description line opens the float; on the changed line it does nothing", function()
  setup()
  local buf = open_item(100)
  vim.api.nvim_win_set_cursor(0, { readonly_line(buf, "    description:"), 0 })
  key("<CR>")
  ok(vim.api.nvim_win_get_config(0).relative ~= "", "the description float")
  key("q")
  eq(vim.api.nvim_get_current_buf(), buf)
  vim.api.nvim_win_set_cursor(0, { require("ado.nvim.region").last_row(buf) + 1, 0 })
  key("<CR>")
  eq(vim.api.nvim_get_current_buf(), buf)
end)

test("C2.6 C2.7 staging the description keeps the header's undo history and adds no undo step", function()
  setup()
  local buf = open_item(100)
  local loaded = views.row_lines(buf)
  cursor_to("Checkout story")
  change("A now<Esc>")
  ok(vim.tbl_contains(views.shown(buf), "Checkout story now"))
  local seq = vim.fn.undotree().seq_cur
  edit_description({ "Pay at checkout." })
  eq(vim.fn.undotree().seq_cur, seq, "no undo step for the staging")
  change("u")
  eq(views.row_lines(buf), loaded, "u undoes the title edit")
  eq(views.readonly_lines(buf)[3], "    Pay at checkout.", "and leaves the staged description")
  vim.wait(20)
  eq(vim.bo[buf].modified, true, "the staged description keeps the buffer modified")
  eq(require("ado.nvim.ux_stats").get().quiet_write_failed, nil)
end)

test("A25 <leader>wr with a staged description asks before discarding it", function()
  setup()
  local buf = open_item(100)
  edit_description({ "Pay at checkout." })
  local asked
  local select = vim.ui.select
  vim.ui.select = function(_, opts, cb)
    asked = opts.prompt
    cb("Keep editing")
  end
  key("<leader>wr")
  vim.ui.select = select
  eq(asked, "This view has unsaved edits")
  eq(views.readonly_lines(buf)[3], "    Pay at checkout.")
end)

test("A23 Insert mode on a read-only line ends at once, with a message", function()
  -- Headless Neovim reads typed keys only through feedkeys, which leaves
  -- Insert mode by itself; the real-UI check covers the mode, this spec
  -- the InsertEnter guard and its message.
  local env = setup()
  local buf = open_item(100)
  vim.api.nvim_win_set_cursor(0, { readonly_line(buf, "    description:"), 0 })
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_feedkeys("i", "xt", false)
  vim.wait(50, function() return #env.notes > 0 end)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
  ok(#env.notes == 1 and env.notes[1].msg:find("read-only", 1, true), vim.inspect(env.notes))
  cursor_to("Write API")
  vim.api.nvim_feedkeys("i", "xt", false)
  vim.wait(20)
  eq(#env.notes, 1, "no message in the header")
end)

test("the write guard stays in front of a description write", function()
  local env = setup({ answer = true, write_guard = { area = "P\\Team\\B" } })
  local buf = open_item(100)
  edit_description({ "Pay at checkout." })
  write(buf)
  eq(#env.fake.writes, 0, "#100 is in P\\Team\\A, outside the allowed area")
  eq(env.fake.items[100].fields["System.Description"], "<p>Let customers pay at checkout.</p>")
end)

test("Q5 <leader>wc sends a multi-line comment at once through the write guard, then reloads", function()
  local env = setup({ write_guard = { area = "P\\Team" } })
  local buf = open_item(100)
  key("<leader>wc")
  local fbuf = vim.api.nvim_get_current_buf()
  ok(vim.api.nvim_win_get_config(0).relative ~= "", "a float")
  eq(vim.bo[fbuf].filetype, "markdown")
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { "Looks good.", "", "Ship it." })
  key("<C-s>")
  eq(#env.fake.writes, 1)
  eq(env.fake.writes[1].op, "add_comment")
  eq(env.fake.writes[1].params.text, "Looks good.\n\nShip it.")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(require("ado.nvim.item_view").state(buf).view.item.rev, env.fake.items[100].rev, "the header reloaded")
end)

test("<leader>wc is refused while the buffer has unsaved edits, and on an Issue by the write guard", function()
  local env = setup({ write_guard = { area = "P\\Team", deny_types = { "Issue" } } })
  open_item(100)
  cursor_to("Write API")
  change("A more<Esc>")
  key("<leader>wc")
  eq(vim.api.nvim_win_get_config(0).relative, "", "no float")
  ok(env.notes[#env.notes].msg:find("save (:w) or reload", 1, true), env.notes[#env.notes].msg)
  open_item(111)
  key("<leader>wc")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "paging test" })
  key("<C-s>")
  eq(#env.fake.writes, 0)
  ok(env.notes[#env.notes].msg:find("write guard refused add_comment", 1, true), env.notes[#env.notes].msg)
end)

test("C2.5 ic, <leader>wx and the cut-cell float do nothing on a read-only line that looks like a row", function()
  local env = setup()
  local buf = open_item(100)
  local n = vim.api.nvim_buf_line_count(buf)
  require("ado.nvim.view_buffer").replace_readonly(buf, n, n, { "Task │ To Do │ quoted │ │" })
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_win_set_cursor(0, { n + 1, 8 })
  change("dic")
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "dic deletes nothing")
  key("<leader>wx")
  ok(env.notes[#env.notes].msg:find("this line has no cells", 1, true), env.notes[#env.notes].msg)
end)

test("C2.5 a resize refits the header of an unmodified item buffer and leaves the read-only lines", function()
  setup()
  vim.o.columns, vim.o.lines = 80, 24
  vim.cmd("vsplit")
  vim.cmd("only")
  local buf = open_item(100)
  local wide, below = views.row_lines(buf), views.readonly_lines(buf)
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, 40)
  require("ado.nvim.view_buffer").refit(buf)
  ok(not vim.deep_equal(views.row_lines(buf), wide), "the rows were laid out again")
  eq(views.readonly_lines(buf), below)
  eq(vim.bo[buf].modified, false)
end)

test("staging the description keeps the header's end-of-line labels on their lines", function()
  setup()
  local buf = open_item(100)
  cursor_to("Write API")
  change("A more<Esc>")
  local function labels()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_view_labels, 0, -1,
      { details = true })) do
      out[m[2]] = m[4].virt_text[1][1]
    end
    return out
  end
  local before = labels()
  edit_description({ "Pay at checkout." })
  eq(labels(), before)
  eq(before[0], "this item")
end)
