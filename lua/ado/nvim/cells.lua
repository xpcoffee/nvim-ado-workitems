-- The cell under the cursor and the `ic`/`ac` text objects (plan 0002
-- UX1.7). On an item row the cells follow the parse rule of nvim/lines.lua;
-- on a field line the cell is the value; on the item view's own title
-- line it is the whole title.
local fit = require("ado.nvim.fit")
local lines = require("ado.nvim.lines")
local registry = require("ado.nvim.registry")
local table_layout = require("ado.core.table_layout")

local COLUMNS = table_layout.LAYOUTS.full.columns
local INDENT_CELL = table_layout.LAYOUTS.full.indent

local M = {}

local function is_self(line)
  local id = tonumber(line:match("^/(%d+) "))
  local reg = id and registry.get(id)
  return reg ~= nil and reg.row.kind == "item" and reg.row.slot == "self"
end

-- The start byte of the character that ends at or holds byte `at`.
local function char_start(line, at)
  while at > 1 and (line:byte(at) or 0) >= 0x80 and line:byte(at) < 0xC0 do at = at - 1 end
  return at
end

-- The cell of `line` holding byte `col` (1-based), as 1-based byte ranges
-- of the line: { index, count, from, to, first, last, bar }, the fields of
-- core/table_layout.lua ranges. Field and title lines give one cell.
-- nil on a sub-area or heading line.
function M.at(line, col)
  if is_self(line) then
    local offset = lines.prefix_length(line)
    local first = line:find("%S", offset + 1) or #line + 1
    local last = #line
    while last >= first and line:sub(last, last):match("%s") do last = last - 1 end
    return { index = 1, count = 1, from = offset + 1, to = #line, first = first, last = last }
  end
  local field = lines.field_range(line)
  if field then
    return { index = 1, count = 1, field = true, from = field.lead, to = #line, first = field.first, last = field.last }
  end
  local ranges, offset = lines.row_ranges(line)
  if not ranges then return nil end
  local index = 1
  for i, r in ipairs(ranges) do
    if col >= offset + r.from then index = i end
  end
  return M.nth(line, index, ranges, offset)
end

-- As M.at, for cell `index` of an item row; nil on any other line.
-- ranges and offset: lines.row_ranges(line), when the caller has them.
function M.nth(line, index, ranges, offset)
  if not ranges then
    if is_self(line) then return nil end
    ranges, offset = lines.row_ranges(line)
    if not ranges then return nil end
  end
  local r = ranges[index]
  local first = r.first
  -- The type cell's text includes the indent of a child row.
  if index == INDENT_CELL then first = math.min(r.last + 1, (line:find("%S", offset + first) or 0) - offset) end
  local shift = function(b) return b and b + offset or nil end
  return { index = index, count = #ranges, from = shift(r.from), to = shift(r.to), first = shift(first),
    last = shift(r.last), bar = shift(r.bar), prev_last = index > 1 and shift(ranges[index - 1].last) or nil }
end

-- The bytes `ic` or `ac` selects in cell c of line, first to last
-- (1-based, inclusive), or nil when there is nothing to select.
function M.span(line, c, around)
  if not around then
    if c.last >= c.first then return c.first, c.last end
    -- An empty cell selects its padding, without the space after the
    -- separator before it, so `cic` inserts where its text would start.
    local first = c.index == 1 and c.from or c.from + 1
    local last = math.max(first, c.to - 1)
    if c.field or first > c.to then return nil end
    return first, math.min(last, c.to)
  end
  if c.count == 1 then
    if c.last < c.first then return nil end
    return c.field and c.from or c.first, c.last
  end
  if c.index == c.count then
    -- As `aw` at the end of a line: the whitespace and separator before it.
    return (c.prev_last or c.from) + 1, #line
  end
  local last = c.bar + #"│" - 1
  if c.index == 1 and line:sub(last + 1, last + 1) == " " then last = last + 1 end
  return c.from, last
end

-- Where a value written into cell c goes: the bytes it replaces, first to
-- last (last = first - 1 inserts), and the text to write for `value`. An
-- empty cell takes the value where its text would start; an empty field
-- value gets the gap a loaded line has after its label.
function M.target(line, c, value)
  if c.last >= c.first then return c.first, c.last, value end
  if c.field then return c.from, #line, lines.field_gap(line) .. value end
  if c.index == 1 then return c.from, c.from - 1, value end
  if c.to < c.from then return c.from, c.from - 1, " " .. value .. " " end
  return c.from + 1, c.from, value
end

-- The column cell c of line is: a table column, a field line's field, or
-- the title of the item view's own line.
function M.column(line, c)
  if c.field then return line:match("^/%d+ %s*(%l+):") end
  if c.count == 1 then return "title" end
  return COLUMNS[c.index]
end

-- Writes value into cell `index` (nil on a field line or the item view's
-- own title line) of each 1-based line of buf, as one change. Lines without that cell are left alone.
-- The value replaces the whole cell, so a cut cell takes it as its full
-- value (plan 0002 UX5.3). Returns the number of lines written.
function M.write(buf, line_numbers, index, value)
  local n = 0
  for _, at in ipairs(line_numbers) do
    local line = vim.api.nvim_buf_get_lines(buf, at - 1, at, false)[1]
    local c = line and (index and M.nth(line, index) or M.at(line, #line))
    if c and (index or c.field or c.count == 1) then
      fit.replacing(buf, at, M.column(line, c), value)
      local first, last, text = M.target(line, c, value)
      if line:sub(first, last) ~= text then
        vim.api.nvim_buf_set_text(buf, at - 1, first - 1, at - 1, last, { text })
      end
      n = n + 1
    end
  end
  return n
end

-- Selects the cell under the cursor in charwise Visual mode, for an
-- operator or in Visual mode. Selects nothing on a sub-area or heading
-- line; an operator pending there is cancelled.
function M.select(around)
  local mode = vim.api.nvim_get_mode().mode
  local visual = mode:find("^[vV\22]") ~= nil
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local c = require("ado.nvim.region").readable(0, row) and M.at(line, col + 1) or nil
  local first, last
  if c then first, last = M.span(line, c, around) end
  if not first then
    if not visual then vim.cmd("normal! \27") end
    return
  end
  -- `cic` and `dic` replace the whole cell, so a cut cell takes what is
  -- typed as its full value (plan 0002 UX5.3) instead of restoring it.
  if not visual and (vim.v.operator == "c" or vim.v.operator == "d") then
    fit.replacing(vim.api.nvim_get_current_buf(), row, M.column(line, c), true)
  end
  if visual then vim.cmd("normal! \27") end
  vim.api.nvim_win_set_cursor(0, { row, first - 1 })
  vim.cmd("normal! v")
  vim.api.nvim_win_set_cursor(0, { row, char_start(line, last) - 1 })
end

return M
