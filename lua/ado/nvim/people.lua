-- The people menu of an assignee cell (plan 0002 UX6.1 to UX6.3, UX6.7).
-- <C-Space> opens it at once with the people core/people.lua knows; each
-- key typed narrows it, and once the cell holds 2 characters and no key
-- has come for DEBOUNCE_MS, ADO is searched and the answer merged in with
-- complete(). An item shows a display name and inserts the email, which
-- the save resolves to exactly one identity.
local complete = require("ado.nvim.complete")
local people = require("ado.core.people")
local progress = require("ado.nvim.progress")
local registry = require("ado.nvim.registry")
local session = require("ado.nvim.session")
local ux_stats = require("ado.nvim.ux_stats")

local M = {}

M.DEBOUNCE_MS = 200
M.MIN_CHARS = 2

-- The menu open now: { buf, line, id, start, prefix, gen, exact }. Typing
-- refreshes it until a person is picked, <C-e> or Insert mode ends.
local active
-- A failed search has been reported in this Insert session.
local reported = false

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function row_id(line)
  return tonumber((line or ""):match("^/(%d+) "))
end

-- The people assigned to the rows of every open view.
function M.locals()
  local out, seen = {}, {}
  registry.each(function(entry)
    local row = entry.row
    local email = row.kind == "item" and row.assignee_unique or ""
    if email ~= "" and not seen[email:lower()] then
      seen[email:lower()] = true
      table.insert(out, { display_name = row.assignee or "", unique_name = email })
    end
  end)
  return out
end

-- "Name <email>", or the email of a person without a display name.
function M.label(p)
  if (p.display_name or "") == "" then return p.unique_name end
  return string.format("%s <%s>", p.display_name, p.unique_name)
end

local function items(state, list)
  local out = {}
  for _, p in ipairs(list) do
    table.insert(out, {
      word = state.prefix .. p.unique_name,
      abbr = p.display_name ~= "" and p.display_name or p.unique_name,
      menu = p.unique_name,
      -- Keeps an item whose email does not start with the name typed,
      -- which Neovim would drop as the text grows (:help complete-items).
      equal = 1,
      icase = 1,
      user_data = { ado_person = { display_name = p.display_name, unique_name = p.unique_name, mail = p.mail,
        id = p.id } },
    })
  end
  return out
end

-- The text typed in the cell, from its start to the cursor.
local function typed(state)
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return trim(vim.api.nvim_get_current_line():sub(state.start, col))
end

-- Whether the cursor is still in the assignee cell the menu opened in, in
-- Insert mode.
local function here(state)
  if vim.api.nvim_get_current_buf() ~= state.buf or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    return false
  end
  local at, col = unpack(vim.api.nvim_win_get_cursor(0))
  if at ~= state.line or row_id(vim.api.nvim_get_current_line()) ~= state.id or col + 1 < state.start then
    return false
  end
  local t = complete.target(state.buf, at, col + 1)
  return t ~= nil and t.column == "assignee"
end

-- Whether an item is selected with <C-n>, and so in the buffer; a
-- refresh would drop the selection.
local function selecting()
  return vim.fn.complete_info({ "selected" }).selected ~= -1
end

local function show(state, text, first)
  local search = session.get():people()
  local list = search:candidates(text, M.locals())
  if first then
    -- As the type and state menus do: a cell holding a whole value, or
    -- text that matches no one, offers everyone so another can be picked.
    for _, p in ipairs(list) do
      if people.names(p, text) then state.exact = text:lower() end
    end
    if state.exact or #list == 0 then list = search:candidates("", M.locals()) end
  end
  vim.fn.complete(state.start, items(state, list))
end

local function report(err)
  if reported then return end
  reported = true
  notify("people search failed: " .. tostring(err.message), vim.log.levels.ERROR)
end

-- Reports a search that called ADO on the progress line and in ux_stats.
local function timed(text, started, found, info)
  if info.calls == 0 then return end
  local ms = (vim.uv.hrtime() - started) / 1e6
  ux_stats.record("people_search", ms, { found = #found })
  progress.echo(string.format("people '%s': %d found in %.2f s", text, #found, ms / 1000))
end

local function search(state, text)
  local started = vim.uv.hrtime()
  session.get():people():search(text, { quiet = true }, function(err, found, info)
    if err then return report(err) end
    timed(text, started, found, info)
    if info.stale or active ~= state or not here(state) or selecting() then return end
    local now = typed(state)
    if now:lower():sub(1, #text) ~= text:lower() then return end
    show(state, now)
  end)
end

-- Searches text once no key has come for DEBOUNCE_MS.
local function later(state, text)
  state.gen = state.gen + 1
  local gen = state.gen
  if vim.fn.strchars(text) < M.MIN_CHARS or text:lower() == state.exact then return end
  vim.defer_fn(function()
    if active == state and state.gen == gen then search(state, text) end
  end, M.DEBOUNCE_MS)
end

-- Opens the menu for target t (nvim/complete.lua) of the cursor's line,
-- the cursor moved after the cell's text so the person picked replaces it.
function M.open(buf, t)
  local line = vim.api.nvim_get_current_line()
  local start, prefix, col = complete.span(line, t.cell)
  vim.api.nvim_win_set_cursor(0, { t.line, col })
  local state = { buf = buf, line = t.line, id = row_id(line), start = start, prefix = prefix, gen = 0 }
  active = state
  local text = typed(state)
  show(state, text, true)
  later(state, text)
end

local function changed(buf)
  local state = active
  if not state or state.buf ~= buf then return end
  if not here(state) then
    active = nil
    return
  end
  if selecting() then return end
  local text = typed(state)
  show(state, text)
  later(state, text)
end

local function done()
  if not active then return end
  local item = vim.v.completed_item or {}
  local person = type(item.user_data) == "table" and item.user_data.ado_person
  if person then
    session.get():people():picked(person)
    active = nil
  elseif vim.v.event and vim.v.event.reason == "cancel" then
    active = nil
  end
end

-- Whether a people menu is open, for specs.
function M.is_open()
  return active ~= nil
end

function M.attach(buf)
  local function on(events, fn)
    vim.api.nvim_create_autocmd(events, { buffer = buf, callback = fn })
  end
  on("InsertEnter", function() reported = false end)
  on("InsertLeave", function() active = nil end)
  on({ "TextChangedI", "TextChangedP" }, function() changed(buf) end)
  on("CompleteDone", done)
end

-- For <leader>we (UX6.6): the people matching text, searched in ADO, then
-- cb(list) ranked as the menu ranks them, or cb(nil) after a failure,
-- which the session has reported.
function M.find(text, cb)
  local search = session.get():people()
  local started = vim.uv.hrtime()
  search:search(text, {}, function(err, found, info)
    if err then return cb(nil) end
    timed(text, started, found, info)
    cb(search:candidates(text, M.locals()))
  end)
end

-- Everyone the menu offers before a search: picked, then on loaded rows.
function M.local_candidates()
  return session.get():people():candidates("", M.locals())
end

function M.picked(person)
  session.get():people():picked(person)
end

return M
