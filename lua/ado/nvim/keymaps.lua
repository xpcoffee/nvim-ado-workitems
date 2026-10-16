-- Default buffer-local keys of the views (plan 0001 phase 2 key table).
-- They take precedence over the global <leader>w keys.
local M = {}

-- `ic` and `ac`, the cell under the cursor (nvim/cells.lua). A <Cmd>
-- mapping, not an expression, so that `.` repeats `cic`.
local function cell_objects(buf)
  for lhs, around in pairs({ ic = false, ac = true }) do
    vim.keymap.set({ "o", "x" }, lhs, function() require("ado.nvim.cells").select(around) end,
      { buffer = buf, desc = around and "ado: a cell, with its separator" or "ado: inner cell" })
  end
end

-- The value menus and pickers of type and state cells (plan 0002 UX3.1,
-- UX3.2, UX3.5). Terminals send <C-Space> as NUL, which Neovim reads as
-- <C-@>.
local function pickers(buf)
  require("ado.nvim.complete").attach(buf)
  for _, lhs in ipairs({ "<C-Space>", "<C-@>" }) do
    vim.keymap.set("i", lhs, function() require("ado.nvim.complete").menu() end,
      { buffer = buf, desc = "ado: list the values of this type or state cell" })
  end
  vim.keymap.set("n", "<leader>we", function() require("ado.nvim.pick").pick(false) end,
    { buffer = buf, desc = "ado: pick a type or state for this cell" })
  vim.keymap.set("x", "<leader>we", function() require("ado.nvim.pick").pick(true) end,
    { buffer = buf, desc = "ado: pick a type or state for this column on every selected row" })
end

-- Cut cells (plan 0002 UX4.4, UX5.2): the full-row float, and <leader>wx,
-- which shows a cut cell in full.
local function fitting(buf)
  require("ado.nvim.hover").attach(buf)
  vim.keymap.set("n", "<leader>wx", function() require("ado.nvim.reveal").show(false) end,
    { buffer = buf, desc = "ado: show this cut cell in full" })
  vim.keymap.set("x", "<leader>wx", function() require("ado.nvim.reveal").show(true) end,
    { buffer = buf, desc = "ado: show this column in full on every selected row" })
end

-- actions: select, parent, back, forward, filters, toggle_sub, browser, reload
function M.area(buf, actions)
  cell_objects(buf)
  pickers(buf)
  fitting(buf)
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "ado: " .. desc, remap = false, nowait = true })
  end
  k("<CR>", actions.select, "open the sub-area or work item")
  k("-", actions.parent, "parent area")
  k("[h", actions.back, "history back")
  k("]h", actions.forward, "history forward")
  k("<leader>wf", actions.filters, "choose filters")
  k("<leader>wu", actions.toggle_sub, "toggle sub-area items")
  k("<leader>wb", actions.browser, "open the query in the browser")
  k("<leader>wr", actions.reload, "reload")
end

-- actions: select, back, forward, filters, browser, reload
function M.query(buf, actions)
  cell_objects(buf)
  pickers(buf)
  fitting(buf)
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "ado: " .. desc, remap = false, nowait = true })
  end
  k("<CR>", actions.select, "open the work item")
  k("[h", actions.back, "history back")
  k("]h", actions.forward, "history forward")
  k("<leader>wf", actions.filters, "choose filters")
  k("<leader>wb", actions.browser, "open the query in the browser")
  k("<leader>wr", actions.reload, "reload")
end

-- actions: select, back, forward, expand, preview, description, comment,
-- toggle_all, browser, reload
function M.item(buf, actions)
  cell_objects(buf)
  pickers(buf)
  fitting(buf)
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "ado: " .. desc, remap = false, nowait = true })
  end
  k("<CR>", actions.select, "open the parent, child, link or area")
  k("[h", actions.back, "history back")
  k("]h", actions.forward, "history forward")
  k("<Tab>", actions.expand, "expand or collapse the child")
  k("K", actions.preview, "show the row's item in a float")
  k("gd", actions.select, "open the parent, child, link or area")
  k("<leader>wd", actions.description, "edit the description; :w saves it")
  k("<leader>wc", actions.comment, "add a comment, sent at once")
  k("<leader>wt", actions.toggle_all, "children and links in every state, or open only")
  k("<leader>wb", actions.browser, "open the item in the browser")
  k("<leader>wr", actions.reload, "reload")
end

return M
