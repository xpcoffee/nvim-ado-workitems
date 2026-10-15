-- Row <-> line text for the views (plan 0001 phases 2 and 3):
--
--   /<row id> <type> │ <state> │ <title> │ <assignee> │ <tags>
--   /<row id> <title>                 (the item view's own item)
--   /<row id>   <field>: <value>      (one line per field beneath it)
--   /<row id> ▸ <sub-area name>/
--   /<row id> ── <heading>
--
-- The "/<row id> " prefix is concealed in the buffer (view_buffer.lua).
-- Parsing takes type and state from the first two separators and assignee
-- and tags from the last two, so a title holding "│" or "/" needs no
-- escaping. Rows shown under an expanded row are indented in the type
-- column, and parsing trims the indent (RFC 0001 Q5: indentation carries
-- no meaning).
local table_layout = require("ado.core.table_layout")

local M = {}

M.SEP = table_layout.SEP
local LAYOUT = table_layout.LAYOUTS.full
local AREA_MARK = "▸ "
local HEADING_MARK = "── "
local INDENT = "  "
local FIELD_INDENT = "  "
local FIELD_WIDTH = #"assignee:"

-- Display width in columns. Most cells are plain ASCII, whose width is
-- their length, and a re-pad measures every cell of the view.
function M.measure(s)
  if not s:find("[%c\128-\255]") then return #s end
  return vim.fn.strdisplaywidth(s)
end

local function pad(s, width)
  return s .. string.rep(" ", width - M.measure(s))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local COLUMNS = LAYOUT.columns

local function cell(r, c)
  local text = r[c] or ""
  if c == "type" and (r.depth or 0) > 0 then text = string.rep(INDENT, r.depth) .. text end
  return text
end

local function columns_of(r)
  local cells = {}
  for i, c in ipairs(COLUMNS) do cells[i] = cell(r, c) end
  return cells
end

-- rows: core view rows; ids: the row ID of each, in order. widths: column
-- widths to keep, so rows inserted beneath an expanded row line up with
-- the rows already shown; columns widen to fit, unless exact, when a cell
-- wider than its column runs past it on its own row.
-- Returns the lines, per line the byte length of its concealed prefix, and
-- the column widths used.
function M.render(rows, ids, widths, exact)
  if not exact then
    local table_rows = {}
    for _, r in ipairs(rows) do
      if r.kind == "item" and r.slot ~= "self" then table.insert(table_rows, columns_of(r)) end
    end
    widths = table_layout.widths(table_rows, M.measure, widths or { 0, 0, 0, 0, 0 })
  end
  local out, prefixes = {}, {}
  for i, r in ipairs(rows) do
    local prefix = "/" .. ids[i] .. " "
    local body
    if r.kind == "area" then
      body = AREA_MARK .. r.name .. "/"
    elseif r.kind == "heading" then
      body = HEADING_MARK .. r.label
    elseif r.kind == "field" then
      body = (FIELD_INDENT .. pad(r.field .. ":", FIELD_WIDTH) .. " " .. (r.value or "")):gsub("%s+$", "")
    elseif r.slot == "self" then
      body = r.title or ""
    else
      body = table_layout.pad(columns_of(r), widths, M.measure)
    end
    out[i] = prefix .. body
    prefixes[i] = #prefix
  end
  return out, prefixes, widths
end

-- The byte length of the line's row ID prefix, 0 when it has none.
function M.prefix_length(line)
  local prefix = line:match("^/%d+ ")
  return prefix and #prefix or 0
end

-- The line after its row ID prefix, trimmed: the whole title of the item
-- view's own row, whatever it holds.
function M.body(line)
  local rest = line:match("^/%d+ (.*)$") or line
  return trim(rest)
end

local function kind_of(id, rest)
  if not id then return "item" end
  if rest:match("^" .. AREA_MARK .. ".*/$") then return "area" end
  if rest:match("^" .. HEADING_MARK) then return "heading" end
  if rest:match("^" .. FIELD_INDENT .. "%l+:") then return "field" end
  return "item"
end

-- The cells of an item row, as table_layout.ranges gives them for the
-- text after the row ID prefix, and that prefix's byte length; nil for a
-- sub-area, heading or field line, or a line without the separators of a
-- row. Ranges count from the start of the body, not of the line.
function M.row_ranges(line)
  local id, rest = line:match("^/(%d+) (.*)$")
  if not id then rest = line end
  if kind_of(id, rest) ~= "item" then return nil end
  local ranges = table_layout.ranges(rest, LAYOUT)
  if not ranges then return nil end
  return ranges, #line - #rest, rest
end

-- The bytes of a field line's value in the line, first to last (last <
-- first when it is empty), and where the whitespace before it starts; nil
-- for other lines.
function M.field_range(line)
  local id, rest = line:match("^/(%d+) (.*)$")
  if not id or kind_of(id, rest) ~= "field" then return nil end
  local offset = #line - #rest
  local _, e = rest:find("^" .. FIELD_INDENT .. "%l+:")
  local first = rest:find("%S", e + 1) or #rest + 1
  local last = #rest
  while last >= first and rest:sub(last, last):match("%s") do last = last - 1 end
  return { first = offset + first, last = offset + last, lead = offset + e + 1 }
end

-- The spaces a rendered field line has between its label and its value,
-- for a field line whose value is empty.
function M.field_gap(line)
  local field = line:match("^/%d+ " .. FIELD_INDENT .. "(%l+):")
  return string.rep(" ", FIELD_WIDTH - #((field or "") .. ":") + 1)
end

-- { row_id, kind = "area", name }, { row_id, kind = "heading", label } or
-- { row_id, kind = "item", type, state, assignee, tags, title }. A line
-- without a row ID prefix has row_id nil.
function M.parse(line)
  local id, rest = line:match("^/(%d+) (.*)$")
  if not id then rest = line end
  local row_id = id and tonumber(id) or nil
  local kind = kind_of(id, rest)
  if kind == "area" then return { row_id = row_id, kind = "area", name = rest:match("^" .. AREA_MARK .. "(.*)/$") } end
  if kind == "heading" then
    return { row_id = row_id, kind = "heading", label = rest:match("^" .. HEADING_MARK .. "(.*)$") }
  end
  if kind == "field" then
    local field, value = rest:match("^" .. FIELD_INDENT .. "(%l+):%s*(.-)%s*$")
    return { row_id = row_id, kind = "field", field = field, value = value }
  end
  local ranges = table_layout.ranges(rest, LAYOUT)
  if not ranges then
    return { row_id = row_id, kind = "item", title = trim(rest) }
  end
  local p = { row_id = row_id, kind = "item" }
  for i, text in ipairs(table_layout.cells(rest, ranges)) do p[COLUMNS[i]] = trim(text) end
  return p
end

return M
