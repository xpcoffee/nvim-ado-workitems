-- Comment paging for an item buffer (RFC 0003 C4, C5, C7.2), on the fake
-- gateway's pages.
local Fake = require("tests.support.fake_gateway")
local comments = require("ado.core.comments")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")

local function with_comments(list)
  local d = {}
  for k, v in pairs(seed) do d[k] = v end
  d.items = { { id = 100, type = "User Story", title = "Checkout story", state = "Active", area = "P\\Team\\A",
    comments = list } }
  return d
end

local function numbered(n, edit)
  local out = {}
  for i = 1, n do
    out[i] = { id = i, text = "<p>comment " .. i .. "</p>", author = "alex.smith@example.com",
      created = string.format("2026-09-15T13:%02d:00.0000000Z", i) }
    if edit then edit(out[i]) end
  end
  return out
end

local function new(list)
  local fake = Fake.new(with_comments(list))
  return session.new({ gateway = fake, org = "test-org", project = "P" }), fake
end

-- Starts a page and answers it from the session.
local function page(s, state)
  local req = comments.begin(state)
  local kind, added
  s:list_comments(100, "P", req.token, comments.PAGE, function(err, p) kind, added = comments.receive(state, req, err, p) end)
  return kind, added
end

local function ids(list)
  local out = {}
  for _, c in ipairs(list) do table.insert(out, c.id) end
  return out
end

test("A1 A2 pages of 5, newest first; the footer counts what is shown, and says all once the token is gone", function()
  local s, fake = new(numbered(8))
  local state = comments.new(8)
  eq(comments.heading(state), "── Comments: 8")
  eq(comments.footer(state), "── 8 comments; move down to load them")
  comments.begin(state)
  eq(comments.footer(state), "── loading comments…")
  state = comments.new(8)
  local kind, added = page(s, state)
  eq(kind, "merged")
  eq(ids(added), { 8, 7, 6, 5, 4 })
  eq(comments.footer(state), "── 5 of 8 comments shown; move down to load more")
  comments.begin(state)
  eq(comments.footer(state), "── 5 of 8 comments shown, loading more…")
  state.in_flight = nil
  kind, added = page(s, state)
  eq(ids(added), { 3, 2, 1 })
  eq(state.done, true)
  eq(comments.footer(state), "── all 8 comments shown")
  eq(comments.wants(state, 30, 30, 20), false, "nothing more to load")
  eq(#fake.calls, 2)
  eq(fake.calls[1].params, { id = 100, project = "P", top = 5, quiet = true })
end)

test("A6 an item with no comments shows none and wants no page", function()
  local state = comments.new(0)
  eq(comments.heading(state), "── Comments: none")
  eq(comments.footer(state), nil)
  eq(comments.wants(state, 10, 30, 20), false)
end)

test("C4.3 the trigger: the footer shown, or within half the window's height below w$", function()
  eq(comments.near(40, 40, 20), true, "shown")
  eq(comments.near(50, 40, 20), true, "10 lines below a 20-line window")
  eq(comments.near(51, 40, 20), false)
  eq(comments.near(45, 40, 11), true, "floor(11 / 2) = 5")
  eq(comments.near(46, 40, 11), false)
  local state = comments.new(8)
  eq(comments.wants(state, 50, 40, 20), true)
  comments.begin(state)
  eq(comments.wants(state, 50, 40, 20), false, "A3 one page in flight at a time")
end)

test("A4 a response after a reload, or with another token, is dropped and changes nothing", function()
  local s = new(numbered(8))
  local old = comments.new(8)
  local req = comments.begin(old)
  local state = comments.new(8, old)
  eq(state.generation, old.generation + 1)
  local answered
  s:list_comments(100, "P", nil, 5, function(err, p) answered = { err, p } end)
  eq(comments.receive(state, req, answered[1], answered[2]), "stale")
  eq(#state.comments, 0)
  state.in_flight = req
  state.generation = req.generation
  state.token = "another"
  eq(comments.receive(state, req, answered[1], answered[2]), "stale", "the token no longer matches")
end)

test("A5 a page that repeats a shown comment adds only the others", function()
  local list = numbered(8)
  list[4].created = list[3].created
  local s = new(list)
  local state = comments.new(8)
  page(s, state)
  eq(ids(state.comments), { 8, 7, 6, 5, 4 })
  local _, added = page(s, state)
  eq(ids(added), { 3, 2, 1 }, "#4 came again and was skipped")
  eq(ids(state.comments), { 8, 7, 6, 5, 4, 3, 2, 1 })
end)

test("A17 a failed page keeps the shown comments, says why, and is not retried by itself", function()
  local s, fake = new(numbered(8))
  local state = comments.new(8)
  page(s, state)
  fake:fail_on("list_comments", 2, require("ado.core.gateway").error("failed", "HTTP 503\nmore detail"))
  eq(page(s, state), "failed")
  eq(#state.comments, 5)
  eq(comments.footer(state), "── comments did not load: HTTP 503; <CR> retries")
  eq(comments.wants(state, 30, 30, 20), false)
  local kind = page(s, state)
  eq(kind, "merged", "a retry, as <CR> on the footer starts")
  eq(#state.comments, 8)
end)

test("C4.9 a reload that keeps the comments counts the new ones in the heading", function()
  local state = comments.new(8)
  comments.update_total(state, 9)
  eq(comments.heading(state), "── Comments: 9 (1 new; <leader>wr shows it)")
  comments.update_total(state, 11)
  eq(comments.heading(state), "── Comments: 11 (3 new; <leader>wr shows them)")
  local unknown = comments.new(nil)
  eq(comments.heading(unknown), "── Comments")
  eq(comments.footer(unknown), "── move down to load the comments")
  comments.update_total(unknown, 0)
  eq(comments.footer(unknown), nil)
end)

test("a first page fetched again after a new comment puts the new one first", function()
  local s, fake = new(numbered(8))
  local state = comments.new(8)
  page(s, state)
  fake.add_comment({ id = 100, text = "<p>new</p>" }, function() end)
  local p
  s:list_comments(100, "P", nil, 5, function(_, x) p = x end)
  local fresh = comments.merge_newest(state, p)
  eq(ids(fresh), { 9 })
  eq(ids(state.comments), { 9, 8, 7, 6, 5, 4 })
  eq(comments.heading(state), "── Comments: 9")
end)

test("A22 C5.1 a comment shows its local time, author and edited mark, then its text indented", function()
  local c = comments.normalise({ id = 1, version = 2, createdDate = "2026-09-15T13:58:12.5Z", format = "html",
    text = "<p>x</p>", createdBy = { displayName = "Alex Smith", uniqueName = "alex@example.com" } })
  eq(c.edited, true)
  local out, kinds = comments.lines({ c }, function() return { "Looks right.", "", "Ship it." } end)
  eq(out, { "2026-09-15 13:58 · Alex Smith · edited", "    Looks right.", "", "    Ship it.", "" })
  eq(kinds, { "title", "text", "blank", "text", "blank" })
  eq(comments.title(comments.normalise({ id = 2, createdDate = "2026-09-15T13:58:00Z",
    createdBy = { uniqueName = "u@example.com" } })), "2026-09-15 13:58 · u@example.com")
  eq(comments.normalise({ id = 3, format = "Markdown" }).format, "markdown")
end)

test("C5.2 C5.3 without pandoc, HTML loses its tags and keeps a mention as @Name", function()
  eq(comments.plain('<div>Hi <a href="#" data-vss-mention="version:2.0,x">@Alex Smith</a>,</div>'
    .. "<div>see &lt;this&gt; &amp; that<br>next line</div><ul><li>one</li><li>two</li></ul>"),
    { "Hi @Alex Smith,", "see <this> & that", "next line", "- one", "- two" })
  eq(comments.plain("<p>a</p>\n<p>b&#39;s</p>"), { "a", "", "b's" })
end)

test("deleted comments in a page are not shown", function()
  local s = new(numbered(3, function(c) if c.id == 2 then c.deleted = true end end))
  local state = comments.new(2)
  page(s, state)
  eq(ids(state.comments), { 3, 1 })
end)
