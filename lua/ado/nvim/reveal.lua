-- <leader>wx (plan 0002 UX5.2): shows a cut cell in full, on the cursor's
-- row or on every selected row in Visual mode, as an ordinary change that
-- `u` undoes. A cell shown in full is not cut again until the view is
-- rendered again, so edits to it are plain edits of the full value.
local cells = require("ado.nvim.cells")
local fit = require("ado.nvim.fit")
local realign = require("ado.nvim.realign")
local registry = require("ado.nvim.registry")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

-- The value to show for the cell: its full value, or, for a cut cell
-- whose full value is not known (UX5.4), the value it was loaded with.
local function full_value(line, column)
  local r = fit.read(line)
  if not r then return nil end
  for _, a in ipairs(r.ambiguous or {}) do
    if a == column then
      local reg = r.row_id and registry.get(r.row_id)
      if not reg then return nil end
      return reg.row.kind == "field" and reg.row.value or reg.row[column], true
    end
  end
  return r.values[column], false
end

function M.show(visual)
  local buf = vim.api.nvim_get_current_buf()
  local at, col = unpack(vim.api.nvim_win_get_cursor(0))
  local first, last = at, at
  if visual then
    first = vim.fn.line("v")
    if first > last then first, last = last, first end
    vim.cmd("normal! \27")
  end
  local region = require("ado.nvim.region")
  local line = vim.api.nvim_get_current_line()
  local c = region.readable(buf, at) and cells.at(line, col + 1) or nil
  if not c then return notify("<leader>wx shows a cut cell in full; this line has no cells") end
  if not vim.bo[buf].modifiable then return notify("the view is loading; try again once it has loaded") end
  local column = cells.column(line, c)
  local index = (c.count > 1) and c.index or nil
  local shown, reloaded = 0, 0
  for n = first, math.min(last, region.last_row(buf)) do
    local text = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
    local cell = index and cells.nth(text, index) or (n == at and c) or nil
    local id = tonumber(text:match("^/(%d+) "))
    if cell and id and cells.column(text, cell) == column then
      local value, was_ambiguous = full_value(text, column)
      local now = text:sub(cell.first, cell.last)
      if value and value ~= now then
        cells.write(buf, { n }, index, value)
        fit.keep_full(buf, id, column)
        shown = shown + 1
        if was_ambiguous then reloaded = reloaded + 1 end
      end
    end
  end
  if shown == 0 then return notify("the " .. column .. " is shown in full") end
  realign.run(buf)
  view_buffer.decorate(buf)
  if reloaded > 0 then
    notify(string.format("the %s on %d %s was cut and its … edited, so its full text was not known;"
      .. " it shows the %s it was loaded with", column, reloaded, reloaded == 1 and "row" or "rows", column),
      vim.log.levels.WARN)
  end
end

return M
