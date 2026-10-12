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
local M = {}

M.SEP = " │ "
local AREA_MARK = "▸ "
local HEADING_MARK = "── "
local INDENT = "  "
local FIELD_INDENT = "  "
local FIELD_WIDTH = #"assignee:"

local function pad(s, width)
  return s .. string.rep(" ", width - vim.fn.strdisplaywidth(s))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local COLUMNS = { "type", "state", "title", "assignee", "tags" }

local function cell(r, c)
  local text = r[c] or ""
  if c == "type" and (r.depth or 0) > 0 then text = string.rep(INDENT, r.depth) .. text end
  return text
end

-- rows: core view rows; ids: the row ID of each, in order. widths: column
-- widths to keep, so rows inserted beneath an expanded row line up with
-- the rows already shown; columns widen to fit.
-- Returns the lines, per line the byte length of its concealed prefix, and
-- the column widths used.
function M.render(rows, ids, widths)
  widths = { unpack(widths or { 0, 0, 0, 0, 0 }) }
  for _, r in ipairs(rows) do
    if r.kind == "item" and r.slot ~= "self" then
      for i, c in ipairs(COLUMNS) do
        widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(cell(r, c)))
      end
    end
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
      local cells = {}
      for j, c in ipairs(COLUMNS) do cells[j] = pad(cell(r, c), widths[j]) end
      body = (table.concat(cells, M.SEP):gsub("%s+$", ""))
    end
    out[i] = prefix .. body
    prefixes[i] = #prefix
  end
  return out, prefixes, widths
end

-- { row_id, kind = "area", name }, { row_id, kind = "heading", label } or
-- { row_id, kind = "item", type, state, assignee, tags, title }. A line
-- without a row ID prefix has row_id nil.
function M.parse(line)
  local id, rest = line:match("^/(%d+) (.*)$")
  if not id then rest = line end
  local row_id = id and tonumber(id) or nil
  local name = rest:match("^" .. AREA_MARK .. "(.*)/$")
  if id and name then return { row_id = row_id, kind = "area", name = name } end
  local label = rest:match("^" .. HEADING_MARK .. "(.*)$")
  if id and label then return { row_id = row_id, kind = "heading", label = label } end
  local field, value = rest:match("^" .. FIELD_INDENT .. "(%l+):%s*(.-)%s*$")
  if id and field then return { row_id = row_id, kind = "field", field = field, value = value } end
  local seps = {}
  local pos = 1
  while true do
    local s, e = rest:find("│", pos, true)
    if not s then break end
    table.insert(seps, { s, e })
    pos = e + 1
  end
  if #seps < 4 then
    return { row_id = row_id, kind = "item", title = trim(rest) }
  end
  local function between(a, b)
    local from = a and seps[a][2] + 1 or 1
    local to = b and seps[b][1] - 1 or #rest
    return trim(rest:sub(from, to))
  end
  local n = #seps
  return { row_id = row_id, kind = "item", type = between(nil, 1), state = between(1, 2),
    title = between(2, n - 1), assignee = between(n - 1, n), tags = between(n, nil) }
end

return M
