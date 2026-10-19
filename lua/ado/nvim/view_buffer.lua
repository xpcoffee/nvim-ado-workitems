-- Buffers for the area and item views: named by their location URI,
-- acwrite so that :w reaches the plugin and never the file system, row ID
-- prefixes concealed, colours and change markers (nvim/decorations.lua),
-- and a window bar per buffer.
local decorations = require("ado.nvim.decorations")
local fit = require("ado.nvim.fit")
local highlights = require("ado.nvim.highlights")
local lines_mod = require("ado.nvim.lines")
local quiet_edit = require("ado.nvim.quiet_edit")
local realign = require("ado.nvim.realign")
local region = require("ado.nvim.region")
local registry = require("ado.nvim.registry")
local session = require("ado.nvim.session")

local M = {}

local NS = vim.api.nvim_create_namespace("ado_view")
local LABELS = vim.api.nvim_create_namespace("ado_view_labels")

-- buf -> { opts = get_or_create's opts, left, right (window bar parts),
-- counts = the last decoration's, tick = changedtick it decorated }
local views = {}

-- vim.fn.bufnr() treats its argument as a file pattern, and these names
-- hold "?", so buffers are matched by exact name instead.
function M.find(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then return buf end
  end
end

local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

-- The counts of unsaved edits, after the view's own counts on the right.
local function winbar_text(buf)
  local v = views[buf] or {}
  local right = {}
  if v.right and v.right ~= "" then table.insert(right, v.right) end
  local c = v.counts
  if c then
    if c.changed > 0 then table.insert(right, c.changed .. " edited") end
    if c.new > 0 then table.insert(right, c.new .. " new") end
    if c.removed > 0 then table.insert(right, c.removed .. " removed") end
  end
  local text = escape(v.left or "")
  if fit.stale(buf) then text = text .. "  ·  fits the window after :w or <leader>wr" end
  if #right > 0 then text = text .. "%=%#AdoCount#" .. escape(table.concat(right, " · ")) .. "%*" end
  return text
end

local function apply_window_options(buf, win)
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  set("conceallevel", 2)
  set("concealcursor", "nvic")
  set("wrap", false)
  set("signcolumn", "yes:1")
  set("winbar", winbar_text(buf))
end

local function update_winbars(buf)
  local text = winbar_text(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_set_option_value("winbar", text, { scope = "local", win = win })
  end
end

-- A catalog the session has not loaded yet is requested once per session
-- and project, and the view is decorated again when it arrives; until
-- then its cells use AdoType and AdoState. Only a view in every state
-- needs this: an open-state load has loaded the catalog already.
local requested = setmetatable({}, { __mode = "k" })

local function session_catalog(buf)
  return function(project)
    local s = session.get()
    local catalog = s:cached_catalog(project)
    if catalog then return catalog end
    requested[s] = requested[s] or {}
    if not requested[s][project] then
      requested[s][project] = true
      vim.schedule(function()
        s:catalog(project, function(err)
          if not err and vim.api.nvim_buf_is_valid(buf) then M.decorate(buf, true) end
        end)
      end)
    end
  end
end

-- The project of a line in buf that names none (a typed line, the viewed
-- item's field lines), or nil.
function M.project(buf)
  local v = views[buf]
  return v and v.opts.project and v.opts.project(buf) or nil
end

-- Places colours and change markers, and refreshes the window bar's
-- counts. Skipped when the text has not changed since the last pass,
-- unless force (a load, or a catalog that arrived).
function M.decorate(buf, force)
  local v = views[buf]
  if not v or not vim.api.nvim_buf_is_valid(buf) then return end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if not force and v.tick == tick then return end
  v.tick = tick
  local opts = v.opts
  v.counts = decorations.refresh(buf, { ids = opts.ids and opts.ids(buf) or {},
    project = opts.project and opts.project(buf) or nil, catalog = opts.catalog or session_catalog(buf) })
  update_winbars(buf)
end

local function in_insert()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

-- Conceals the row ID prefix of every row line, including lines the user
-- has pasted or typed, by reading it from the text. A comment line that
-- starts like a row ID is read-only text and keeps its start (RFC 0003
-- C2.5).
local function conceal(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, line in ipairs(region.lines(buf)) do
    local prefix = line:match("^/%d+ ")
    if prefix then vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 0, { end_col = #prefix, conceal = "" }) end
  end
end

-- Moves the cursor of the current window out of a row's concealed row ID
-- prefix, in Normal mode. The cursor shows on the first visible character
-- there, the ID, but `yiw` would yank the hidden "/".
local function out_of_prefix(buf)
  if vim.api.nvim_get_mode().mode ~= "n" then return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if not region.readable(buf, row) then return end
  local n = lines_mod.prefix_length(vim.api.nvim_get_current_line())
  if col < n then vim.api.nvim_win_set_cursor(0, { row, n }) end
end

-- Returns the buffer and whether it was created now.
-- opts: syntax (the syntax file, "adoarea" or "adoitem"); ids(buf) -> the
-- row ID of each loaded line; project(buf) -> the project of a line that
-- names none (a typed line, the viewed item's field lines);
-- catalog(project) -> a type catalog or nil, in place of the session's
-- (for the bench).
function M.get_or_create(name, filetype, opts)
  local existing = M.find(name)
  if existing then return existing, false end
  opts = opts or {}
  highlights.setup()
  local buf = vim.api.nvim_create_buf(true, false)
  views[buf] = { opts = opts }
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = filetype
  if opts.syntax then
    -- With :syntax on, setting 'syntax' loads syntax/<name>.lua; without
    -- it (nvim -u NONE), nothing does, so the file is run here.
    vim.api.nvim_buf_call(buf, function()
      vim.bo.syntax = opts.syntax
      if vim.b.current_syntax ~= opts.syntax then vim.cmd("runtime! syntax/" .. opts.syntax .. ".lua") end
    end)
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    -- Neovim returns the cursor to the written buffer once BufWriteCmd
    -- ends, which would pull it out of the summary float the save opens.
    callback = function() vim.schedule(function() require("ado.nvim.save").write(buf) end) end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function() conceal(buf) end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function() out_of_prefix(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      apply_window_options(buf, vim.api.nvim_get_current_win())
      vim.schedule(function() M.refit(buf) end)
    end,
  })
  realign.attach(buf)
  -- A value picked from a menu replaces the whole cell (plan 0002 UX5.3).
  vim.api.nvim_create_autocmd("CompleteDone", {
    buffer = buf,
    callback = function()
      local word = (vim.v.completed_item or {}).word
      if not word or word == "" then return end
      local cells = require("ado.nvim.cells")
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      if not region.readable(buf, row) then return end
      local line = vim.api.nvim_get_current_line()
      local c = cells.at(line, math.max(col, 1))
      if c then fit.replacing(buf, row, cells.column(line, c), word) end
    end,
  })
  -- After realign's autocommands, so the markers read the re-padded text.
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = buf,
    callback = function()
      if not in_insert() then M.decorate(buf) end
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not in_insert() then M.decorate(buf) end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function() views[buf] = nil end,
  })
  return buf, true
end

-- Changes lines whether or not the view is modifiable, keeping its modified
-- flag. The change is left out of the undo history, so `u` cannot undo a
-- load or an expansion into an empty or half-shown view, and is not
-- re-padded: the lines render aligned. The history itself is cleared,
-- unless keep_history, for a write below the header that must leave the
-- user's header edits undoable (nvim/quiet_edit.lua).
local function edit(buf, change, keep_history)
  local modified, modifiable = vim.bo[buf].modified, vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  if keep_history then
    quiet_edit.run(buf, change)
  else
    local undolevels = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    change()
    vim.bo[buf].undolevels = undolevels
  end
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = modified
  realign.settle(buf, keep_history)
end

local function set(buf, first, last, lines)
  return function() vim.api.nvim_buf_set_lines(buf, first, last, false, lines) end
end

-- Views cannot be edited while they load or while a save applies, since
-- the load or the save's reload would replace the edits.
function M.set_editable(buf, editable)
  if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = editable end
end

-- boundary: for an item buffer, { line, row_id } of its `── Details`
-- row; the lines from it on are read-only (nvim/region.lua).
function M.set_lines(buf, lines, boundary)
  edit(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if boundary then
      region.set(buf, boundary.line, boundary.row_id, vim.list_slice(lines, boundary.line))
    else
      region.clear(buf)
    end
  end)
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, LABELS, 0, -1)
  conceal(buf)
  M.decorate(buf, true)
end

-- Replaces lines first to last - 1 (0-based) of an item buffer's
-- read-only text, outside the undo history and keeping it, so the header's
-- unsaved edits stay undoable (RFC 0003 C2.6, C2.7). Records the read-only
-- text the buffer then holds.
function M.replace_readonly(buf, first, last, lines)
  edit(buf, set(buf, first, last, lines), true)
  local n = region.header_end(buf)
  if n then region.set_readonly(buf, vim.api.nvim_buf_get_lines(buf, n, -1, false)) end
end

-- Inserts lines before line `at` (0-based) without redrawing the others,
-- except to re-pad them when the new lines widen a column.
function M.insert_lines(buf, at, lines)
  edit(buf, function()
    vim.api.nvim_buf_set_lines(buf, at, at, false, lines)
    realign.repad(buf)
  end)
  conceal(buf)
  M.decorate(buf, true)
end

-- Deletes lines first to last - 1 (0-based).
function M.delete_lines(buf, first, last)
  -- A deleted line's labels would otherwise move onto the next line.
  vim.api.nvim_buf_clear_namespace(buf, LABELS, first, last)
  edit(buf, set(buf, first, last, {}))
  conceal(buf)
  M.decorate(buf, true)
end

-- Lays an unmodified view out again for its window's text width (plan 0002
-- UX4.3), rewriting only the lines that change, so the labels stay and no
-- undo step is added, as for a load. A view with unsaved edits keeps its
-- layout, because rewriting it would add an undo step between the user's
-- edits, and its window bar says when it fits again.
function M.refit(buf)
  local v = views[buf]
  if not v or not vim.api.nvim_buf_is_valid(buf) then return end
  local width = fit.window_width(buf)
  if not width then return end
  local stale = fit.stale(buf)
  if width == fit.text_width(buf) then
    if stale then
      fit.set_stale(buf, nil)
      update_winbars(buf)
    end
    return
  end
  local ids = v.opts.ids and v.opts.ids(buf) or {}
  local current = region.lines(buf)
  if vim.bo[buf].modified or not vim.bo[buf].modifiable or #ids == 0 or #ids ~= #current then
    if stale ~= width then
      fit.set_stale(buf, width)
      update_winbars(buf)
    end
    return
  end
  local rows = {}
  for i, id in ipairs(ids) do
    local reg = registry.get(id)
    if not reg then return end
    rows[i] = reg.row
  end
  local text = fit.render(buf, rows, ids)
  edit(buf, function()
    for i, line in ipairs(text) do
      if current[i] ~= line then vim.api.nvim_buf_set_text(buf, i - 1, 0, i - 1, #current[i], { line }) end
    end
  end)
  conceal(buf)
  M.decorate(buf, true)
  update_winbars(buf)
  -- A window made narrower scrolls sideways to keep the cursor in view
  -- before the rows are fitted to it; once they fit, it can scroll back.
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_call(win, function() vim.fn.winrestview({ leftcol = 0 }) end)
  end
end

-- labels: { [0-based line] = text }, shown after the end of the line.
function M.set_labels(buf, labels)
  for line, text in pairs(labels) do
    vim.api.nvim_buf_set_extmark(buf, LABELS, line, 0, { virt_text = { { text, "Comment" } }, virt_text_pos = "eol" })
  end
end

-- left: what the view shows (its location and filters); right: its own
-- counts or state ("loading"), shown at the right edge before the counts
-- of unsaved edits.
function M.set_winbar(buf, left, right)
  local v = views[buf]
  if not v then return end
  v.left, v.right = left, right
  update_winbars(buf)
end

-- The view record the change plan reads (core/plan.lua): the rows shown at
-- the last load, from the registry, and the rows parsed from the buffer
-- now. ids: the row ID of each loaded line, in order. extra: fields the
-- plan needs about the view itself (rel, item, ...), copied in.
-- A row ID this buffer did not load is a row pasted from another view; its
-- registry entry becomes the row's origin, so the plan knows which item it
-- shows. An ID the registry no longer holds gets no origin, and the plan
-- rejects the line.
function M.record(buf, kind, state_filter, ids, extra)
  local name = vim.api.nvim_buf_get_name(buf)
  local snapshot, loaded = {}, {}
  for i, rid in ipairs(ids) do
    local s = vim.deepcopy(registry.get(rid).row)
    s.row_id, s.line = rid, i
    snapshot[i] = s
    loaded[rid] = true
  end
  local current = {}
  for i, text in ipairs(region.lines(buf)) do
    local p = lines_mod.parse(text)
    local reg = p.row_id and registry.get(p.row_id)
    if reg and reg.row.kind == "item" and reg.row.slot == "self" then
      p = { row_id = p.row_id, kind = "item", title = lines_mod.body(text) }
    end
    -- Cut cells are planned with their full values (plan 0002 UX5.4).
    local r = fit.read(text)
    if r then
      for column, value in pairs(r.values) do
        if r.kind == "field" then p.value = value else p[lines_mod.key(column)] = value end
      end
      p.ambiguous = r.ambiguous
    end
    if reg and not loaded[p.row_id] then p.origin = { key = reg.view, row = vim.deepcopy(reg.row) } end
    p.line = i
    table.insert(current, p)
  end
  local record = { key = name, kind = kind, state_filter = state_filter, snapshot = snapshot, current = current }
  for k, v in pairs(extra or {}) do record[k] = v end
  return record
end

-- Runs fn now when buf has no unsaved edits, else after the user agrees to
-- discard them (R4.4).
function M.confirm_discard(buf, fn)
  if not vim.bo[buf].modified then return fn() end
  vim.ui.select({ "Discard the edits and reload", "Keep editing" },
    { prompt = "This view has unsaved edits" }, function(choice)
      if choice == "Discard the edits and reload" then fn() end
    end)
end

-- Window sizes change on a resize of the screen or a split, and when the
-- layout opens or closes a window (the detail split, for example).
local resize_group = vim.api.nvim_create_augroup("ado_view_fit", { clear = true })
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = resize_group,
  callback = function()
    local wins = vim.v.event and vim.v.event.windows or vim.api.nvim_list_wins()
    local bufs = {}
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        local b = vim.api.nvim_win_get_buf(win)
        if views[b] then bufs[b] = true end
      end
    end
    if next(bufs) == nil then return end
    vim.schedule(function()
      for b in pairs(bufs) do M.refit(b) end
    end)
  end,
})

function M.show(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  apply_window_options(buf, win)
end

return M
