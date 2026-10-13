-- The query list buffer (RFC 0001 R9): one buffer per query location,
-- named by its URI, shown in the top window of the column where the area
-- view also goes (nvim/layout.lua). Its rows are edited in place and saved
-- with :w (nvim/save.lua).
local core = require("ado.core.query_view")
local filters = require("ado.nvim.filters")
local keymaps = require("ado.nvim.keymaps")
local layout = require("ado.nvim.layout")
local lines = require("ado.nvim.lines")
local location = require("ado.core.location")
local progress = require("ado.nvim.progress")
local registry = require("ado.nvim.registry")
local session = require("ado.nvim.session")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

-- buf -> { location, view (core view, nil until loaded), ids = { row id per
-- line }, loading = bool }
local state = {}

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local function title(loc)
  return location.QUERIES[loc.name].title
end

local function winbar(loc, view)
  local count = ""
  if view then
    count = string.format("  ·  %d items%s", #view.items,
      view.truncated and string.format(" (first %d of %s%d)", #view.items,
        view.total >= 1000 and "at least " or "", view.total) or "")
  end
  return title(loc) .. "  ·  " .. location.describe(loc) .. count
end

local function render(buf, view)
  local entry = state[buf]
  registry.release(entry.ids)
  local name = vim.api.nvim_buf_get_name(buf)
  local ids = {}
  for i, row in ipairs(view.rows) do
    ids[i] = registry.add({ kind = row.kind, view = name, row = row })
  end
  local text = lines.render(view.rows, ids)
  if #text == 0 then text = { "" } end
  entry.view, entry.ids = view, ids
  view_buffer.set_lines(buf, text)
  view_buffer.set_winbar(buf, winbar(entry.location, view))
end

-- opts as for nvim/area_view.lua load: quiet, on_done(err).
function M.load(buf, opts)
  opts = opts or {}
  local echo = opts.quiet and function() end or progress.echo
  local done_cb = opts.on_done or function() end
  local entry = state[buf]
  if not entry then return done_cb(nil) end
  local loc = entry.location
  local label = title(loc)
  entry.loading = true
  view_buffer.set_editable(buf, false)
  view_buffer.set_winbar(buf, winbar(loc) .. "  ·  loading")
  echo("loading " .. label)
  core.load(session.get(), loc, {}, function(err, view)
    entry.loading = false
    if not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= entry then return done_cb(nil) end
    view_buffer.set_editable(buf, true)
    if err then
      -- Transport errors are already reported by nvim/session.lua; the
      -- core's own (no project) is not.
      if err.kind == "invalid" then notify(err.message, vim.log.levels.WARN) end
      view_buffer.set_winbar(buf, winbar(loc) .. "  ·  load failed, <leader>wr retries")
      return done_cb(err)
    end
    render(buf, view)
    echo(string.format("%s: %d items%s", label, #view.items, view.truncated and " (truncated)" or ""))
    done_cb(nil)
  end)
end

local function current()
  local buf = vim.api.nvim_get_current_buf()
  return buf, state[buf]
end

local actions = {}

function actions.select()
  local _, entry = current()
  if not entry or not entry.view then return end
  local parsed = lines.parse(vim.api.nvim_get_current_line())
  local row = parsed.row_id and registry.get(parsed.row_id)
  if row and row.kind == "item" then layout.open_item_from_list(row.row.id) end
end

actions.back = layout.back
actions.forward = layout.forward

function actions.reload()
  local buf, entry = current()
  if not entry or entry.loading then return end
  view_buffer.confirm_discard(buf, function() M.load(buf) end)
end

function actions.filters()
  local _, entry = current()
  if not entry then return end
  local loc = entry.location
  filters.choose(loc, { "state", "types", "tag" }, function() return location.query(loc.name) end, M.open)
end

function actions.browser()
  local _, entry = current()
  if not entry or not entry.view then return end
  local url, err = core.browser_url(session.get().org, entry.view)
  if not url then return notify(err.message, vim.log.levels.WARN) end
  require("ado.nvim.detail").browser_open(url)
end

M.actions = actions

-- Shows loc in the top window and records it in the history; opts.record
-- = false leaves the history alone.
function M.open(loc, opts)
  return layout.go(loc, opts)
end

-- Shows loc in the current window, loading it the first time its buffer is
-- created. Called by layout.go.
function M.show(loc)
  local buf, created = view_buffer.get_or_create(location.uri(loc), "adoquery")
  if created then
    state[buf] = { location = loc, ids = {} }
    keymaps.query(buf, actions)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        if state[buf] then registry.release(state[buf].ids) end
        state[buf] = nil
      end,
    })
    view_buffer.set_lines(buf, { "" })
  end
  view_buffer.show(vim.api.nvim_get_current_win(), buf)
  if created then M.load(buf) end
  return buf
end

-- The view record for the change plan, or nil until the view has loaded.
function M.record(buf)
  local entry = state[buf]
  if not entry or not entry.view then return nil end
  return view_buffer.record(buf, "query", entry.location.filters.state, entry.ids,
    { filters = entry.location.filters })
end

function M.busy(buf)
  local entry = state[buf]
  return entry ~= nil and entry.loading == true
end

function M.state(buf)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return state[buf]
end

return M
