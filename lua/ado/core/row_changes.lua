-- Which fields of a row changed against the row it was loaded as (plan 0002
-- UX2.4). The change plan (core/plan.lua) and the views' change markers
-- both read it, so a row marked changed and a line in the save summary
-- always agree on what the row edits.
--
-- Rows are those of core/plan.lua's view records: a snapshot (or origin)
-- row as the core views build it, and a current row as the presentation
-- layer parses it from the buffer.
local M = {}

-- The columns a row edit can change, in the order their ops run on one item.
M.FIELDS = { "title", "type", "state", "assignee", "tags" }

function M.trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
local trim = M.trim

-- "b; A; a" -> { "A", "b" }: ADO keeps tags as a set, compared without
-- regard to case, so order and repeats carry no meaning.
function M.norm_tags(s)
  local out, seen = {}, {}
  for tag in (s or ""):gmatch("[^;]+") do
    local t = trim(tag)
    if t ~= "" and not seen[t:lower()] then
      seen[t:lower()] = true
      table.insert(out, t)
    end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

function M.tags_text(s)
  return table.concat(M.norm_tags(s), "; ")
end

-- A column's value as the plan compares and sends it: tags as a sorted
-- set, any other text trimmed.
function M.value(field, text)
  if field == "tags" then return M.tags_text(text) end
  return trim(text)
end

-- Whether text edits a field loaded as `loaded`. Tags compare without
-- regard to case, as ADO matches them.
function M.differs(field, text, loaded)
  local a, b = M.value(field, text), M.value(field, loaded)
  if field == "tags" then return a:lower() ~= b:lower() end
  return a ~= b
end

-- A current item row with no text in any column, such as an empty line.
function M.blank(c)
  for _, f in ipairs(M.FIELDS) do
    if trim(c[f]) ~= "" then return false end
  end
  return true
end

-- The edits current row c makes to s, the row it was loaded as:
-- { [field] = new value }, as M.value gives it, and a problem when c can no
-- longer be compared with s:
--   "kind"        c no longer reads as the kind of row s is
--   "self_copy"   s is an item view's own title line, which holds only the
--                 title, and c has the columns of a table row
--   "separators"  c lacks the separators of a table row
--   "field_name"  c is a field line naming another field
-- Sub-area rows report a changed name and headings a changed label, which
-- the plan rejects as read-only.
function M.changed(s, c)
  local diffs = {}
  if s.kind == "item" then
    if c.kind ~= "item" then return diffs, "kind" end
    if s.slot == "self" then
      if c.type ~= nil then return diffs, "self_copy" end
      if trim(c.title) ~= trim(s.title) then diffs.title = trim(c.title) end
      return diffs
    end
    if c.type == nil then return diffs, "separators" end
    for _, f in ipairs(M.FIELDS) do
      if M.differs(f, c[f], s[f]) then diffs[f] = M.value(f, c[f]) end
    end
    return diffs
  end
  if c.kind ~= s.kind then return diffs, "kind" end
  if s.kind == "field" then
    if c.field ~= s.field then return diffs, "field_name" end
    if M.differs(s.field, c.value, s.value) then diffs[s.field] = M.value(s.field, c.value) end
  elseif s.kind == "area" then
    if trim(c.name) ~= trim(s.name) then diffs.name = trim(c.name) end
  elseif s.kind == "heading" then
    if trim(c.label) ~= trim(s.label) then diffs.label = trim(c.label) end
  end
  return diffs
end

-- The change markers of one view: which current lines changed a row and
-- which are new, and how many loaded item rows are gone.
--   snapshot: the rows shown at the last load, each with row_id
--   current:  the rows read from the buffer now, each with row_id | nil
-- Returns { marks = { [index in current] = "changed" | "new" }, changed = n,
-- new = n, removed = n }. A line is "new" when it has no row ID and holds
-- text, carries a row ID this view did not load (a pasted row), or repeats
-- a row ID an earlier line already showed (a copy within the view).
-- "removed" counts loaded item rows whose ID no line holds any more, which
-- have no line to mark.
function M.marks(snapshot, current)
  local snap = {}
  for _, s in ipairs(snapshot) do snap[s.row_id] = s end
  local out = { marks = {}, changed = 0, new = 0, removed = 0 }
  local seen = {}
  for i, c in ipairs(current) do
    local s = c.row_id and snap[c.row_id]
    local mark
    if s and not seen[c.row_id] then
      local diffs, problem = M.changed(s, c)
      if problem or next(diffs) then mark = "changed" end
    elseif c.row_id or not (c.kind == "item" and M.blank(c)) then
      mark = "new"
    end
    if c.row_id then seen[c.row_id] = true end
    if mark then
      out.marks[i] = mark
      out[mark] = out[mark] + 1
    end
  end
  for _, s in ipairs(snapshot) do
    if s.kind == "item" and s.slot ~= "self" and not seen[s.row_id] then out.removed = out.removed + 1 end
  end
  return out
end

return M
