-- The save summary float: y applies, n, q and <Esc> cancel, and a plan
-- with rejections can only be closed.
local views = require("tests.support.views")
local key = views.key

local LINES = { { text = "Save 1 change to Azure DevOps?", kind = "title" },
  { text = "Field changes", kind = "heading" }, { text = "  #101 state: To Do -> Doing", kind = "change" } }

local function open(can_apply)
  views.fresh()
  local answers = {}
  local win = require("ado.nvim.summary_ui").open(LINES, can_apply, function(a) table.insert(answers, a) end)
  return win, answers
end

test("the float shows the summary and y accepts once", function()
  local win, answers = open(true)
  eq(vim.api.nvim_get_current_win(), win)
  local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  eq(text[1], "Save 1 change to Azure DevOps?")
  eq(text[#text], "  #101 state: To Do -> Doing")
  eq(vim.api.nvim_win_get_config(win).footer[1][1], " y apply  ·  n or q cancel, keeping the edits ")
  key("y")
  eq(answers, { true })
  eq(vim.api.nvim_win_is_valid(win), false)
end)

test("n, q and <Esc> cancel", function()
  for _, k in ipairs({ "n", "q", "<Esc>" }) do
    local win, answers = open(true)
    key(k)
    eq(answers, { false }, k)
    eq(vim.api.nvim_win_is_valid(win), false)
  end
end)

test("with rejections, y does nothing and q closes as a cancel", function()
  local win, answers = open(false)
  key("y")
  eq(answers, {})
  eq(vim.api.nvim_win_is_valid(win), true)
  key("q")
  eq(answers, { false })
end)

test("closing the float another way counts as a cancel", function()
  local win, answers = open(true)
  vim.api.nvim_win_close(win, true)
  eq(answers, { false })
end)

test("leaving the float cancels the save, so it cannot be stranded", function()
  local win, answers = open(true)
  vim.cmd("wincmd p")
  vim.wait(100, function() return #answers > 0 end)
  eq(answers, { false })
  eq(vim.api.nvim_win_is_valid(win), false)
end)

test("the float is tall enough for wrapped lines, and refits when the screen resizes", function()
  views.fresh()
  vim.o.columns = 60
  local long = { { text = "Save 1 change to Azure DevOps?", kind = "title" },
    { text = "  " .. string.rep("x", 150), kind = "change" } }
  local win = require("ado.nvim.summary_ui").open(long, true, function() end)
  local cfg = vim.api.nvim_win_get_config(win)
  eq(cfg.width, 56)
  eq(cfg.height, 1 + 3)
  vim.o.columns = 120
  vim.api.nvim_exec_autocmds("VimResized", {})
  eq(vim.api.nvim_win_get_config(win).height, 1 + 2)
  key("q")
  vim.o.columns = 200
end)
