-- The column layout of the views' item rows (plan 0002 phase 1): column
-- widths, padding, and where each cell sits in a row's text. A row's text
-- here is the line after its row ID prefix:
--
--   <id> │ <type> │ <state> │ <title> │ <assignee> │ <tags>
--
-- Cells are found by the parse rule of nvim/lines.lua: the cells before the
-- title end at the first separators and the cells after it start at the
-- last ones, so a title holding "│" is one cell. String width is passed in
-- as `measure`, the display width in columns. The id cell shows the work
-- item's ID for copying; the row ID prefix, not this cell, says which item
-- a line is.
local M = {}

M.SEP = " │ "
local BAR = "│"

-- head: cells before the title; tail: cells after it; indent: the cell
-- that holds the indent of child rows, the tree column.
M.LAYOUTS = {
  full = { columns = { "id", "type", "state", "title", "assignee", "tags" }, head = 3, tail = 2, indent = 2 },
}

-- The index of each column in the full layout.
M.INDEX = {}
for i, c in ipairs(M.LAYOUTS.full.columns) do M.INDEX[c] = i end

-- The mark that ends a cut cell (plan 0002 UX4.2).
M.ELLIPSIS = "…"

-- Widths a column may take when the window is too narrow for every cell
-- (UX4.1); the title gets the rest, and no less than MIN_TITLE.
M.BUDGETS = { type = 10, state = 10, assignee = 14, tags = 14 }
M.MIN_TITLE = 20
M.SHORT_ASSIGNEE = 8
M.SEP_WIDTH = 3

local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- The steps of UX4.1, narrowest last: each keeps the caps of the steps
-- before it.
local STEPS = { "full", "tags", "letters", "assignee" }

local function is_space(byte)
  return byte == 32 or byte == 9
end

-- rows: lists of cell texts, the indent cell with its indent. keep: widths
-- to start from, so rows added beneath an expanded row line up with the
-- rows already shown. Returns the widest cell per column.
function M.widths(rows, measure, keep)
  local out = {}
  for i, w in ipairs(keep or {}) do out[i] = w end
  for _, cells in ipairs(rows) do
    for i, text in ipairs(cells) do
      out[i] = math.max(out[i] or 0, measure(text))
    end
  end
  return out
end

-- The row's text: cells padded to widths and joined by M.SEP, without
-- trailing whitespace.
function M.pad(cells, widths, measure)
  local parts = {}
  for i, text in ipairs(cells) do
    parts[i] = text .. string.rep(" ", (widths[i] or 0) - measure(text))
  end
  return (table.concat(parts, M.SEP):gsub("%s+$", ""))
end

-- The byte range of each cell in text, in layout's column order, or nil
-- when text has fewer separators than the layout needs. Per cell:
--   from, to     the bytes between its separators (to = from - 1 when none)
--   first, last  its text without surrounding spaces (last < first when
--                empty); the indent cell's text starts after the one space
--                that follows its separator, so its indent counts as text
--   bar          the byte where the separator after it starts (nil for
--                the last cell)
function M.ranges(text, layout)
  local bars = {}
  local pos = 1
  while true do
    local s = text:find(BAR, pos, true)
    if not s then break end
    table.insert(bars, s)
    pos = s + #BAR
  end
  local n = #bars
  if n < layout.head + layout.tail then return nil end
  local used = {}
  for i = 1, layout.head do used[#used + 1] = bars[i] end
  for i = n - layout.tail + 1, n do used[#used + 1] = bars[i] end
  local out = {}
  for i = 1, #used + 1 do
    local from = i == 1 and 1 or used[i - 1] + #BAR
    local to = i <= #used and used[i] - 1 or #text
    local first, last = from, to
    if i == layout.indent then
      if i > 1 and first <= to and is_space(text:byte(first)) then first = first + 1 end
    else
      while first <= to and is_space(text:byte(first)) do first = first + 1 end
    end
    while last >= first and is_space(text:byte(last)) do last = last - 1 end
    if last < first then first, last = from, from - 1 end
    out[i] = { from = from, to = to, first = first, last = last, bar = used[i] }
  end
  return out
end

-- The cell texts of ranges: the indent cell with its indent, the rest
-- trimmed.
function M.cells(text, ranges)
  local out = {}
  for i, r in ipairs(ranges) do out[i] = text:sub(r.first, r.last) end
  return out
end

-- The edits that re-pad text to widths, rewriting only the runs of spaces
-- that differ from M.pad's: { from, to, text } byte ranges of text (to =
-- from - 1 inserts), from the last to the first, so applying them in order
-- keeps the earlier offsets valid. A cell's own text is rewritten only
-- when replace[i] holds a different text for it (the indent cell's with
-- its indent), as a cut cell shown cut again.
function M.edits(text, ranges, widths, measure, replace)
  local edits = {}
  local function want(from, to, wanted)
    if text:sub(from, to) ~= wanted then table.insert(edits, { from = from, to = to, text = wanted }) end
  end
  local n = #ranges
  for i, r in ipairs(ranges) do
    local empty = r.last < r.first
    local current = empty and "" or text:sub(r.first, r.last)
    local new = replace and replace[i] or current
    local fill = string.rep(" ", math.max(0, (widths[i] or 0) - measure(new)))
    local lead = i == 1 and "" or " "
    local trail = i == n and "" or fill .. " "
    if new == "" then
      want(r.from, r.to, i == n and "" or lead .. trail)
    elseif empty then
      want(r.from, r.to, lead .. new .. trail)
    else
      want(r.from, r.first - 1, lead)
      if new ~= current then want(r.first, r.last, new) end
      want(r.last + 1, r.to, trail)
    end
  end
  table.sort(edits, function(a, b) return a.from > b.from end)
  return edits
end

-- The column widths for a row text width (UX4.1). text_width: the columns
-- the row's text may take; natural: the widest value per column (type with
-- the indent of child rows), and letters, the widest type cell shown as one
-- letter with its indent; extra: columns the row takes beyond its text (the
-- state dot). The id column always keeps its natural width and is taken
-- first, because a cut ID could not be copied. The first step whose title
-- gets MIN_TITLE (or its natural width, when narrower) wins. Columns that
-- fit keep their natural width, and room the title does not need goes
-- back to the columns cut. Returns
-- { step, letters, widths = { id, type, state, title, assignee, tags } }.
function M.budget(text_width, natural, extra)
  local function nat(c) return natural[c] or 0 end
  local title_floor = math.min(M.MIN_TITLE, nat("title"))
  local w, step, rest
  for i, name in ipairs(STEPS) do
    step = name
    w = {}
    for c, cap in pairs(M.BUDGETS) do w[c] = math.min(nat(c), cap) end
    if i >= 2 then w.tags = math.min(nat("tags"), 1) end
    if i >= 3 then w.type = math.min(nat("type"), nat("letters")) end
    if i >= 4 then w.assignee = math.min(nat("assignee"), M.SHORT_ASSIGNEE) end
    w.id = nat("id")
    rest = text_width - (extra or 0) - 5 * M.SEP_WIDTH - w.id - w.type - w.state - w.assignee - w.tags
    if rest >= title_floor then break end
  end
  w.title = math.max(math.min(nat("title"), rest), title_floor)
  local leftover = rest - w.title
  local letters = step == "letters" or step == "assignee"
  for _, c in ipairs({ "assignee", "tags", "state", "type" }) do
    if leftover <= 0 then break end
    if not (c == "type" and letters) then
      local add = math.min(leftover, nat(c) - w[c])
      if add > 0 then
        w[c] = w[c] + add
        leftover = leftover - add
      end
    end
  end
  return { step = step, letters = letters, widths = w }
end

-- The widths of a budget in the full layout's column order.
function M.ordered(widths)
  local out = {}
  for i, c in ipairs(M.LAYOUTS.full.columns) do out[i] = widths[c] end
  return out
end

-- text shortened to width columns, ending in ELLIPSIS, or text itself when
-- it fits. A character is never split: one that does not fit whole is
-- left out. A cell with text never cuts to nothing, so its mark shows.
function M.cut(text, width, measure)
  if measure(text) <= width then return text end
  local out, used = {}, 0
  for ch in text:gmatch(UTF8_CHAR) do
    local w = measure(ch)
    if used + w > width - 1 then break end
    out[#out + 1] = ch
    used = used + w
  end
  return table.concat(out) .. M.ELLIPSIS
end

-- The one letter a type shows as in a narrow window: overrides[type], else
-- the first character of its name's last word ("User Story" is "S").
function M.letter(type_name, overrides)
  if overrides and overrides[type_name] then return overrides[type_name] end
  local word = type_name:match("(%S+)%s*$")
  return word and word:match(UTF8_CHAR) or ""
end

local function ends_cut(text)
  return #text >= #M.ELLIPSIS and text:sub(-#M.ELLIPSIS) == M.ELLIPSIS
end

-- The restore rule (plan 0002 phase 5): a cut cell's text is a head of the
-- full value followed by ELLIPSIS. When the text changed from before to
-- now and still ends in ELLIPSIS, the edit lay in the head, so the new full
-- value is the new head followed by the part of full that before hid.
-- nil when before is not a cut of full, or now no longer ends in ELLIPSIS
-- (the mark deleted, or text typed after it), which no rule can restore.
function M.restore(full, before, now)
  if not (ends_cut(before) and ends_cut(now)) then return nil end
  local head = before:sub(1, -#M.ELLIPSIS - 1)
  if full == before or full:sub(1, #head) ~= head then return nil end
  return now:sub(1, -#M.ELLIPSIS - 1) .. full:sub(#head + 1)
end

-- text with edits applied, as the buffer has it after a re-pad.
function M.apply(text, edits)
  for _, e in ipairs(edits) do
    text = text:sub(1, e.from - 1) .. e.text .. text:sub(e.to + 1)
  end
  return text
end

return M
