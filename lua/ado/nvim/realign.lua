-- Keeps the item rows of a view aligned and fitted to the window while the
-- user edits (plan 0002 UX1.1 to UX1.6, UX5.1). The padding is real text,
-- so blockwise Visual changes work on every row; after each change it is
-- re-padded to the column widths of all rows, each edited cut cell gets
-- its full value back and is cut again (nvim/fit.lua), and all of it is
-- joined to the change with :undojoin, so one `u` undoes both. During
-- Insert mode only the edited line drifts.
local fit = require("ado.nvim.fit")
local ux_stats = require("ado.nvim.ux_stats")

local M = {}

-- buf -> the changedtick at which the buffer was last known aligned.
local aligned = {}

-- Marks the buffer's text as aligned, for a change the plugin made itself
-- (a load, an expansion, a save's reload), which renders aligned.
function M.settle(buf)
  aligned[buf] = vim.api.nvim_buf_get_changedtick(buf)
  fit.snapshot(buf, true)
end

local function plan(buf, user)
  return fit.plan(buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false), user)
end

-- The cursor column after edits (byte ranges of the body, offset bytes
-- into the line): the same cell, at the same offset in it.
local function moved(col, offset, edits)
  local shift = 0
  for i = #edits, 1, -1 do
    local e = edits[i]
    local s, stop = offset + e.from - 1, offset + e.to
    if col >= stop then
      shift = shift + #e.text - (stop - s)
    elseif col >= s then
      return s + shift + math.min(col - s, math.max(#e.text - 1, 0))
    else
      break
    end
  end
  return col + shift
end

local function apply(buf, todo)
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do cursors[win] = vim.api.nvim_win_get_cursor(win) end
  local by_line = {}
  for _, t in ipairs(todo) do
    by_line[t.line + 1] = t
    for _, e in ipairs(t.edits) do
      vim.api.nvim_buf_set_text(buf, t.line, t.offset + e.from - 1, t.line, t.offset + e.to, { e.text })
    end
  end
  for win, cur in pairs(cursors) do
    local t = by_line[cur[1]]
    local col = t and moved(cur[2], t.offset, t.edits) or cur[2]
    pcall(vim.api.nvim_win_set_cursor, win, { cur[1], col })
  end
end

-- Re-pads buf in place, for a change the plugin makes itself, which is
-- left out of the undo history.
function M.repad(buf)
  local todo = plan(buf, false)
  if #todo > 0 then apply(buf, todo) end
end

-- Re-pads buf after a change of the user's, unless it is already aligned at this changedtick, has
-- no unsaved edits, cannot be edited, or sits at an undo state older than
-- its newest. After `u` every state is already aligned, because each
-- change was joined to its re-pad, and :undojoin after `u` fails (E790).
-- After `u` the text is one the re-pad left, so every cell's text is in
-- its shown map; the snapshot still follows it, for the next edit.
function M.run(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if aligned[buf] == tick then return end
  if not vim.bo[buf].modified or not vim.bo[buf].modifiable then
    aligned[buf] = tick
    fit.snapshot(buf)
    return
  end
  local started = vim.uv.hrtime()
  local todo, rows, after = plan(buf, true)
  if #todo > 0 then
    local ok = vim.api.nvim_buf_call(buf, function()
      local tree = vim.fn.undotree()
      if tree.seq_cur < tree.seq_last then return false end
      return pcall(vim.cmd, "undojoin")
    end)
    if not ok then
      ux_stats.count("repad_skipped")
      aligned[buf] = tick
      fit.snapshot(buf)
      return
    end
    apply(buf, todo)
  end
  aligned[buf] = vim.api.nvim_buf_get_changedtick(buf)
  fit.snapshot_rows(buf, after)
  ux_stats.record("repad", (vim.uv.hrtime() - started) / 1e6, { lines = #todo, rows = rows })
end

local function in_insert()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

function M.attach(buf)
  M.settle(buf)
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = buf,
    callback = function()
      if not in_insert() then M.run(buf) end
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = buf,
    -- A blockwise insert (<C-v> then c or I) copies the typed text to the
    -- other lines after InsertLeave, reading it back from the first line;
    -- re-padding that line first would copy the padding too.
    callback = function()
      vim.schedule(function()
        if not in_insert() then M.run(buf) end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      aligned[buf] = nil
      fit.forget(buf)
    end,
  })
end

return M
