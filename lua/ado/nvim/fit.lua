-- Fits the views' rows to their window (plan 0002 phase 5, option T). Long
-- cells are cut in the buffer text, ending in "…", and each cut cell's full
-- value is kept in its row's registry entry, in the shown map that
-- core/fit.lua describes. This module reads cells from buffer lines, looks
-- their values up, renders rows cut to a text width, and works out the
-- re-pad after an edit, which nvim/realign.lua applies.
local config = require("ado.config")
local core = require("ado.core.fit")
local lines = require("ado.nvim.lines")
local region = require("ado.nvim.region")
local registry = require("ado.nvim.registry")
local table_layout = require("ado.core.table_layout")
local ux_stats = require("ado.nvim.ux_stats")

local M = {}

local COLUMNS = table_layout.LAYOUTS.full.columns
local INDENT_CELL = table_layout.LAYOUTS.full.indent

-- The state dot before each state cell is 2 columns of inline virtual text
-- (nvim/decorations.lua). Neovim scrolls a window sideways by every column
-- before the cursor, including concealed and virtual text, so the row ID
-- prefix and the dot count towards the width, and one column stays free
-- so the cursor after the last character in Insert mode does not scroll.
local DOT = 2
local RESERVE = 1
-- "  assignee: " before a field line's value.
local FIELD_LABEL = 12

-- buf -> { text_width (when last rendered), stale = text width of the
-- window now, when it differs and the view could not be re-rendered }
local layouts = {}
-- buf -> { [line] = { [column] = text expected, or true } }: cells the next
-- re-pad must take whole, because the edit replaced them (UX5.3).
local replacing = {}
-- buf -> { ["<row id>:<column>"] = true }: cells shown in full by
-- <leader>wx, not cut again until the next render (UX5.2).
local full = {}
-- buf -> the cells of every line at the last re-pad, and the undo state
-- then: { seq, root, rows = { [line] = { id, texts = { [column] = text } } } }
local snapshots = {}

-- The width of buf's text in the narrowest window showing it: the window
-- minus the sign, number and fold columns. nil when no window shows it.
function M.window_width(buf)
  local narrowest
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local w = info.width - info.textoff
      if not narrowest or w < narrowest then narrowest = w end
    end
  end
  return narrowest
end

-- The text width buf is laid out for: the one it was last rendered at,
-- else its window's, else the screen's less a sign column.
function M.text_width(buf)
  local l = layouts[buf]
  return (l and l.text_width) or M.window_width(buf) or (vim.o.columns - 2)
end

-- The window width when it differs from the one buf is laid out for.
function M.stale(buf)
  local l = layouts[buf]
  return l and l.stale or nil
end

function M.set_stale(buf, width)
  layouts[buf] = layouts[buf] or {}
  layouts[buf].stale = width
end

local function map_of(reg, column)
  return reg and reg.shown and reg.shown[column] or nil
end

local function set_map(reg, column, map)
  if not reg or not map then return end
  reg.shown = reg.shown or {}
  reg.shown[column] = map
end

-- The value a cell was loaded with, from its row's registry entry.
local function loaded_value(reg, kind, column)
  if not reg then return nil end
  local row = reg.row
  if kind == "field" then return row.kind == "field" and (row.value or "") or nil end
  if row.kind ~= "item" then return nil end
  return lines.value(row, column)
end

local function is_self(reg)
  return reg ~= nil and reg.row.kind == "item" and reg.row.slot == "self"
end

-- The cells of a line: { row_id, reg, kind = "table" | "self" | "field",
-- offset, body, ranges, cells = { { column, text, indent, first, last } } },
-- text trimmed (the type without the indent of a child row), first and
-- last its bytes in the line (last < first when empty). nil for a line
-- with no cells (a sub-area row, a heading, a line without separators).
function M.cells(line)
  local id = tonumber(line:match("^/(%d+) "))
  local reg = id and registry.get(id)
  if is_self(reg) then
    local offset = lines.prefix_length(line)
    local first = line:find("%S", offset + 1) or #line + 1
    local last = #line
    while last >= first and line:sub(last, last):match("%s") do last = last - 1 end
    return { row_id = id, reg = reg, kind = "self",
      cells = { { column = "title", text = line:sub(first, last), first = first, last = last } } }
  end
  local f = id and line:find("^/%d+   %l+:") and lines.field_range(line)
  if f then
    local field = line:match("^/%d+ " .. "%s*(%l+):")
    return { row_id = id, reg = reg, kind = "field", field = field,
      cells = { { column = field, text = line:sub(f.first, f.last), first = f.first, last = f.last } } }
  end
  local ranges, offset, body = lines.row_ranges(line)
  if not ranges then return nil end
  local out = { row_id = id, reg = reg, kind = "table", offset = offset, body = body, ranges = ranges, cells = {} }
  for i, r in ipairs(ranges) do
    -- Ranges exclude the spaces around a cell, except the type cell's
    -- indent.
    local text, indent = body:sub(r.first, r.last), ""
    if i == INDENT_CELL then
      indent = text:match("^%s*")
      text = text:sub(#indent + 1)
    end
    out.cells[i] = { column = COLUMNS[i], text = text, indent = indent,
      first = offset + r.first, last = offset + r.last }
  end
  return out
end

-- The value of a cell's text: value (nil when not known) and how it was
-- found ("plain", "cut" or "ambiguous").
function M.lookup(row_id, column, text)
  local reg = row_id and registry.get(row_id)
  local kind = reg and reg.row.kind == "field" and "field" or "item"
  local map = map_of(reg, column)
  -- The save checks a type against the project's types, so text the map
  -- does not know (a type typed over its letter) is the value.
  if column == "type" and (not map or map[text] == nil) then return text, "plain" end
  return core.lookup(map, text, loaded_value(reg, kind, column))
end

-- The line as the save and the markers read it: { row_id, kind, values =
-- { [column] = value }, ambiguous = { column... } | nil, cells }. A cell
-- whose value is not known keeps its text in values.
function M.read(line)
  local c = M.cells(line)
  if not c then return nil end
  local values, ambiguous = {}, nil
  for _, cell in ipairs(c.cells) do
    local v, how = M.lookup(c.row_id, cell.column, cell.text)
    if how == "ambiguous" then
      ambiguous = ambiguous or {}
      table.insert(ambiguous, cell.column)
      v = cell.text
    end
    values[cell.column] = v
  end
  c.values, c.ambiguous = values, ambiguous
  return c
end

-- Marks cell `column` of line (1-based) as replaced whole by the next
-- edit; expected: the text written, or true when it is typed.
function M.replacing(buf, line, column, expected)
  replacing[buf] = replacing[buf] or {}
  replacing[buf][line] = replacing[buf][line] or {}
  replacing[buf][line][column] = expected
end

-- Shows the cell in full until the next render (<leader>wx).
function M.keep_full(buf, row_id, column)
  full[buf] = full[buf] or {}
  full[buf][row_id .. ":" .. column] = true
end

local function letter_of(type_name)
  return table_layout.letter(type_name, (config.get().ui or {}).type_letters)
end

local function widest_prefix(ids)
  local w = 0
  for _, id in ipairs(ids) do w = math.max(w, #tostring(id) + 2) end
  return w
end


-- The widths of table rows for text_width: rows = { { values, indent } },
-- prefix = the widest row ID prefix. Returns the core budget.
local function layout_for(text_width, prefix, rows)
  local natural = { id = 0, type = 0, letters = 0, state = 0, title = 0, assignee = 0, tags = 0 }
  for _, r in ipairs(rows) do
    local indent = r.indent or ""
    for _, c in ipairs(COLUMNS) do
      local w = lines.measure(r.values[c] or "")
      if c == "type" then
        natural.letters = math.max(natural.letters, #indent + lines.measure(letter_of(r.values.type or "")))
        w = w + #indent
      end
      natural[c] = math.max(natural[c], w)
    end
  end
  return table_layout.budget(text_width - prefix - RESERVE, natural, DOT)
end

-- What a table cell shows for value at the layout's widths. An ID is
-- never cut.
local function shown_text(column, value, indent, b)
  if column == "id" then return value end
  if column == "type" then
    if b.letters then return value ~= "" and letter_of(value) or "" end
    return table_layout.cut(value, b.widths.type - #indent, lines.measure)
  end
  return table_layout.cut(value, b.widths[column], lines.measure)
end

-- The width a field line's value or the item's own title may take.
local function single_width(text_width, prefix, kind, column)
  if kind == "field" and column == "id" then return math.huge end
  local w = text_width - prefix - RESERVE
  if kind == "field" then w = w - FIELD_LABEL - (column == "state" and DOT or 0) end
  return math.max(w, table_layout.MIN_TITLE)
end

local function render(buf, rows, ids, text_width)
  local started = vim.uv.hrtime()
  local prefix = widest_prefix(ids)
  local table_rows = {}
  for _, r in ipairs(rows) do
    if r.kind == "item" and r.slot ~= "self" then
      local values = {}
      for _, c in ipairs(COLUMNS) do values[c] = lines.value(r, c) end
      table.insert(table_rows, { values = values, indent = string.rep("  ", r.depth or 0) })
    end
  end
  local b = layout_for(text_width, prefix, table_rows)
  local shown_rows = {}
  for i, r in ipairs(rows) do
    local reg = registry.get(ids[i])
    local copy = setmetatable({}, { __index = r })
    if r.kind == "item" and r.slot ~= "self" then
      local indent = string.rep("  ", r.depth or 0)
      for _, c in ipairs(COLUMNS) do
        local value = lines.value(r, c)
        local shown, map = core.remember(map_of(reg, c), shown_text(c, value, indent, b), value, value)
        set_map(reg, c, map)
        copy[lines.key(c)] = shown
      end
    elseif r.kind == "item" or r.kind == "field" then
      local column = r.kind == "field" and r.field or "title"
      local key = r.kind == "field" and "value" or "title"
      local value = r[key] or ""
      local width = single_width(text_width, prefix, r.kind, column)
      local shown, map = core.remember(map_of(reg, column), table_layout.cut(value, width, lines.measure), value, value)
      set_map(reg, column, map)
      copy[key] = shown
    end
    shown_rows[i] = copy
  end
  local widths = table_layout.ordered(b.widths)
  local text, prefixes = lines.render(shown_rows, ids, widths, true)
  ux_stats.record("fit", (vim.uv.hrtime() - started) / 1e6, { rows = #rows })
  return text, prefixes, widths
end

-- Renders core rows for buf at its window's text width, cutting long
-- cells, and keeps each cut cell's full value. Returns the lines, the
-- prefix lengths and the column widths (in table_layout's order), as
-- lines.render does.
function M.render(buf, rows, ids)
  local text_width = M.window_width(buf) or (vim.o.columns - 2)
  layouts[buf] = { text_width = text_width }
  full[buf], replacing[buf] = nil, nil
  return render(buf, rows, ids, text_width)
end

-- As render, for rows added to those buf shows (an expansion), at the
-- text width buf is laid out for.
function M.render_more(buf, rows, ids)
  return render(buf, rows, ids, M.text_width(buf))
end

-- buf -> the undo state number after the plugin's last own edit, which
-- leaves the undo history empty: the root of every later state.
local roots = {}

-- Records the cells of every line and the undo state, so the next re-pad
-- knows what an edited cell held before. settled: after an edit of the
-- plugin's own (a load, an expansion), which clears the undo history.
function M.snapshot(buf, settled)
  local all = region.lines(buf)
  local seq = vim.api.nvim_buf_call(buf, function() return vim.fn.changenr() end)
  if settled then roots[buf] = seq end
  local rows = {}
  for i, line in ipairs(all) do
    local c = M.cells(line)
    if c and c.row_id then
      local texts = {}
      for _, cell in ipairs(c.cells) do texts[cell.column] = cell.text end
      rows[i] = { id = c.row_id, texts = texts }
    end
  end
  snapshots[buf] = { seq = seq, root = seq == roots[buf], rows = rows }
end

-- Whether the snapshot shows the state the newest change was made from,
-- or one before it on the same path, so the text it holds for a cell is
-- the cell's text before the edit.
local function snapshot_trusted(buf)
  local snap = snapshots[buf]
  if not snap then return false end
  if snap.root then return true end
  local tree = vim.api.nvim_buf_call(buf, function() return vim.fn.undotree() end)
  for _, e in ipairs(tree.entries) do
    if e.seq == snap.seq then return true end
  end
  return false
end

-- The cell's text in the snapshot: from the same line when it holds the
-- same row, else from the one line holding that row, or from several that
-- agree. nil when it is not known.
local function before_text(buf, line, row_id, column)
  local snap = snapshots[buf]
  if not snap then return nil end
  local same = snap.rows[line]
  if same and same.id == row_id then return same.texts[column] end
  local found
  for _, r in pairs(snap.rows) do
    if r.id == row_id then
      local t = r.texts[column]
      if found ~= nil and found ~= t then return nil end
      found = t
    end
  end
  return found
end

-- The re-pad of buf's text `all`: per line that needs it, { line (0-based),
-- offset, edits (core/table_layout.lua edits, from `offset` bytes into the
-- line) }, and the number of table rows. Records the text each cell shows
-- after the re-pad in its shown map. A text recorded for an edit the
-- caller then does not make is harmless: no line holds it, and a cell
-- whose text the map does not know has no value. user: the text was
-- changed by an edit of the user's, so a cut cell whose text the map does
-- not know is restored from its text before the edit.
function M.plan(buf, all, user)
  local pending = replacing[buf] or {}
  replacing[buf] = nil
  local kept = full[buf] or {}
  local trusted
  local function is_trusted()
    if trusted == nil then trusted = snapshot_trusted(buf) end
    return trusted
  end
  local read, table_rows, prefix = {}, {}, 0
  for i, line in ipairs(all) do
    prefix = math.max(prefix, lines.prefix_length(line))
    local c = M.cells(line)
    if c then
      c.line, c.values = i, {}
      local kind = c.kind == "field" and "field" or "item"
      for _, cell in ipairs(c.cells) do
        cell.loaded = c.row_id and loaded_value(c.reg, kind, cell.column) or nil
        local value
        local map = cell.loaded ~= nil and map_of(c.reg, cell.column) or nil
        local replaced = pending[i] and pending[i][cell.column]
        if cell.loaded == nil or cell.text == cell.loaded then
          value = cell.text
        elseif not map and replaced == nil then
          value = cell.column == "type" and cell.text or core.lookup(nil, cell.text, cell.loaded)
        else
          local ctx = { loaded = cell.loaded, enum = cell.column == "type", replaced = replaced }
          if user and map and map[cell.text] == nil and ctx.replaced == nil and not ctx.enum then
            ctx.before = before_text(buf, i, c.row_id, cell.column)
            ctx.trusted = ctx.before ~= nil and is_trusted()
          end
          value = core.resolve(map, cell.text, ctx)
        end
        c.values[cell.column] = value
      end
      table.insert(read, c)
      if c.kind == "table" then
        local values = {}
        for _, cell in ipairs(c.cells) do values[cell.column] = c.values[cell.column] or cell.text end
        table.insert(table_rows, { values = values, indent = c.cells[INDENT_CELL].indent })
      end
    end
  end
  local text_width = M.text_width(buf)
  local b = layout_for(text_width, prefix, table_rows)
  local widths = table_layout.ordered(b.widths)
  local todo, after = {}, {}
  for _, c in ipairs(read) do
    local replace, changed = {}, false
    local texts = {}
    if c.row_id then after[c.line] = { id = c.row_id, texts = texts } end
    for k, cell in ipairs(c.cells) do
      local value, shown = c.values[cell.column], cell.text
      if cell.loaded ~= nil then
        if value ~= nil and not kept[c.row_id .. ":" .. cell.column] then
          shown = c.kind == "table" and shown_text(cell.column, value, cell.indent, b)
            or table_layout.cut(value, single_width(text_width, prefix, c.kind, cell.column), lines.measure)
        end
        local map
        shown, map = core.remember(map_of(c.reg, cell.column), shown, value, cell.loaded)
        set_map(c.reg, cell.column, map)
      end
      if shown ~= cell.text then changed = true end
      replace[k] = (cell.indent or "") .. shown
      texts[cell.column] = shown
    end
    if c.kind == "table" then
      local edits = table_layout.edits(c.body, c.ranges, widths, lines.measure, replace)
      if #edits > 0 then table.insert(todo, { line = c.line - 1, offset = c.offset, edits = edits }) end
    elseif changed then
      local cell = c.cells[1]
      table.insert(todo, { line = c.line - 1, offset = 0,
        edits = { { from = cell.first, to = cell.last, text = replace[1] } } })
    end
  end
  return todo, #table_rows, after
end

-- Records the cells the re-pad left (plan's third result) as the snapshot,
-- once its edits are in the buffer.
function M.snapshot_rows(buf, rows)
  local seq = vim.api.nvim_buf_call(buf, function() return vim.fn.changenr() end)
  snapshots[buf] = { seq = seq, root = seq == roots[buf], rows = rows }
end

-- How many texts the shown maps hold, for ux_stats.
function M.map_size()
  local n = 0
  registry.each(function(entry)
    for _, map in pairs(entry.shown or {}) do n = n + core.size(map) end
  end)
  return n
end

function M.forget(buf)
  layouts[buf], replacing[buf], full[buf], snapshots[buf], roots[buf] = nil, nil, nil, nil, nil
end

return M
