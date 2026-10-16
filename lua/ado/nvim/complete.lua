-- The Insert-mode menu of the views (plan 0002 UX3.1, UX3.3 to UX3.5): in
-- a type or state cell, <C-Space> or <C-x><C-u> lists the values the save
-- accepts there (core/choices.lua), and the one picked replaces the cell's
-- text; in an assignee cell they open the people menu (nvim/people.lua).
-- Also finds the cell a value is for, which nvim/pick.lua shares.
local cells = require("ado.nvim.cells")
local choices = require("ado.core.choices")
local highlights = require("ado.nvim.highlights")
local lines = require("ado.nvim.lines")
local registry = require("ado.nvim.registry")
local session = require("ado.nvim.session")
local table_layout = require("ado.core.table_layout")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

local COLUMNS = table_layout.LAYOUTS.full.columns

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function row_id(line)
  return tonumber((line or ""):match("^/(%d+) "))
end

-- The viewed item's field lines around line `at`: { [field] = { value,
-- loaded } }, the text now and the value the view loaded.
local function field_block(buf, at)
  local all = require("ado.nvim.region").lines(buf)
  local out = {}
  for _, step in ipairs({ -1, 1 }) do
    local i = at
    while all[i] do
      local p = lines.parse(all[i])
      if p.kind ~= "field" then break end
      local reg = p.row_id and registry.get(p.row_id)
      local value = p.row_id and require("ado.nvim.fit").lookup(p.row_id, p.field, p.value) or p.value
      out[p.field] = out[p.field] or { value = value or p.value, loaded = reg and reg.row.value }
      i = i + step
    end
  end
  return out
end

-- The cell of line `at` (1-based) holding byte `col`, or cell `index` of
-- that line's item row, and what the choices need to know about it:
-- { line, index, cell (nvim/cells.lua), column, choice (a core/choices.lua
-- cell) }. nil on a line without cells.
function M.target(buf, at, col, index)
  if not require("ado.nvim.region").readable(buf, at) then return nil end
  local line = vim.api.nvim_buf_get_lines(buf, at - 1, at, false)[1]
  if not line then return nil end
  local c = index and cells.nth(line, index) or (not index and cells.at(line, col))
  if not c then return nil end
  local project = view_buffer.project(buf)
  if c.field then
    local fields = field_block(buf, at)
    local column = lines.parse(line).field
    local typed, state = fields.type or {}, fields.state or {}
    return { line = at, cell = c, column = column, choice = { column = column, type = typed.value,
      state = state.value, snapshot_type = typed.loaded, project = project } }
  end
  if c.count == 1 then return { line = at, cell = c, column = "title" } end
  local column = COLUMNS[c.index]
  local id = row_id(line)
  local reg = id and registry.get(id)
  local row = reg and reg.row.kind == "item" and reg.row or nil
  local values = require("ado.nvim.fit").read(line).values
  return { line = at, index = c.index, cell = c, column = column, choice = { column = column,
    type = values.type, state = values.state, snapshot_type = row and row.type,
    project = row and row.project ~= "" and row.project or project, new = row == nil } }
end

local function lookup()
  local s = session.get()
  local configured = {}
  for _, p in ipairs(s:project_list()) do configured[p.name] = p.types end
  return {
    catalog = function(project) return s:cached_catalog(project) end,
    types = function(project) return configured[project] end,
  }
end

-- The values every target may take: cb(items) or cb(nil, reason), where a
-- reason without a message needs no report (a failed load, which the
-- session has reported). A catalog not loaded yet is loaded first (UX3.4).
function M.values(targets, cb)
  local tried = {}
  local function attempt()
    local list = {}
    for i, t in ipairs(targets) do list[i] = t.choice end
    local items, reason = choices.for_cells(list, lookup())
    if reason and reason.kind == "no_catalog" and not tried[reason.project or ""] then
      tried[reason.project or ""] = true
      return session.get():catalog(reason.project, function(err)
        if err then return cb(nil, { kind = "failed", message = err.kind == "invalid" and err.message or nil }) end
        attempt()
      end)
    end
    if reason and reason.kind == "no_catalog" then
      reason.message = string.format("the work item types of project %s could not be loaded", tostring(reason.project))
    end
    cb(items, reason)
  end
  attempt()
end

-- The byte the menu's text starts at, the text each value needs before it
-- (the gap after an empty field's label), and the 0-based cursor column
-- after the cell's text.
function M.span(line, c)
  if c.last >= c.first then return c.first, "", c.last end
  if c.field then return c.from, lines.field_gap(line), #line end
  local start = c.index == 1 and c.from or math.min(c.from + 1, c.to + 1)
  return start, "", start - 1
end

local function menu_items(items, prefix)
  local colours = vim.fn.has("nvim-0.11") == 1
  local out = {}
  for _, it in ipairs(items) do
    local entry = { word = prefix .. it.word, abbr = it.word, menu = it.menu ~= "" and it.menu or nil, icase = 1 }
    if colours then entry.abbr_hlgroup = highlights.color(it.color, nil) end
    table.insert(out, entry)
  end
  return out
end

-- Whether the cursor of the current window is still in the cell t was
-- found in, in Insert mode in buf, for a menu whose values arrived late.
local function still_in(buf, t, id)
  if vim.api.nvim_get_current_buf() ~= buf or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then return nil end
  local at, col = unpack(vim.api.nvim_win_get_cursor(0))
  if at ~= t.line or row_id(vim.api.nvim_get_current_line()) ~= id then return nil end
  local now = M.target(buf, at, col + 1)
  return now and now.column == t.column and now or nil
end

-- Opens the menu for target t with items, from the cell's start, the
-- cursor moved after the cell's text so the value picked replaces it.
local function open(t, items)
  local line = vim.api.nvim_get_current_line()
  local start, prefix, col = M.span(line, t.cell)
  vim.api.nvim_win_set_cursor(0, { t.line, col })
  local base = line:sub(start, col)
  vim.fn.complete(start, menu_items(choices.filter(items, base), prefix))
end

local function report(reason)
  if reason and reason.message then notify(reason.message, vim.log.levels.WARN) end
end

-- The menu for the cell under the cursor, from Insert mode. Called from a
-- plain mapping: from an <expr> mapping complete() fails (spike 0002).
function M.menu()
  local buf = vim.api.nvim_get_current_buf()
  local at, col = unpack(vim.api.nvim_win_get_cursor(0))
  local t = M.target(buf, at, col + 1)
  if t and t.column == "assignee" then return require("ado.nvim.people").open(buf, t) end
  if not t or not choices.COLUMNS[t.column] then
    return notify("<C-Space> lists the values of a type, state or assignee cell")
  end
  local id = row_id(vim.api.nvim_get_current_line())
  M.values({ t }, function(items, reason)
    if not items then return report(reason) end
    local now = still_in(buf, t, id)
    if now then open(now, items) end
  end)
end

-- What the last findstart call found: { items, prefix }.
local pending

-- 'completefunc' of the views, for <C-x><C-u>. It cannot wait, so a cell
-- whose catalog is not loaded yet cancels this call and opens the menu
-- when the catalog arrives.
function M.completefunc(findstart, base)
  if findstart ~= 1 then
    if not pending then return {} end
    return menu_items(choices.filter(pending.items, base), pending.prefix)
  end
  pending = nil
  local buf = vim.api.nvim_get_current_buf()
  local at, col = unpack(vim.api.nvim_win_get_cursor(0))
  local t = M.target(buf, at, col + 1)
  if t and t.column == "assignee" then
    -- The people menu refreshes itself with complete(), which a
    -- 'completefunc' cannot do, so it opens once this call has returned.
    vim.schedule(function()
      local now = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
        and M.target(buf, at, vim.api.nvim_win_get_cursor(0)[2] + 1)
      if now and now.line == at and now.column == "assignee" then require("ado.nvim.people").open(buf, now) end
    end)
    return -3
  end
  if not t or not choices.COLUMNS[t.column] then return -3 end
  local id = row_id(vim.api.nvim_get_current_line())
  local waiting, found = true, nil
  M.values({ t }, function(items, reason)
    if not items then return report(reason) end
    if waiting then
      found = items
      return
    end
    local now = still_in(buf, t, id)
    if now then open(now, items) end
  end)
  waiting = false
  if not found then return -3 end
  local start, prefix = M.span(vim.api.nvim_get_current_line(), t.cell)
  pending = { items = found, prefix = prefix }
  return math.min(start, col + 1) - 1
end

local cmp_off = {}

-- nvim-cmp installs its Insert-mode keys on InsertEnter, only in a buffer
-- where it is enabled; turned off here, its <C-Space> leaves the views'
-- own mapping alone. A config that loads nvim-cmp on InsertEnter has not
-- loaded it when the view opens, so this runs again on InsertEnter.
local function disable_cmp(buf)
  if cmp_off[buf] or not package.loaded.cmp then return end
  cmp_off[buf] = true
  vim.api.nvim_buf_call(buf, function()
    pcall(function() require("cmp").setup.buffer({ enabled = false }) end)
  end)
end

-- The menus need 'completeopt' to show a single item and to insert
-- nothing until one is picked: Neovim's default inserts the first item,
-- which would replace a name being typed with an email. Where Neovim
-- has no buffer-local 'completeopt', the global value is left alone.
local function completeopt(buf)
  local info = vim.api.nvim_get_option_info2("completeopt", {})
  if not (info.scope == "buf" or info.global_local) then return end
  local opts = vim.split(vim.go.completeopt, ",", { trimempty = true })
  local has = {}
  for _, o in ipairs(opts) do has[o] = true end
  if not has.menu then table.insert(opts, "menu") end
  if not has.menuone then table.insert(opts, "menuone") end
  if not has.noselect and not has.noinsert then table.insert(opts, "noselect") end
  vim.bo[buf].completeopt = table.concat(opts, ",")
end

-- Makes the plugin's menu the only one in buf (UX3.5): nvim-cmp off,
-- blink.cmp asked to stay off through vim.b.completion, and the
-- 'completefunc' for <C-x><C-u>.
function M.attach(buf)
  vim.b[buf].completion = false
  vim.bo[buf].completefunc = "v:lua.require'ado.nvim.complete'.completefunc"
  completeopt(buf)
  require("ado.nvim.people").attach(buf)
  disable_cmp(buf)
  vim.api.nvim_create_autocmd("InsertEnter", { buffer = buf, callback = function() disable_cmp(buf) end })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function() cmp_off[buf] = nil end })
end

return M
