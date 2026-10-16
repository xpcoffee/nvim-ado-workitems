-- Comment paging for one item buffer (RFC 0003 section 9): the comments
-- loaded so far, newest first, the continuation token of the next page,
-- and whether a page is in flight, failed, or the last one has arrived.
--
--   state   = { generation, total = count | nil (unknown), newer = n,
--               comments = { comment... } (newest first), seen = { [id] = true },
--               token, started, done, in_flight = request | nil,
--               failed = reason | nil }
--   request = { generation, token }
--   comment = { id, version, edited, author, created (ISO 8601), format =
--               "html" | "markdown", text }
--
-- A response is merged only while it answers the newest request of the
-- same generation (a counter every reload raises) with the same token, so
-- a page that arrives after a reload, or after another page, is dropped.
local item_details = require("ado.core.item_details")

local M = {}

M.PAGE = 5

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- total: the item's System.CommentCount, nil when unknown. A count of 0
-- makes no call (C4.1). previous: the state this one replaces on a reload.
function M.new(total, previous)
  return { generation = (previous and previous.generation or 0) + 1, total = total, newer = 0, comments = {},
    seen = {}, token = nil, started = false, done = total == 0, in_flight = nil, failed = nil }
end

-- The comment count from a reload that keeps the loaded comments (C4.9):
-- when it grew, the heading says how many are new.
function M.update_total(state, total)
  if total == nil then return end
  if state.total ~= nil and total > state.total then
    state.newer = total - state.total
  elseif state.total == nil then
    state.total = total
    if total == 0 and not state.started then state.done = true end
  end
end

function M.normalise(raw)
  local who = type(raw.createdBy) == "table" and raw.createdBy or {}
  local version = tonumber(raw.version) or 1
  local format = type(raw.format) == "string" and raw.format:lower() == "markdown" and "markdown" or "html"
  return { id = raw.id, version = version, edited = version > 1,
    author = who.displayName or who.uniqueName or "", created = raw.createdDate or "",
    format = format, text = type(raw.text) == "string" and raw.text or "", deleted = raw.isDeleted == true }
end

-- The trigger rule (C4.3): load when the footer line is shown, or lies
-- within half the window's height below the last line drawn (w$).
function M.near(footer, last_shown, height)
  return footer - last_shown <= math.floor(height / 2)
end

-- Whether a page should load now: there is more to load, nothing is in
-- flight, the last page did not fail (C4.7: no retry by itself), and the
-- footer line is near.
function M.wants(state, footer, last_shown, height)
  if state.done or state.in_flight or state.failed then return false end
  return M.near(footer, last_shown, height)
end

-- Marks a page in flight and returns its request.
function M.begin(state)
  state.started = true
  state.failed = nil
  state.in_flight = { generation = state.generation, token = state.token }
  return state.in_flight
end

-- Whether request is still the one state waits for.
function M.current(state, request)
  return state.in_flight == request and request.generation == state.generation and request.token == state.token
end

-- Merges a page answering request. Returns "stale" (dropped: nothing
-- changed), "failed" (state.failed holds the reason) or "merged" and the
-- comments added, newest first, without those already shown (C4.4, C4.6).
function M.receive(state, request, err, page)
  if not M.current(state, request) then return "stale" end
  state.in_flight = nil
  if err then
    state.failed = trim(err.message ~= nil and tostring(err.message) or "unknown error"):gsub("\n.*", "")
    return "failed"
  end
  local added = {}
  for _, raw in ipairs(page.comments or {}) do
    local c = M.normalise(raw)
    if c.id ~= nil and not c.deleted and not state.seen[c.id] then
      state.seen[c.id] = true
      table.insert(state.comments, c)
      table.insert(added, c)
    end
  end
  if page.total ~= nil then state.total = page.total end
  state.token = page.token
  -- "All shown" follows the absent token, not the count, which may count
  -- deleted comments (RFC 0003 R6).
  state.done = page.token == nil
  return "merged", added
end

-- Merges a first page fetched again, after the user added a comment: the
-- comments it holds that are not shown yet are newer than every shown one,
-- so they go first. Returns them.
function M.merge_newest(state, page)
  local fresh = {}
  for _, raw in ipairs(page.comments or {}) do
    local c = M.normalise(raw)
    if c.id ~= nil and not c.deleted and not state.seen[c.id] then
      state.seen[c.id] = true
      table.insert(fresh, c)
    end
  end
  for i = #fresh, 1, -1 do table.insert(state.comments, 1, fresh[i]) end
  if page.total ~= nil then state.total = page.total end
  state.newer = 0
  if not state.started then
    state.started = true
    state.token = page.token
    state.done = page.token == nil
  end
  return fresh
end

-- "── Comments: 8", "── Comments: none", "── Comments" (count unknown), or
-- with the comments a later load counted: "── Comments: 9 (1 new;
-- <leader>wr shows it)".
function M.heading(state)
  if state.total == nil then return "── Comments" end
  if state.total == 0 and #state.comments == 0 then return "── Comments: none" end
  local text = "── Comments: " .. (state.total + state.newer)
  if state.newer > 0 then
    text = text .. string.format(" (%d new; <leader>wr shows %s)", state.newer, state.newer == 1 and "it" or "them")
  end
  return text
end

local function of_total(state)
  return state.total and (" of " .. state.total) or ""
end

-- The footer line (C4.5), or nil when there is nothing to page through.
function M.footer(state)
  local shown = #state.comments
  if state.failed then return "── comments did not load: " .. state.failed .. "; <CR> retries" end
  if state.done then
    if shown == 0 then return nil end
    return string.format("── all %d comment%s shown", shown, shown == 1 and "" or "s")
  end
  if state.in_flight then
    if shown == 0 then return "── loading comments…" end
    return string.format("── %d%s comments shown, loading more…", shown, of_total(state))
  end
  if not state.started then
    if state.total then return string.format("── %d comment%s; move down to load them", state.total,
      state.total == 1 and "" or "s") end
    return "── move down to load the comments"
  end
  return string.format("── %d%s comments shown; move down to load more", shown, of_total(state))
end

-- The heading line of a comment (C5.1): "2026-09-15 13:58 · Alex Smith",
-- with " · edited" when its version is above 1. format_time: epoch ->
-- local time text.
function M.title(comment, format_time)
  local text = item_details.time(comment.created, format_time) .. " · " .. comment.author
  if comment.edited then text = text .. " · edited" end
  return text
end

-- The lines of comments in order, each as its title, its text (text_of(c)
-- -> lines) indented 4 spaces and wrapped to width, then a blank line.
-- kinds[i] says what line i is: "title", "text" or "blank".
-- opts: format_time, width, measure.
function M.lines(comments, text_of, opts)
  opts = opts or {}
  local out, kinds = {}, {}
  for _, c in ipairs(comments) do
    table.insert(out, M.title(c, opts.format_time))
    table.insert(kinds, "title")
    for _, l in ipairs(item_details.indented(text_of(c), opts.width, opts.measure)) do
      table.insert(out, l)
      table.insert(kinds, l == "" and "blank" or "text")
    end
    table.insert(out, "")
    table.insert(kinds, "blank")
  end
  return out, kinds
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ["#39"] = "'" }

-- Plain text lines from a comment's HTML without pandoc (C5.2): block
-- ends and <br> become line breaks, tags are removed and common entities
-- decoded. A mention's link text is "@Name", so it stays.
function M.plain(html)
  local s = (html or ""):gsub("\r", "")
  s = s:gsub("<[Bb][Rr]%s*/?>", "\n")
  s = s:gsub("</[Pp]>", "\n"):gsub("</[Dd][Ii][Vv]>", "\n"):gsub("</[Ll][Ii]>", "\n")
  s = s:gsub("<[Ll][Ii][^>]*>", "- ")
  s = s:gsub("<[^>]*>", "")
  s = s:gsub("&(#?%w+);", function(e)
    if ENTITIES[e] then return ENTITIES[e] end
    local n = e:match("^#(%d+)$")
    if n and tonumber(n) < 128 then return string.char(tonumber(n)) end
    return "&" .. e .. ";"
  end)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do table.insert(out, (line:gsub("%s+$", ""))) end
  while #out > 0 and out[#out] == "" do table.remove(out) end
  while #out > 0 and out[1] == "" do table.remove(out, 1) end
  return out
end

return M
