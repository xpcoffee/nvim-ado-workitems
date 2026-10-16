-- The comments section of an item buffer (RFC 0003 section 9): the
-- `── Comments` heading, the comments loaded so far and the footer line,
-- the last line of the buffer. A page loads when the footer comes near
-- the window's last line (core/comments.lua has the rule), and is written
-- in place of the footer line with a quiet write, so it adds no undo step
-- and leaves the header's edits undoable (C2.6, C2.7).
local comments = require("ado.core.comments")
local fit = require("ado.nvim.fit")
local lines_mod = require("ado.nvim.lines")
local markup = require("ado.nvim.markup")
local region = require("ado.nvim.region")
local session = require("ado.nvim.session")
local ux_stats = require("ado.nvim.ux_stats")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

local NS = vim.api.nvim_create_namespace("ado_comments")
local PAUSE_NS = vim.api.nvim_create_namespace("ado_comments_pause")

M.PAUSED = "── comments are read-only; undo the change to load more"

-- Set by nvim/item_view.lua: entry(buf) -> the buffer's state, render(buf),
-- format_time(epoch) -> text.
local host

function M.setup(h)
  host = h
end

local function width(buf)
  return (fit.window_width(buf) or (vim.o.columns - 2)) - 1
end

local function render_opts(buf)
  return { format_time = host.format_time, width = width(buf), measure = lines_mod.measure }
end

local function text_of(entry)
  return function(c) return entry.comment_text[c.id] or {} end
end

-- A fresh paging state for a load, or the loaded one kept with the new
-- count (keep: the reload after a save or a comment, C4.9).
function M.on_load(entry, count, keep)
  if keep and entry.comments then
    comments.update_total(entry.comments, count)
    return
  end
  entry.comments = comments.new(count, entry.comments)
  entry.comment_text = {}
  entry.unwritten = nil
end

-- The section's lines, from the heading to the footer, and what each is.
function M.section(buf, entry)
  local st = entry.comments
  local out, kinds = { comments.heading(st) }, { "heading" }
  local body, body_kinds = comments.lines(st.comments, text_of(entry), render_opts(buf))
  vim.list_extend(out, body)
  vim.list_extend(kinds, body_kinds)
  local footer = comments.footer(st)
  if footer then
    table.insert(out, footer)
    table.insert(kinds, "footer")
  end
  entry.comment_kinds = kinds
  entry.unwritten = nil
  return out
end

local GROUPS = { heading = "AdoHeading", footer = "AdoHeading", title = "AdoCommentHeading", text = "AdoCommentText" }

-- Colours the section's lines, which start after the details.
function M.highlight(buf, entry)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local boundary = region.boundary(buf)
  if not boundary or not entry.details or not entry.comment_kinds then return end
  local first = boundary + entry.details.count
  local count = vim.api.nvim_buf_line_count(buf)
  for i, kind in ipairs(entry.comment_kinds) do
    local row = first + i - 1
    if GROUPS[kind] and row < count then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, { end_row = row + 1, end_col = 0, hl_group = GROUPS[kind] })
    end
  end
end

-- Whether the user changed the read-only text, which pauses paging
-- (C2.8): the plugin could no longer tell where the footer line is. The
-- pause is shown at the end of the last line, since the footer cannot be
-- written.
-- buf -> { tick, paused }: the check reads every line below the header,
-- and the cursor moves far more often than the text changes.
local checked = setmetatable({}, { __mode = "k" })

local function paused(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = checked[buf]
  if c and c.tick == tick then return c.paused end
  vim.api.nvim_buf_clear_namespace(buf, PAUSE_NS, 0, -1)
  local changed = region.readonly_changed(buf) ~= nil
  if changed then
    local last = vim.api.nvim_buf_line_count(buf) - 1
    vim.api.nvim_buf_set_extmark(buf, PAUSE_NS, last, 0, { virt_text = { { "  " .. M.PAUSED, "WarningMsg" } },
      virt_text_pos = "eol" })
  end
  checked[buf] = { tick = tick, paused = changed }
  return changed
end

-- Replaces the footer line, the buffer's last, with lines (comment lines
-- and the new footer); kinds says what each is. Returns false when the
-- read-only text was changed, so the footer's place is unknown.
local function write_tail(buf, entry, new_lines, kinds)
  if paused(buf) then return false end
  local n = vim.api.nvim_buf_line_count(buf)
  local had_footer = entry.comment_kinds[#entry.comment_kinds] == "footer"
  if had_footer then table.remove(entry.comment_kinds) end
  vim.list_extend(entry.comment_kinds, kinds)
  view_buffer.replace_readonly(buf, had_footer and n - 1 or n, n, new_lines)
  M.highlight(buf, entry)
  return true
end

local function footer_lines(entry)
  local footer = comments.footer(entry.comments)
  if not footer then return {}, {} end
  return { footer }, { "footer" }
end

local function write_footer(buf, entry)
  local lines, kinds = footer_lines(entry)
  return write_tail(buf, entry, lines, kinds)
end

-- Writes the comments added (newest first) after those shown, then the
-- footer. Comments merged while paging was paused are written once it
-- resumes.
local function write_page(buf, entry, added)
  local pending = entry.unwritten or {}
  vim.list_extend(pending, added)
  local body, kinds = comments.lines(pending, text_of(entry), render_opts(buf))
  local footer, footer_kinds = footer_lines(entry)
  vim.list_extend(body, footer)
  vim.list_extend(kinds, footer_kinds)
  if write_tail(buf, entry, body, kinds) then
    entry.unwritten = nil
  else
    entry.unwritten = pending
  end
end

-- Converts the page's comments to text lines, then calls cb({ [id] =
-- lines }): markdown as it is, HTML with one pandoc call for the page.
local function convert(raws, cb)
  local htmls, ids, texts = {}, {}, {}
  for _, raw in ipairs(raws) do
    local c = comments.normalise(raw)
    if c.format == "markdown" then
      texts[c.id] = vim.split(c.text, "\n", { plain = true })
    else
      table.insert(htmls, c.text)
      table.insert(ids, c.id)
    end
  end
  markup.html_to_plain(htmls, function(out)
    for i, id in ipairs(ids) do texts[id] = out[i] end
    cb(texts)
  end)
end

local function alive(buf, entry, st)
  return vim.api.nvim_buf_is_valid(buf) and host.entry(buf) == entry and entry.comments == st
end

local function load_page(buf, entry)
  local st = entry.comments
  local request = comments.begin(st)
  write_footer(buf, entry)
  local started = vim.uv.hrtime()
  local item = entry.view.item
  session.get():list_comments(item.id, item.project, request.token, comments.PAGE, function(err, page)
    if not alive(buf, entry, st) or not comments.current(st, request) then
      return ux_stats.count("comment_page_dropped")
    end
    if err then
      comments.receive(st, request, err)
      ux_stats.count("comment_page_failed")
      write_footer(buf, entry)
      vim.notify(string.format("[ado] the comments of #%d did not load: %s", item.id, st.failed),
        vim.log.levels.WARN)
      return
    end
    convert(page.comments or {}, function(texts)
      if not alive(buf, entry, st) or not comments.current(st, request) then
        return ux_stats.count("comment_page_dropped")
      end
      for id, t in pairs(texts) do entry.comment_text[id] = t end
      local _, added = comments.receive(st, request, nil, page)
      write_page(buf, entry, added)
      ux_stats.record("comment_page", (vim.uv.hrtime() - started) / 1e6)
      vim.schedule(function() M.maybe_load(buf) end)
    end)
  end)
end

-- Loads the next page when the trigger rule holds in a window showing
-- buf (C4.3).
function M.maybe_load(buf)
  if not host or not vim.api.nvim_buf_is_valid(buf) then return end
  local entry = host.entry(buf)
  if not entry or not entry.view or not entry.comments or entry.loading then return end
  local st = entry.comments
  if paused(buf) then return end
  if entry.unwritten then write_page(buf, entry, {}) end
  if st.done or st.in_flight or st.failed then return end
  local footer = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local last = vim.fn.line("w$", win)
    if comments.wants(st, footer, last, vim.api.nvim_win_get_height(win)) then return load_page(buf, entry) end
  end
end

-- <CR> on line of buf: on the footer line, retries a failed page or loads
-- the next one now. Returns whether the line was the footer.
function M.on_enter(buf, line)
  local entry = host.entry(buf)
  if not entry or not entry.comments or not entry.comment_kinds then return false end
  if line ~= vim.api.nvim_buf_line_count(buf) or entry.comment_kinds[#entry.comment_kinds] ~= "footer" then
    return false
  end
  if paused(buf) then return true end
  local st = entry.comments
  if st.done or st.in_flight then return true end
  st.failed = nil
  load_page(buf, entry)
  return true
end

-- After the user added a comment and the header reloaded: the first page
-- again, so the new comment shows first (Q5). Only an unedited buffer is
-- rendered again; otherwise the heading's count says a comment is new.
function M.show_newest(buf)
  local entry = host.entry(buf)
  if not entry or not entry.view or not entry.comments then return end
  local st = entry.comments
  local item = entry.view.item
  session.get():list_comments(item.id, item.project, nil, comments.PAGE, function(err, page)
    if err or not alive(buf, entry, st) or vim.bo[buf].modified then return end
    convert(page.comments or {}, function(texts)
      if not alive(buf, entry, st) or vim.bo[buf].modified or entry.loading then return end
      for id, t in pairs(texts) do entry.comment_text[id] = t end
      comments.merge_newest(st, page)
      host.render(buf)
    end)
  end)
end

-- Paging follows the cursor and the windows of every item buffer.
function M.attach(buf)
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter" }, {
    buffer = buf,
    callback = function() M.maybe_load(buf) end,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = buf,
    callback = function() M.maybe_load(buf) end,
  })
end

local group = vim.api.nvim_create_augroup("ado_item_comments", { clear = true })
vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
  group = group,
  callback = function()
    if not host then return end
    local seen = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(win)
      if not seen[b] and host.entry(b) then
        seen[b] = true
        vim.schedule(function() M.maybe_load(b) end)
      end
    end
  end,
})

return M
