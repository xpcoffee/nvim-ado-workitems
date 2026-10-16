-- Window layout and navigation for the views (RFC 0001 R4.1, R4.2, R9.2,
-- RFC 0003 C6): one column of stacked windows, one per role: the list on
-- top (an area view or a query list) and the item buffer beneath it, each
-- present only when open. Each role reuses its window while
-- that window is in the current tab and still shows a buffer of the role,
-- so a window the user has put another buffer in is left alone. Every
-- location shares one history.
local history = require("ado.core.history")
local location = require("ado.core.location")

local M = {}

M.history = history.new()

-- role -> the filetypes of the buffers it shows.
local FILETYPES = {
  list = { adoarea = true, adoquery = true },
  item = { adoitemview = true },
}

local wins = {}

local function win_of(role)
  local win = wins[role]
  if not win or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
      or not FILETYPES[role][vim.bo[vim.api.nvim_win_get_buf(win)].filetype] then
    wins[role] = nil
    return nil
  end
  return win
end

local function claim(role, win)
  for r, w in pairs(wins) do
    if w == win and r ~= role then wins[r] = nil end
  end
  wins[role] = win
end

local function split(from, cmd)
  vim.api.nvim_set_current_win(from)
  vim.cmd(cmd)
  return vim.api.nvim_get_current_win()
end

local ORDER = { "list", "item" }

-- The item window's share of the column when the list is open too (RFC
-- 0003 C6.2): it holds the header, the details and the comments.
M.ITEM_SHARE = 2 / 3

-- Splits the column between the open role windows, leaving other windows
-- alone. Reads wins directly: a window just claimed still shows the buffer
-- it was split from until its view loads, so win_of would drop it.
local function balance()
  local open, total = {}, 0
  local tab = vim.api.nvim_get_current_tabpage()
  for _, role in ipairs(ORDER) do
    local win = wins[role]
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab then
      open[role] = win
      total = total + vim.api.nvim_win_get_height(win)
    end
  end
  if open.list and open.item then
    local item = math.floor(total * M.ITEM_SHARE + 0.5)
    vim.api.nvim_win_set_height(open.list, total - item)
    vim.api.nvim_win_set_height(open.item, item)
  end
end

-- A new window for `role` in its place in the column: below the nearest
-- open role above it, else above the nearest open role below it, else
-- below the current window.
local function place(role)
  local at
  for i, r in ipairs(ORDER) do if r == role then at = i end end
  for i = at - 1, 1, -1 do
    local w = win_of(ORDER[i])
    if w then return split(w, "rightbelow split") end
  end
  for i = at + 1, #ORDER do
    local w = win_of(ORDER[i])
    if w then return split(w, "leftabove split") end
  end
  return split(vim.api.nvim_get_current_win(), "rightbelow split")
end

-- The window for `role`, created in its place in the column if needed.
local function window(role, use_current)
  local win = win_of(role)
  if win then return win end
  win = use_current and vim.api.nvim_get_current_win() or place(role)
  claim(role, win)
  balance()
  return win
end

-- The list takes the current window when no view window is open yet.
local function focus_list()
  vim.api.nvim_set_current_win(window("list", not win_of("item")))
end

local function focus_item()
  vim.api.nvim_set_current_win(window("item"))
end

-- role -> the last location it showed, which its toggle reopens.
local last = {}

local LIST_MODULES = { area = "ado.nvim.area_view", query = "ado.nvim.query_view" }

-- Shows a location in its role's window and records it in the history,
-- unless opts.record is false (back and forward). opts.keep_expansion is
-- passed to the item view.
function M.go(loc, opts)
  opts = opts or {}
  if opts.record ~= false then M.history:visit(loc) end
  if LIST_MODULES[loc.kind] then
    last.list = loc
    focus_list()
    return require(LIST_MODULES[loc.kind]).show(loc)
  end
  last.item = loc
  focus_item()
  return require("ado.nvim.item_view").show(loc, opts)
end

function M.back()
  local loc = M.history:back()
  if loc then M.go(loc, { record = false }) end
end

function M.forward()
  local loc = M.history:forward()
  if loc then M.go(loc, { record = false }) end
end

-- Selecting an item in a list (R4.2, R9.2, RFC 0003 C6.3): its item
-- buffer in the item window, which takes the cursor.
function M.open_item_from_list(id)
  claim("list", vim.api.nvim_get_current_win())
  M.go(location.item(id))
end

-- The item buffer for an item, in the item window (RFC 0003 C6.4).
function M.open_item(id)
  M.go(location.item(id))
end

function M.window(role)
  return win_of(role)
end

-- Closes the window of `role` ("list" or "item") and returns true, or
-- returns false when it has none. The last window in the tab stays open,
-- since Neovim cannot close it.
local function close(role)
  local win = win_of(role)
  if not win then return false end
  if #vim.api.nvim_tabpage_list_wins(0) == 1 then
    vim.notify("[ado] the " .. role .. " window is the only window; not closing it", vim.log.levels.INFO)
    return true
  end
  vim.api.nvim_win_close(win, false)
  wins[role] = nil
  balance()
  return true
end

-- Toggles the top window: closes it, else reopens the last list shown,
-- an area view or a query list. Returns false when there is nothing to
-- reopen.
function M.toggle_list()
  if close("list") then return true end
  if not last.list then return false end
  M.go(last.list, { record = false })
  return true
end

-- Toggles the item window: closes it, else reopens the last item location
-- shown. Returns false when there is nothing to open.
function M.toggle_item()
  if close("item") then return true end
  if not last.item then return false end
  M.go(last.item, { record = false })
  return true
end

return M
