-- The area view buffer (RFC 0001 R2): one buffer per location, named by its
-- URI. Its title and state columns are edited in place and saved with :w
-- (nvim/save.lua). Navigation replaces the buffer in the area window;
-- nvim/layout.lua picks the window and records the history (R4.1).
local area_path = require("ado.core.area_path")
local core = require("ado.core.area_view")
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

local function winbar(loc, view)
  local count = ""
  if view then
    count = string.format("  ·  %d sub-areas, %d items%s", #view.areas, #view.items,
      view.truncated and string.format(" (first %d of %s%d)", #view.items,
        view.total >= 1000 and "at least " or "", view.total) or "")
  end
  return area_path.normalise(loc.path) .. "  ·  " .. location.describe(loc) .. count
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

-- opts.quiet leaves the command line alone, for a caller that reports the
-- load itself; opts.on_done(err) runs once the load ends, also when the
-- buffer went away or a newer load replaced it.
function M.load(buf, opts)
  opts = opts or {}
  local echo = opts.quiet and function() end or progress.echo
  local done_cb = opts.on_done or function() end
  local entry = state[buf]
  if not entry then return done_cb(nil) end
  local loc = entry.location
  local label = area_path.name(loc.path)
  entry.loading = true
  view_buffer.set_editable(buf, false)
  view_buffer.set_winbar(buf, winbar(loc) .. "  ·  loading")
  core.load(session.get(), loc, {
    on_progress = function(done, total, what)
      echo(string.format("loading %s: %s (%d/%d)", label, what, done, total))
    end,
  }, function(err, view)
    entry.loading = false
    if not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= entry then return done_cb(nil) end
    view_buffer.set_editable(buf, true)
    if err then
      -- Transport errors are already reported by nvim/session.lua.
      view_buffer.set_winbar(buf, winbar(loc) .. "  ·  load failed, <leader>wr retries")
      return done_cb(err)
    end
    render(buf, view)
    echo(string.format("%s: %d sub-areas, %d items%s", label, #view.areas, #view.items,
      view.truncated and " (truncated)" or ""))
    done_cb(nil)
  end)
end

local function current()
  local buf = vim.api.nvim_get_current_buf()
  return buf, state[buf]
end

local function row_under_cursor()
  local buf, entry = current()
  if not entry or not entry.view then return nil end
  local line = vim.api.nvim_get_current_line()
  local parsed = lines.parse(line)
  return parsed.row_id and registry.get(parsed.row_id) or nil, entry, buf
end

local actions = {}

function actions.select()
  local row, entry = row_under_cursor()
  if not row then return end
  if row.kind == "area" then
    M.open(core.select(entry.view, row.row))
  else
    layout.open_item_from_area(row.row.id)
  end
end

function actions.parent()
  local _, entry = current()
  if not entry then return end
  local parent = area_path.parent(entry.location.path)
  if not parent then return notify("already at the project's root area") end
  M.open(location.at(entry.location, parent))
end

actions.back = layout.back
actions.forward = layout.forward

function actions.toggle_sub()
  local _, entry = current()
  if entry then M.open(location.with_sub(entry.location, not entry.location.sub)) end
end

function actions.reload()
  local buf, entry = current()
  if not entry or entry.loading then return end
  view_buffer.confirm_discard(buf, function() M.load(buf) end)
end

local function split_list(text)
  local out = {}
  for part in (text or ""):gmatch("[^,]+") do
    local v = part:match("^%s*(.-)%s*$")
    if v ~= "" then table.insert(out, v) end
  end
  return out
end

local FILTER_PROMPTS = {
  state = "State (open, all, or names separated by commas): ",
  assignee = "Assignee (empty for anyone, @Me, or a name or email): ",
  types = "Types (empty for every type, or names separated by commas): ",
  tag = "Tag (empty for any, or one whole tag): ",
}

local function current_text(f, key)
  local v = f[key]
  if type(v) == "table" then return table.concat(v, ", ") end
  return v or ""
end

function actions.filters()
  local _, entry = current()
  if not entry then return end
  local loc = entry.location
  local choices = { "state", "assignee", "types", "tag", "reset to defaults" }
  vim.ui.select(choices, { prompt = "Filter" }, function(key)
    if not key then return end
    if key == "reset to defaults" then
      return M.open(location.area(loc.path, require("ado.config").get().area_filters, loc.sub))
    end
    vim.ui.input({ prompt = FILTER_PROMPTS[key], default = current_text(loc.filters, key) }, function(text)
      if text == nil then return end
      local value
      if key == "state" then
        local t = text:match("^%s*(.-)%s*$"):lower()
        if t == "" or t == "open" then
          value = "open"
        elseif t == "all" then
          value = "all"
        else
          value = split_list(text)
        end
      elseif key == "types" then
        value = split_list(text)
        if #value == 0 then value = false end
      else
        value = text:match("^%s*(.-)%s*$")
        if value == "" then value = false end
      end
      M.open(location.with_filters(loc, { [key] = value }))
    end)
  end)
end

function actions.browser()
  local _, entry = current()
  if not entry or not entry.view then return end
  local url, err = core.browser_url(session.get().org, entry.view)
  if not url then return notify(err.message, vim.log.levels.WARN) end
  require("ado.nvim.detail").browser_open(url)
end

M.actions = actions

-- Shows loc in the area window and records it in the history; opts.record
-- = false leaves the history alone.
function M.open(loc, opts)
  return layout.go(loc, opts)
end

-- Shows loc in the current window, loading it the first time its buffer is
-- created. Called by layout.go.
function M.show(loc)
  local buf, created = view_buffer.get_or_create(location.uri(loc), "adoarea")
  if created then
    state[buf] = { location = loc, ids = {} }
    keymaps.area(buf, actions)
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
  return view_buffer.record(buf, "area", entry.location.filters.state, entry.ids,
    { rel = entry.location.path, filters = entry.location.filters })
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
