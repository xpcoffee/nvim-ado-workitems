-- Default buffer-local keys of the views (plan 0001 phase 2 key table).
-- They take precedence over the global <leader>w keys.
local M = {}

-- actions: select, parent, back, forward, filters, toggle_sub, browser, reload
function M.area(buf, actions)
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

-- actions: select, back, forward, expand, preview, detail, toggle_all,
-- browser, reload
function M.item(buf, actions)
  local function k(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = "ado: " .. desc, remap = false, nowait = true })
  end
  k("<CR>", actions.select, "open the parent, child, link or area")
  k("[h", actions.back, "history back")
  k("]h", actions.forward, "history forward")
  k("<Tab>", actions.expand, "expand or collapse the child")
  k("K", actions.preview, "preview in the detail split")
  k("gd", actions.detail, "open in the detail buffer")
  k("<leader>wt", actions.toggle_all, "children and links in every state, or open only")
  k("<leader>wb", actions.browser, "open the item in the browser")
  k("<leader>wr", actions.reload, "reload")
end

return M
