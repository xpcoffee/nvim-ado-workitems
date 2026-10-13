-- The save summary in a float (RFC 0001 R5.3): `y` applies, `n`, `q` or
-- <Esc> cancels. A plan with rejections can only be closed. The report of
-- a save that stopped opens in the same kind of float.
local M = {}

local NS = vim.api.nvim_create_namespace("ado_summary")

local HIGHLIGHTS = {
  title = "Title",
  heading = "Statement",
  rejection = "ErrorMsg",
  removal = "DiffDelete",
  copy = "DiffChange",
  type = "DiffChange",
  warning = "WarningMsg",
  note = "Comment",
}

-- Opens lines in a centred float with title and hint in its border, and
-- returns its buf and win.
local function open_float(lines, title, hint)
  local text, kinds = {}, {}
  for i, l in ipairs(lines) do
    text[i], kinds[i] = l.text, l.kind
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  for i, kind in pairs(kinds) do
    if HIGHLIGHTS[kind] then
      vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 0, { end_row = i - 1, end_col = #text[i], hl_group = HIGHLIGHTS[kind] })
    end
  end

  -- The key hint sits in the border, so wrapping or a short screen cannot
  -- push it out of view.
  local function frame()
    local width = vim.fn.strdisplaywidth(hint) + 2
    for _, t in ipairs(text) do width = math.max(width, vim.fn.strdisplaywidth(t) + 2) end
    width = math.max(1, math.min(width, vim.o.columns - 4))
    local rows = 0
    for _, t in ipairs(text) do rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(t) / width)) end
    local height = math.max(1, math.min(rows, vim.o.lines - 4))
    return {
      relative = "editor", width = width, height = height,
      row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    }
  end
  local opts = frame()
  opts.style, opts.border = "minimal", "rounded"
  opts.title, opts.title_pos = title, "center"
  opts.footer, opts.footer_pos = hint, "center"
  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.wo[win].wrap = true
  local group = vim.api.nvim_create_augroup("ado_summary_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", { group = group, callback = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, frame()) end
  end })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, once = true, callback = function()
    vim.api.nvim_del_augroup_by_id(group)
  end })
  return buf, win
end

local function close(win)
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
end

local function map(buf, lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, remap = false })
end

-- lines: { { text, kind }... } from core/summary.lua. cb(accepted) runs
-- once, also when the float is closed some other way.
function M.open(lines, can_apply, cb)
  local hint = can_apply and " y apply  ·  n or q cancel, keeping the edits "
    or " q close; nothing will be sent, the views keep their edits "
  local buf, win = open_float(lines, " ado: save ", hint)

  local answered = false
  local group = vim.api.nvim_create_augroup("ado_summary_answer_" .. buf, { clear = true })
  local function answer(accepted)
    if answered then return end
    answered = true
    vim.api.nvim_del_augroup_by_id(group)
    close(win)
    cb(accepted)
  end
  if can_apply then map(buf, "y", function() answer(true) end) end
  for _, lhs in ipairs({ "n", "q", "<Esc>" }) do map(buf, lhs, function() answer(false) end) end
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, once = true, callback = function() answer(false) end })
  -- Only this window has the answer keys, so leaving it (a click, <C-w>)
  -- would strand the save; leaving cancels instead, keeping the edits.
  vim.api.nvim_create_autocmd("WinLeave", { group = group, buffer = buf, callback = function()
    vim.schedule(function()
      if not answered then
        vim.notify("[ado] save cancelled: the summary lost focus; the edits are kept, :w to try again", vim.log.levels.WARN)
        answer(false)
      end
    end)
  end })
  return win
end

-- The report of a save that stopped (core/summary.lua report): q or <Esc>
-- closes it, and so does leaving it, since it asks nothing.
function M.report(lines)
  local buf, win = open_float(lines, " ado: save report ", " q close ")
  for _, lhs in ipairs({ "q", "<Esc>" }) do map(buf, lhs, function() close(win) end) end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function()
    vim.schedule(function() close(win) end)
  end })
  return win
end

return M
