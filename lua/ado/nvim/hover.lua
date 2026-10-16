-- The full-row float (plan 0002 UX4.4, the owner's answer to Q4): when the
-- cursor rests in Normal mode on a cut cell, a type shown as one letter, or
-- a row whose tags are hidden, a float beside the cursor shows the whole
-- row. It never takes focus and closes as soon as the cursor moves.
local cells = require("ado.nvim.cells")
local fit = require("ado.nvim.fit")
local registry = require("ado.nvim.registry")
local row_info = require("ado.core.row_info")

local M = {}

-- Milliseconds the cursor rests before the float opens. The timer starts
-- on CursorMoved: CursorHold waits 'updatetime', which is global and 4,000
-- ms by default.
M.delay = 300

local timer
-- { win, buf } of the open float.
local open

function M.close()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if open then
    if vim.api.nvim_win_is_valid(open.win) then vim.api.nvim_win_close(open.win, true) end
    open = nil
  end
end

-- The float's lines for the cursor's cell on line, or nil when the cell
-- and its row are shown in full.
function M.content(line, col)
  local r = fit.read(line)
  if not r or not r.row_id then return nil end
  local c = cells.at(line, col)
  if not c then return nil end
  local column = cells.column(line, c)
  local function cut(name)
    for _, cell in ipairs(r.cells) do
      if cell.column == name then
        local _, how = fit.lookup(r.row_id, name, cell.text)
        return how == "cut"
      end
    end
    return false
  end
  local reg = registry.get(r.row_id)
  if r.kind == "table" then
    if not (cut(column) or cut("tags")) then return nil end
    return row_info.lines(r.values, reg and reg.row)
  end
  if not cut(column) then return nil end
  return { r.values[column] }
end

local function show(buf, win, at)
  if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_current_buf() ~= buf then return end
  if vim.api.nvim_get_mode().mode ~= "n" then return end
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] ~= at[1] or cursor[2] ~= at[2] then return end
  if not require("ado.nvim.region").readable(buf, cursor[1]) then return end
  local text = M.content(vim.api.nvim_get_current_line(), cursor[2] + 1)
  if not text then return end
  local width = 1
  for _, t in ipairs(text) do width = math.max(width, vim.fn.strdisplaywidth(t)) end
  width = math.min(width, math.max(1, vim.o.columns - 4))
  local height = 0
  for _, t in ipairs(text) do height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(t) / width)) end
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, text)
  height = math.min(height, 20)
  local opts = { relative = "cursor", row = 1, col = 0, width = width, height = height,
    style = "minimal", focusable = false, noautocmd = true }
  -- 'winborder' (Neovim 0.11) applies when no border is given.
  local has_winborder, winborder = pcall(function() return vim.o.winborder end)
  if not has_winborder or winborder == "" then opts.border = "rounded" end
  -- Above the cursor when the rows below cannot hold it with its border,
  -- so it never covers the row it describes.
  local below = vim.api.nvim_win_get_height(win) - vim.fn.winline()
  if below < height + 2 and vim.fn.winline() > height + 2 then opts.row = -(height + 2) end
  local fwin = vim.api.nvim_open_win(fbuf, false, opts)
  vim.wo[fwin].wrap = true
  open = { win = fwin, buf = fbuf }
end

function M.attach(buf)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      M.close()
      local win = vim.api.nvim_get_current_win()
      local at = vim.api.nvim_win_get_cursor(win)
      local t = vim.uv.new_timer()
      timer = t
      t:start(M.delay, 0, vim.schedule_wrap(function()
        if timer ~= t then return end
        t:close()
        timer = nil
        show(buf, win, at)
      end))
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertEnter", "BufLeave", "WinScrolled" }, {
    buffer = buf,
    callback = function() M.close() end,
  })
end

-- The open float's window, for the specs.
function M.window()
  return open and open.win or nil
end

return M
