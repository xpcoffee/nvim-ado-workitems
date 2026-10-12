-- Window layout and navigation for the views (RFC 0001 R4.1, R4.2): one
-- column of stacked windows, the area view on top, the item view beneath
-- it, then the detail buffer, each present only when open. Each role reuses
-- its window while that window is in the current tab and still shows a
-- buffer of the role, so a window the user has put another buffer in is
-- left alone. Area and item locations share one history.
local history = require("ado.core.history")
local location = require("ado.core.location")

local M = {}

M.history = history.new()

local FILETYPES = { area = "adoarea", detail = "adoitem", item = "adoitemview" }

local wins = {}

local function win_of(role)
  local win = wins[role]
  if not win or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
      or vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= FILETYPES[role] then
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

local ORDER = { "area", "item", "detail" }

-- Gives the open role windows equal heights, leaving other windows alone.
-- Reads wins directly: a window just claimed still shows the buffer it was
-- split from until its view loads, so win_of would drop it.
local function balance()
  local open, total = {}, 0
  local tab = vim.api.nvim_get_current_tabpage()
  for _, role in ipairs(ORDER) do
    local win = wins[role]
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab then
      table.insert(open, win)
      total = total + vim.api.nvim_win_get_height(win)
    end
  end
  for _, win in ipairs(open) do vim.api.nvim_win_set_height(win, math.floor(total / #open)) end
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

-- The area view takes the current window when no view window is open yet.
local function focus_area()
  local alone = not win_of("item") and not win_of("detail")
  vim.api.nvim_set_current_win(window("area", alone))
end

local function detail_window()
  return window("detail")
end

local function focus_item()
  vim.api.nvim_set_current_win(window("item"))
end

-- Shows a location in its role's window and records it in the history,
-- unless opts.record is false (back and forward). opts.keep_expansion is
-- passed to the item view.
local last = {}

function M.go(loc, opts)
  opts = opts or {}
  if opts.record ~= false then M.history:visit(loc) end
  last[loc.kind] = loc
  if loc.kind == "area" then
    focus_area()
    return require("ado.nvim.area_view").show(loc)
  end
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

-- Shows item id in the detail split; opts.focus = false keeps the cursor
-- where it is (R3.5 preview).
function M.show_detail(id, opts)
  local from = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(detail_window())
  require("ado.nvim.detail").open(id)
  if opts and opts.focus == false and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end
end

-- Like show_detail, without creating a detail split when there is none.
function M.sync_detail(id)
  if win_of("detail") then M.show_detail(id, { focus = false }) end
end

-- Selecting an item in the area view (R4.2): its detail buffer in the
-- split, then its item view in the panel, which takes the cursor.
function M.open_item_from_area(id)
  claim("area", vim.api.nvim_get_current_win())
  M.show_detail(id)
  M.go(location.item(id))
end

-- The item view for an item, beside the current window. From a detail
-- buffer (R3.7), that window becomes the detail split.
function M.open_item(id)
  local win = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == FILETYPES.detail then claim("detail", win) end
  M.go(location.item(id))
end

function M.window(role)
  return win_of(role)
end

-- Closes the window of `role` ("area" or "item") and returns true, or
-- returns false when it has none. The last window in the tab stays open,
-- since Neovim cannot close it.
local function close(role)
  local win = win_of(role)
  if not win then return false end
  if #vim.api.nvim_tabpage_list_wins(0) == 1 then
    vim.notify("[ado] the " .. role .. " view is the only window; not closing it", vim.log.levels.INFO)
    return true
  end
  vim.api.nvim_win_close(win, false)
  wins[role] = nil
  balance()
  return true
end

-- Toggles the area view: closes its window, else reopens the last area
-- location shown. Returns false when there is nothing to reopen.
function M.toggle_area()
  if close("area") then return true end
  if not last.area then return false end
  M.go(last.area, { record = false })
  return true
end

-- Toggles the item view: closes its window, else opens it for item `id`
-- when given (the detail buffer's item), else reopens the last item
-- location shown. Returns false when there is nothing to open.
function M.toggle_item(id)
  if close("item") then return true end
  if id then
    M.open_item(id)
    return true
  end
  if not last.item then return false end
  M.go(last.item, { record = false })
  return true
end

return M
