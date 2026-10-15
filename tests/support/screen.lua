-- Reads what a window draws, with conceal and sideways scrolling applied,
-- for specs that check what the user sees rather than the buffer text.
-- Uses vim, so only tests/nvim specs load it.
local M = {}

-- The drawn text of each screen row of win, trailing spaces removed.
function M.rows(win)
  if win == nil or win == 0 then win = vim.api.nvim_get_current_win() end
  -- After enough messages the screen stays scrolled up by them, which
  -- redraw! alone leaves as it is; :mode clears it.
  vim.cmd("mode")
  vim.cmd("redraw!")
  local info = vim.fn.getwininfo(win)[1]
  local out = {}
  local top = info.winrow + info.winbar
  for row = top, top + info.height - 1 do
    local cells = {}
    for col = info.wincol, info.wincol + info.width - 1 do
      table.insert(cells, vim.fn.screenstring(row, col))
    end
    out[#out + 1] = (table.concat(cells):gsub("%s+$", ""))
  end
  return out
end

-- The screen columns (1-based, within the window) where `glyph` is drawn
-- on a row.
function M.columns(row, glyph)
  local out = {}
  local col = 0
  for ch in row:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    col = col + 1
    if ch == glyph then table.insert(out, col) end
  end
  return out
end

return M
