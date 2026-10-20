-- Comments in the item buffer (RFC 0003 section 9) on the fake gateway:
-- paging by the trigger rule, one page in flight, stale responses, the
-- footer's states, undo and the modified flag, reloads and history.
local views = require("tests.support.views")
local key, cursor_to = views.key, views.cursor_to

local seed = require("tests.fixtures.seed")

-- The seed with item 100 holding n comments (newest is n), and opts:
-- children (extra children of 100), edit(comment).
local function seeded(n, opts)
  opts = opts or {}
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  d.items = {}
  for _, it in ipairs(seed.items) do
    local copy = {}
    for k, v in pairs(it) do copy[k] = v end
    table.insert(d.items, copy)
  end
  local list = {}
  for i = 1, n do
    list[i] = { id = i, text = "<p>comment " .. i .. "</p>", author = "alex.smith@example.com",
      created = string.format("2026-09-15T13:%02d:00.0000000Z", i) }
    if opts.edit then opts.edit(list[i]) end
  end
  d.items[1].comments = list
  for i = 1, opts.children or 0 do
    table.insert(d.items, { id = 2000 + i, type = "Task", title = "Child " .. i, state = "To Do",
      area = "P\\Team\\A", parent = 100, changed = "2026-10-01T09:00:00Z" })
  end
  return d
end

local function setup(n, opts)
  opts = opts or {}
  local env = views.fresh({ seed = seeded(n, opts) })
  env.summaries = {}
  require("ado.nvim.save").confirm = function(lines, can_apply, cb)
    table.insert(env.summaries, { lines = lines, can_apply = can_apply })
    cb(true)
  end
  require("ado.nvim.save").show_report = function() end
  if opts.deferred then env.fake.mode = "deferred" end
  return env
end

-- Opens item 100 in a window `height` lines tall and lets the scheduled
-- trigger check run.
local function open(height, id)
  require("ado").item_view(id or 100)
  if height then vim.api.nvim_win_set_height(0, height) end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.wait(20)
  return vim.api.nvim_get_current_buf()
end

local function calls(env)
  local n = 0
  for _, c in ipairs(env.fake.calls) do if c.op == "list_comments" then n = n + 1 end end
  return n
end

local function last_line(buf)
  return vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1]
end

-- The comment heading lines shown, as their comment numbers.
local function shown_comments(buf)
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local n = l:match("^    comment (%d+)$")
    if n then table.insert(out, tonumber(n)) end
  end
  return out
end

-- Moves the cursor, as a user's move does, and lets the trigger run.
local function move(line)
  vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
  vim.wait(20)
end

local function change(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = vim.api.nvim_get_current_buf() })
  vim.wait(20)
end

test("A1 the footer in view loads 5 comments, newest first, and the footer counts them", function()
  local env = setup(8)
  local buf = open(20)
  eq(calls(env), 1)
  eq(env.fake.calls[#env.fake.calls].params, { id = 100, project = "P", top = 5, quiet = true })
  local below = views.readonly_lines(buf)
  eq(below[4], "── Comments: 8")
  eq(below[5], "2026-09-15 " .. os.date("%H:%M", require("ado.core.timestamp").parse("2026-09-15T13:08:00Z"))
    .. " · Alex Smith")
  eq(below[6], "    comment 8", "without pandoc, the HTML loses its tags")
  eq(below[7], "")
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  eq(last_line(buf), "── 5 of 8 comments shown; move down to load more")
end)

test("A2 moving within half a window of the footer loads the other 3 with one call", function()
  local env = setup(8)
  local buf = open(20)
  move(vim.api.nvim_buf_line_count(buf) - 9)
  eq(calls(env), 2)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4, 3, 2, 1 })
  eq(last_line(buf), "── all 8 comments shown")
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), 2, "nothing more to load")
end)

test("A3 two cursor moves while a page is in flight make one call", function()
  local env = setup(8, { deferred = true })
  local buf = open(20)
  env.fake:flush()
  vim.wait(20)
  env.fake:flush()
  vim.wait(20)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  local before = calls(env)
  move(vim.api.nvim_buf_line_count(buf) - 5)
  eq(last_line(buf), "── 5 of 8 comments shown, loading more…")
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), before + 1)
  env.fake:flush()
  vim.wait(20)
  eq(last_line(buf), "── all 8 comments shown")
end)

test("A4 a page that answers after a reload is dropped and writes nothing", function()
  local env = setup(8, { deferred = true })
  local buf = open(20)
  env.fake:flush()
  vim.wait(20)
  eq(calls(env), 1, "the first page is in flight")
  eq(#env.fake.queue, 1)
  local late = table.remove(env.fake.queue, 1)
  local stats = require("ado.nvim.ux_stats")
  local dropped = (stats.get().comment_page_dropped or {}).count or 0
  env.item_view.load(buf)
  env.fake:flush()
  vim.wait(20)
  eq(calls(env), 2, "the reload's own first page")
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  late()
  vim.wait(20)
  eq((stats.get().comment_page_dropped or {}).count, dropped + 1)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "the late page wrote nothing")
  env.fake:flush()
  vim.wait(20)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
end)

test("A5 a comment a later page repeats shows once", function()
  local env = setup(8, { edit = function(c) if c.id == 4 then c.created = "2026-09-15T13:03:00.0000000Z" end end })
  local buf = open(20)
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), 2)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4, 3, 2, 1 })
  eq(last_line(buf), "── all 8 comments shown")
end)

test("A6 an item with no comments makes no comments call and says none", function()
  local env = setup(0)
  local buf = open(20)
  eq(calls(env), 0)
  eq(last_line(buf), "── Comments: none")
end)

test("A7 with the comments off-screen below 60 children, no call until the cursor moves towards them", function()
  local env = setup(8, { children = 60 })
  local buf = open(20)
  eq(calls(env), 0)
  ok(last_line(buf):find("8 comments; move down to load them", 1, true), last_line(buf))
  move(40)
  eq(calls(env), 0, "still far from the footer")
  move(vim.api.nvim_buf_line_count(buf))
  ok(calls(env) >= 1)
  eq(shown_comments(buf)[1], 8)
end)

test("A11 A12 a page written under a title edit leaves u to undo the edit and the modified flag alone", function()
  local env = setup(8, { children = 20 })
  local buf = open(20)
  eq(calls(env), 0)
  local loaded = views.row_lines(buf)
  cursor_to("Checkout story")
  change("A now<Esc>")
  eq(vim.bo[buf].modified, true)
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), 1)
  eq(vim.bo[buf].modified, true, "still modified")
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  change("u")
  eq(views.row_lines(buf), loaded, "u undid the title edit")
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 }, "and left the comments")
  eq(vim.bo[buf].modified, false)
  move(vim.api.nvim_buf_line_count(buf))
  eq(vim.bo[buf].modified, false, "a page on an unmodified buffer leaves it unmodified")
  eq(shown_comments(buf), { 8, 7, 6, 5, 4, 3, 2, 1 })
end)

test("A17 a failed page keeps the comments, says why once, and only <CR> on the footer retries", function()
  local env = setup(8)
  local notify = vim.notify
  local messages = {}
  vim.notify = function(msg, level) table.insert(messages, msg) notify(msg, level) end
  env.fake:fail_on("list_comments", 2, require("ado.core.gateway").error("failed", "HTTP 503"))
  local buf = open(20)
  move(vim.api.nvim_buf_line_count(buf))
  vim.notify = notify
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  eq(last_line(buf), "── comments did not load: HTTP 503; <CR> retries")
  local reported = 0
  for _, m in ipairs(messages) do if m:find("HTTP 503", 1, true) then reported = reported + 1 end end
  eq(reported, 1, "one message, not one from the notifier too")
  move(vim.api.nvim_buf_line_count(buf) - 1)
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), 2, "no retry by itself")
  key("<CR>")
  vim.wait(20)
  eq(calls(env), 3)
  eq(last_line(buf), "── all 8 comments shown")
end)

test("A18 C4.9 the reload after a save keeps the comments and counts a new one in the heading", function()
  local env = setup(8)
  local buf = open(20)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  env.fake.add_comment({ id = 100, text = "<p>remote</p>" }, function() end)
  local item = env.item_view.state(buf).view.item
  env.fake.items[100].rev = item.rev
  cursor_to("Checkout story")
  change("A now<Esc>")
  vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  vim.wait(50)
  eq(#env.fake.writes, 2, "the remote comment and the title")
  eq(vim.bo[buf].modified, false)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  eq(last_line(buf), "── 5 of 8 comments shown; move down to load more")
  ok(vim.tbl_contains(views.readonly_lines(buf), "── Comments: 9 (1 new; <leader>wr shows it)"),
    vim.inspect(views.readonly_lines(buf)))
end)

test("A19 <leader>wr drops the comments and the first page loads again by the trigger", function()
  local env = setup(8, { children = 20 })
  local buf = open(20)
  move(vim.api.nvim_buf_line_count(buf))
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  move(1)
  key("<leader>wr")
  vim.wait(20)
  eq(shown_comments(buf), {})
  ok(last_line(buf):find("8 comments; move down to load them", 1, true), last_line(buf))
  local before = calls(env)
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), before + 1)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
end)

test("A22 an edited comment says so, and a mention shows as @Name", function()
  setup(2, { edit = function(c)
    if c.id == 2 then
      c.version = 2
      c.text = '<div>Thanks <a href="#" data-vss-mention="version:2.0,u">@Alex Smith</a></div>'
    end
  end })
  local buf = open(30)
  local below = views.readonly_lines(buf)
  ok(below[5]:find(" · Alex Smith · edited$"), below[5])
  eq(below[6], "    Thanks @Alex Smith")
  ok(not below[8]:find("edited", 1, true), below[8])
  eq(last_line(buf), "── all 2 comments shown")
end)

test("A24 an edit in the comments pauses paging, says so at the end of the last line, and u resumes it", function()
  local env = setup(8)
  local buf = open(20)
  local first = vim.fn.search("^    comment 8$")
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  change("dd")
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), 1, "no page while the comments are edited")
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_comments_pause, 0, -1,
    { details = true })
  eq(#marks, 1)
  eq(marks[1][4].virt_text[1][1], "  ── comments are read-only; undo the change to load more")
  change("u")
  move(vim.api.nvim_buf_line_count(buf))
  eq(calls(env), 2)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4, 3, 2, 1 })
  eq(#vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_comments_pause, 0, -1, {}), 0)
end)

test("A26 going to another item and back with [h shows the loaded comments with no call", function()
  local env = setup(8)
  local buf = open(20)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  cursor_to("Write API")
  key("<CR>")
  vim.wait(20)
  local before = calls(env)
  key("[h")
  vim.wait(20)
  eq(vim.api.nvim_get_current_buf(), buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.wait(20)
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  eq(calls(env), before, "no comments call")
end)

test("Q5 a comment added with <leader>wc shows first once the header reloads", function()
  local env = setup(8)
  local buf = open(20)
  key("<leader>wc")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Mine." })
  key("<C-s>")
  vim.wait(50)
  eq(vim.api.nvim_get_current_buf(), buf)
  local below = views.readonly_lines(buf)
  eq(below[4], "── Comments: 9")
  ok(below[5]:find(" · Me Myself$"), below[5])
  eq(below[6], "    Mine.")
  eq(shown_comments(buf), { 8, 7, 6, 5, 4 })
  eq(vim.bo[buf].modified, false)
end)

test("C5.4 C7.6 comment lines have their own highlights, and ux_stats reports the pages", function()
  setup(3)
  local buf = open(30)
  local groups = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().ado_comments, 0, -1,
    { details = true })) do
    groups[m[4].hl_group] = (groups[m[4].hl_group] or 0) + 1
  end
  eq(groups.AdoCommentHeading, 3)
  eq(groups.AdoCommentText, 3)
  eq(groups.AdoHeading, 2, "the Comments heading and the footer")
  local stats = require("ado.nvim.ux_stats").get()
  ok(stats.comment_page and stats.comment_page.count >= 1, vim.inspect(stats))
  local text = table.concat(require("ado").ux_stats(), "\n")
  ok(text:find("comment_page: ", 1, true), text)
end)
