-- View records for core plan tests, built as the presentation layer builds
-- them (nvim/view_buffer.lua record): snapshot rows with row IDs and lines
-- from a view the core loaded through the fake transport, and current rows
-- parsed back from those lines. Helpers edit the current rows the way a
-- user edits the buffer: delete a line, paste a line yanked from another
-- view, or type a new line. Vim-free, so core specs can load it.
local Fake = require("tests.support.fake_transport")
local area_view = require("ado.core.area_view")
local item_view = require("ado.core.item_view")
local location = require("ado.core.location")
local plan = require("ado.core.plan")
local query_view = require("ado.core.query_view")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")

local M = {}

-- Every type of the seed's catalog, so rows of project P may take any of them.
M.SEED_TYPES = {}
for _, t in ipairs(seed.types) do table.insert(M.SEED_TYPES, t.name) end

-- opts: seed (default tests/fixtures/seed.lua), and session options. With
-- neither projects nor project, the session covers project P with
-- M.SEED_TYPES; projects = false leaves P with no configured types.
function M.new(opts)
  opts = opts or {}
  local fake = Fake.new(opts.seed or seed)
  local sopts = { transport = fake, org = "test-org", project = "P" }
  if opts.projects == nil and opts.project == nil then
    sopts.projects = { { name = "P", types = M.SEED_TYPES } }
  end
  for k, v in pairs(opts) do if k ~= "seed" then sopts[k] = v end end
  return session.new(sopts), fake
end

local next_row_id = 0

local function current_of(r, row_id, line)
  local c = { row_id = row_id, line = line, kind = r.kind }
  if r.kind == "item" then
    if r.slot == "self" then
      c.title = r.title
    else
      c.shown_id = tostring(r.id)
      c.type, c.state, c.title, c.assignee, c.tags = r.type, r.state, r.title, r.assignee, r.tags
    end
  elseif r.kind == "area" then
    c.name = r.name
  elseif r.kind == "heading" then
    c.label = r.label
  else
    c.field, c.value = r.field, r.value
  end
  return c
end

local function renumber(view)
  for i, c in ipairs(view.current) do c.line = i end
end

function M.record(key, kind, state_filter, rows, extra)
  local snapshot, current = {}, {}
  for i, r in ipairs(rows) do
    next_row_id = next_row_id + 1
    local s = {}
    for k, v in pairs(r) do s[k] = v end
    s.row_id, s.line = next_row_id, i
    snapshot[i] = s
    current[i] = current_of(r, s.row_id, i)
  end
  local view = { key = key, kind = kind, state_filter = state_filter, snapshot = snapshot, current = current }
  for k, v in pairs(extra or {}) do view[k] = v end
  return view
end

function M.area(s, path, filters)
  local loc = location.area(path, filters)
  local view
  area_view.load(s, loc, {}, function(err, v) assert(not err, err and err.message) view = v end)
  return M.record("ado://area/" .. path:gsub("\\", "/"), "area", loc.filters.state, view.rows,
    { rel = loc.path, filters = loc.filters })
end

-- A query list, "mine" unless name is given.
function M.query(s, filters, name)
  local loc = location.query(name or "mine", filters)
  local view
  query_view.load(s, loc, {}, function(err, v) assert(not err, err and err.message) view = v end)
  return M.record(location.uri(loc), "query", loc.filters.state, view.rows, { filters = loc.filters })
end

-- opts.all: every state; opts.expand: child IDs to expand, in order.
function M.item(s, id, opts)
  opts = opts or {}
  local view
  item_view.load(s, location.item(id, opts.all), {}, function(err, v) assert(not err, err and err.message) view = v end)
  local display = item_view.display(view)
  for _, child in ipairs(opts.expand or {}) do
    for _, r in ipairs(item_view.rows(display)) do
      if r.kind == "item" and r.slot == "child" and r.id == child then
        item_view.expand(s, display, r, function(err) assert(not err, err and err.message) end)
        break
      end
    end
  end
  return M.record("ado://item/" .. id, "item", opts.all and "all" or "open", item_view.rows(display),
    item_view.plan_fields(view))
end

function M.line_of(view, pred)
  for i, c in ipairs(view.current) do
    local s
    for _, x in ipairs(view.snapshot) do if x.row_id == c.row_id then s = x end end
    if s and pred(s, c, i) then return c, i end
  end
  error("no such row")
end

function M.item_line(view, id, slot)
  return M.line_of(view, function(s) return s.kind == "item" and s.id == id and (not slot or s.slot == slot) end)
end

function M.field_line(view, name)
  return M.line_of(view, function(s) return s.kind == "field" and s.field == name end)
end

-- The current row of a heading: "children", or a link section's rel.
function M.heading(view, which)
  return M.line_of(view, function(s)
    return s.kind == "heading" and (s.slot == which or s.rel == which)
  end)
end

function M.area_row(view)
  return M.line_of(view, function(s) return s.kind == "area" end)
end

-- Deletes the current rows of item `id` (every slot, or `slot`); returns
-- copies of them as a yank would hold them, with their origin.
function M.cut(view, id, slot)
  local out = M.yank(view, id, slot)
  local kept = {}
  for _, c in ipairs(view.current) do
    local keep = true
    for _, y in ipairs(out) do if y.row_id == c.row_id then keep = false end end
    if keep then table.insert(kept, c) end
  end
  view.current = kept
  renumber(view)
  return out
end

function M.yank(view, id, slot)
  local out = {}
  for _, c in ipairs(view.current) do
    for _, s in ipairs(view.snapshot) do
      if s.row_id == c.row_id and s.kind == "item" and s.id == id and (not slot or s.slot == slot) then
        local y = {}
        for k, v in pairs(c) do y[k] = v end
        y.origin = { key = view.key, row = s }
        table.insert(out, y)
      end
    end
  end
  assert(#out > 0, "no row for #" .. tostring(id))
  return out
end

-- Deletes the current row `c` and every current row listed after it in rows.
function M.delete(view, ...)
  local drop = {}
  for _, c in ipairs({ ... }) do drop[c] = true end
  local kept = {}
  for _, c in ipairs(view.current) do if not drop[c] then table.insert(kept, c) end end
  view.current = kept
  renumber(view)
end

-- Pastes yanked rows into view after current row `after` (nil: at the end).
-- A row pasted back into the view it came from keeps its own row ID and
-- needs no origin, as the presentation layer records it.
function M.paste(view, rows, after)
  local at = #view.current
  for i, c in ipairs(view.current) do if c == after then at = i end end
  for j, y in ipairs(rows) do
    local c = {}
    for k, v in pairs(y) do c[k] = v end
    if c.origin and c.origin.key == view.key then c.origin = nil end
    table.insert(view.current, at + j, c)
  end
  renumber(view)
  return view.current[at + 1]
end

-- Types a new line after current row `after`; fields as lines.parse reads
-- them (a line without separators is all title).
function M.new_line(view, after, fields)
  local c = { kind = "item", shown_id = "" }
  for k, v in pairs(fields) do c[k] = v end
  return M.paste(view, { c }, after)
end

function M.compute(s, views)
  local prepared
  plan.prepare(views, s, function(err, p) assert(not err, err and err.message) prepared = p end)
  return plan.compute(views, prepared)
end

function M.messages(list)
  local out = {}
  for _, x in ipairs(list) do table.insert(out, x.message) end
  return out
end

function M.texts(lines)
  local out = {}
  for _, l in ipairs(lines) do table.insert(out, l.text) end
  return out
end

-- The ops of a plan as { kind, id, ... } lists, for short assertions.
function M.kinds(p)
  local out = {}
  for _, op in ipairs(p.ops) do table.insert(out, op.kind) end
  return out
end

return M
