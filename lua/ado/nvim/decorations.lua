-- The views' extmarks that follow the data (plan 0002 UX2.2, UX2.4): the
-- type cell in its ADO colour, a dot in the state's colour before the state
-- cell, and a sign on each changed or new line. They are placed again
-- after every change, from the text then in the buffer, so a type or state
-- typed over takes its new colour.
local config = require("ado.config")
local fit = require("ado.nvim.fit")
local highlights = require("ado.nvim.highlights")
local lines = require("ado.nvim.lines")
local region = require("ado.nvim.region")
local registry = require("ado.nvim.registry")
local row_changes = require("ado.core.row_changes")
local table_layout = require("ado.core.table_layout")
local ux_stats = require("ado.nvim.ux_stats")

local M = {}

local NS = vim.api.nvim_create_namespace("ado_decorations")

local DEFAULT_ICONS = { state = "●", changed = "~", new = "+" }
local COLUMNS = table_layout.LAYOUTS.full.columns
local warned_icons = false

-- The configured icons; one that is not one column wide keeps its default,
-- because the dot and the signs must not shift the columns.
function M.icons()
  local configured = ((config.get().ui or {}).icons) or {}
  local out, bad = {}, {}
  for name, default in pairs(DEFAULT_ICONS) do
    local icon = configured[name]
    if icon ~= nil and (type(icon) ~= "string" or vim.fn.strdisplaywidth(icon) ~= 1) then
      table.insert(bad, name)
      icon = nil
    end
    out[name] = icon or default
  end
  if #bad > 0 and not warned_icons then
    warned_icons = true
    table.sort(bad)
    vim.notify("[ado] ui.icons " .. table.concat(bad, ", ") .. " must be one column wide; using the default",
      vim.log.levels.WARN)
  end
  return out
end

-- The row a line shows now, as view_buffer.record reads it (cut cells
-- with their full values), and where its cells are: { row, ranges, offset }
-- for a table row, { row, field } for a field line, or { row } for any
-- other line.
local function read(line)
  local id = tonumber(line:match("^/(%d+) "))
  local reg = id and registry.get(id)
  local r = fit.read(line)
  if r and r.kind == "self" then
    return { row = { row_id = id, kind = "item", title = r.values.title }, reg = reg }
  end
  if r and r.kind == "table" then
    local p = { row_id = id, kind = "item" }
    for _, c in ipairs(COLUMNS) do p[c] = r.values[c] end
    return { row = p, reg = reg, ranges = r.ranges, offset = r.offset }
  end
  local p = lines.parse(line)
  local out = { row = p, reg = reg }
  if p.kind == "field" then
    out.field = lines.field_range(line)
    if r then p.value = r.values[r.field] end
  end
  return out
end

-- Places the type colour and the state dot on one line. at: 0-based line;
-- type_range: { first, last } 1-based bytes of the type name; state_col:
-- the 0-based byte the dot goes before.
local function paint(buf, at, line, catalog, wtype, state, type_range, state_col, icons)
  if type_range and type_range.last >= type_range.first then
    local group = highlights.color(catalog and catalog:type_color(wtype), "AdoType")
    vim.api.nvim_buf_set_extmark(buf, NS, at, type_range.first - 1, { end_col = type_range.last,
      hl_group = group, end_right_gravity = true })
  end
  if state_col then
    local group = highlights.color(catalog and state ~= "" and catalog:state_color(wtype, state) or nil, "AdoState")
    -- right_gravity = false keeps the dot before text typed at the start
    -- of the state cell.
    vim.api.nvim_buf_set_extmark(buf, NS, at, math.min(state_col, #line), {
      virt_text = { { icons.state .. " ", group } }, virt_text_pos = "inline", right_gravity = false })
  end
end

-- Decorates every line of buf and returns the counts for the window bar:
-- { changed, new, removed }.
-- ctx: { ids = row ID of each loaded line, project = the project of a row
-- with none (a typed line, or the viewed item's field lines),
-- catalog = function(project) -> the project's type catalog or nil }.
function M.refresh(buf, ctx)
  local started = vim.uv.hrtime()
  local icons = M.icons()
  local text = region.lines(buf)
  local snapshot = {}
  for i, rid in ipairs(ctx.ids or {}) do
    local reg = registry.get(rid)
    if reg then
      local s = setmetatable({ row_id = rid }, { __index = reg.row })
      snapshot[i] = s
    end
  end
  local read_lines, current = {}, {}
  for i, line in ipairs(text) do
    local r = read(line)
    read_lines[i] = r
    current[i] = r.row
  end
  local m = row_changes.marks(snapshot, current)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local catalogs = {}
  local function catalog_of(project)
    if not project or project == "" then return nil end
    if catalogs[project] == nil then catalogs[project] = ctx.catalog(project) or false end
    return catalogs[project] or nil
  end
  local view_project = ctx.project
  for i, r in ipairs(read_lines) do
    local at = i - 1
    local mark = m.marks[i]
    if mark then
      vim.api.nvim_buf_set_extmark(buf, NS, at, 0, { sign_text = icons[mark],
        sign_hl_group = mark == "changed" and "AdoChanged" or "AdoNew" })
    end
    local project = r.reg and r.reg.row.project or view_project
    if r.ranges then
      local p = r.row
      local tr, sr = r.ranges[1], r.ranges[2]
      local type_range = { first = r.offset + tr.first, last = r.offset + tr.last }
      -- The indent of a child row is part of the first cell; colour only
      -- the type name.
      local indent = #(text[i]:sub(type_range.first, type_range.last):match("^%s*"))
      type_range.first = type_range.first + indent
      local state_col = r.offset + (sr.last >= sr.first and sr.first or math.min(sr.from + 1, sr.to + 1)) - 1
      paint(buf, at, text[i], catalog_of(project), p.type, p.state, type_range, state_col, icons)
    elseif r.field and (r.row.field == "state" or r.row.field == "type") then
      local typed = ""
      for j = i - 1, 1, -1 do
        local f = read_lines[j]
        if f.row.kind == "field" and f.row.field == "type" then typed = f.row.value or "" end
        if f.row.kind ~= "field" then break end
      end
      local catalog = catalog_of(project)
      if r.row.field == "type" then
        paint(buf, at, text[i], catalog, r.row.value, nil, r.field, nil, icons)
      else
        local col = (r.field.last >= r.field.first and r.field.first or r.field.lead + 1) - 1
        paint(buf, at, text[i], catalog, typed, r.row.value or "", nil, col, icons)
      end
    end
  end
  ux_stats.record("decorate", (vim.uv.hrtime() - started) / 1e6, { rows = #text })
  return { changed = m.changed, new = m.new, removed = m.removed }
end

return M
