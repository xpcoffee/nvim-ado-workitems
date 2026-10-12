-- The item view buffer (RFC 0001 R3): one buffer per work item, named
-- ado://item/<id>, read-only in this phase. It shows in the item panel that
-- nvim/layout.lua keeps between the area view and the detail split.
local config = require("ado.config")
local core = require("ado.core.item_view")
local keymaps = require("ado.nvim.keymaps")
local layout = require("ado.nvim.layout")
local lines = require("ado.nvim.lines")
local location = require("ado.core.location")
local progress = require("ado.nvim.progress")
local registry = require("ado.nvim.registry")
local session = require("ado.nvim.session")
local urls = require("ado.core.urls")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

-- buf -> { location, view, display (nil until loaded), ids = { row id per
-- line }, widths (column widths), expanding = { [id] = true } }
local state = {}

local LABELS = { self = "this item", parent = "parent" }

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local function winbar(entry, suffix)
  local loc = entry.location
  local text = "#" .. loc.id
  if entry.view then text = text .. " " .. entry.view.item.type end
  text = text .. "  ·  " .. (loc.all and "children and links: all states"
    or "children and links: open only (<leader>wt for all)")
  if entry.view and entry.view.truncated then text = text .. "  ·  links truncated" end
  return text .. (suffix or "")
end

local function add_ids(name, rows)
  local ids = {}
  for i, row in ipairs(rows) do ids[i] = registry.add({ kind = row.kind, view = name, row = row }) end
  return ids
end

local function render(buf)
  local entry = state[buf]
  registry.release(entry.ids)
  local rows = core.rows(entry.display)
  local ids = add_ids(vim.api.nvim_buf_get_name(buf), rows)
  local text, prefixes, widths = lines.render(rows, ids)
  entry.ids, entry.widths = ids, widths
  view_buffer.set_lines(buf, text, prefixes)
  local labels = {}
  for i, row in ipairs(rows) do
    if row.kind == "item" and LABELS[row.slot] then labels[i - 1] = LABELS[row.slot] end
  end
  view_buffer.set_labels(buf, labels)
  view_buffer.set_winbar(buf, winbar(entry))
end

function M.load(buf)
  local entry = state[buf]
  if not entry then return end
  local id = entry.location.id
  entry.loading = true
  view_buffer.set_winbar(buf, winbar(entry, "  ·  loading"))
  core.load(session.get(), entry.location, {
    link_types = config.get().link_types,
    on_progress = function(done, total, what)
      progress.echo(string.format("loading #%d: %s (%d/%d)", id, what, done, total))
    end,
  }, function(err, view)
    entry.loading = false
    if not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= entry then return end
    if err then
      -- Transport errors are already reported by nvim/session.lua.
      view_buffer.set_winbar(buf, winbar(entry, "  ·  load failed, <leader>wr retries"))
      return
    end
    entry.view = view
    entry.display = core.display(view, entry.location)
    entry.expanding = {}
    render(buf)
    local linked = 0
    for _, s in ipairs(view.sections) do linked = linked + #s.items end
    progress.echo(string.format("#%d: %d children, %d linked", id, #view.children.items, linked))
  end)
end

local function current()
  local buf = vim.api.nvim_get_current_buf()
  return buf, state[buf]
end

-- The registry entry of the row under the cursor, its line (1-based), the
-- buffer and its state.
local function row_under_cursor()
  local buf, entry = current()
  if not entry or not entry.display then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local id = entry.ids[line]
  return id and registry.get(id) or nil, line, buf, entry
end

local function line_of(entry, row_id)
  for i, id in ipairs(entry.ids) do
    if id == row_id then return i end
  end
end

-- The rows shown beneath an expanded row: the lines after it that are
-- deeper child rows.
local function block_end(entry, line, depth)
  local last = line
  for i = line + 1, #entry.ids do
    local r = registry.get(entry.ids[i])
    if not (r and r.row.slot == "child" and r.row.depth > depth) then break end
    last = i
  end
  return last
end

local actions = {}

function actions.select()
  local reg, _, _, entry = row_under_cursor()
  if not reg then return end
  local row = reg.row
  if row.kind == "item" and row.slot == "self" then return layout.show_detail(row.id) end
  local loc = core.select(entry.display, row, config.get().area_filters)
  if not loc then return end
  if loc.kind == "item" then layout.sync_detail(loc.id) end
  layout.go(loc)
end

actions.back = layout.back
actions.forward = layout.forward

local function item_id()
  local reg = row_under_cursor()
  return reg and reg.row.kind == "item" and reg.row.id or nil
end

function actions.preview()
  local id = item_id()
  if id then layout.show_detail(id, { focus = false }) end
end

function actions.detail()
  local id = item_id()
  if id then layout.show_detail(id) end
end

-- <Tab> on a child row: collapse it when expanded, else fetch and insert
-- its children (R3.4). Lines are inserted and deleted rather than redrawn,
-- so later phases can keep unsaved edits through an expansion.
function actions.expand()
  local reg, line, buf, entry = row_under_cursor()
  if not reg then return end
  local row = reg.row
  if not core.expandable(row) then return notify("only child rows expand") end
  local display = entry.display
  if display.expanded[row.id] then
    local last = block_end(entry, line, row.depth)
    view_buffer.delete_lines(buf, line, last)
    local removed = {}
    for i = last, line + 1, -1 do table.insert(removed, table.remove(entry.ids, i)) end
    registry.release(removed)
    core.collapse(display, row.id)
    return
  end
  if entry.expanding[row.id] then return end
  entry.expanding[row.id] = true
  local row_id = entry.ids[line]
  progress.echo(string.format("expanding #%d", row.id))
  core.expand(session.get(), display, row, function(err, rows, info)
    entry.expanding[row.id] = nil
    if err or not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= entry or entry.display ~= display then return end
    local at = line_of(entry, row_id)
    if not at then return end
    local ids = add_ids(vim.api.nvim_buf_get_name(buf), rows)
    local text, prefixes, widths = lines.render(rows, ids, entry.widths)
    entry.widths = widths
    view_buffer.insert_lines(buf, at, text, prefixes)
    for i, id in ipairs(ids) do table.insert(entry.ids, at + i, id) end
    if #rows == 0 then
      progress.echo(info.total == 0 and string.format("#%d has no children", row.id)
        or string.format("#%d has no open children; <leader>wt shows all", row.id))
    else
      progress.echo(string.format("#%d: %d children", row.id, #rows))
    end
  end)
end

-- Shows children and links in every state, or open only again (R3.8). The
-- rows are already loaded, so this makes no call and keeps expansions.
function actions.toggle_all()
  local _, entry = current()
  if not entry or not entry.display then return end
  layout.go(location.with_all(entry.location, not entry.location.all), { keep_expansion = true })
end

function actions.browser()
  local _, entry = current()
  if not entry then return end
  local id = item_id() or entry.location.id
  require("ado.nvim.detail").browser_open(urls.item(session.get().org, id))
end

function actions.reload()
  local buf, entry = current()
  if entry and not entry.loading then M.load(buf) end
end

M.actions = actions

-- Opens loc in the item panel and records it in the history.
function M.open(loc, opts)
  return layout.go(loc, opts)
end

-- Shows loc in the current window. The first showing of an item loads it;
-- later ones show the loaded rows again, collapsed (going back shows a
-- location collapsed), except opts.keep_expansion for the all-states
-- toggle. Called by layout.go.
function M.show(loc, opts)
  opts = opts or {}
  local buf, created = view_buffer.get_or_create(location.buffer_name(loc), "adoitemview")
  if created then
    state[buf] = { location = loc, ids = {}, expanding = {} }
    keymaps.item(buf, actions)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        if state[buf] then registry.release(state[buf].ids) end
        state[buf] = nil
      end,
    })
    view_buffer.set_lines(buf, { "" }, {})
  end
  view_buffer.show(vim.api.nvim_get_current_win(), buf)
  local entry = state[buf]
  entry.location = loc
  if entry.view then
    if opts.keep_expansion and entry.display then
      entry.display.location = loc
    else
      entry.display = core.display(entry.view, loc)
    end
    render(buf)
  elseif not entry.loading then
    M.load(buf)
  end
  return buf
end

function M.state(buf)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return state[buf]
end

return M
