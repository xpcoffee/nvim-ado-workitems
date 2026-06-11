-- Generic floating editor. Owns its own window + scratch buffer and tears both
-- down on confirm or cancel (bufhidden=wipe), so callers never manage buffers.
-- Knows nothing about ADO: callers pass current lines and get edited lines back.
local M = {}

-- opts:
--   title      string                 shown on the border
--   lines      { string... }          prefill (one element for single-line)
--   filetype   string|nil             e.g. "markdown"
--   multiline  boolean|nil            if true, <CR> inserts a newline (confirm is <C-s> only)
--   width/height number|nil           sensible defaults derived from content/editor
--   on_confirm function(lines)        called AFTER the window closes
--   on_cancel  function()|nil
function M.text(opts)
  local lines = opts.lines or { "" }
  if #lines == 0 then lines = { "" } end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  if opts.filetype then vim.bo[buf].filetype = opts.filetype end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = opts.width or math.min(80, math.max(20, math.floor(vim.o.columns * 0.6)))
  local height = opts.height or math.min(#lines, math.floor(vim.o.lines * 0.5))
  if height < 1 then height = 1 end
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = opts.title and "center" or nil,
    row = row,
    col = col,
    width = width,
    height = height,
  })
  vim.wo[win].wrap = true
  vim.api.nvim_win_set_cursor(win, { #lines, #(lines[#lines] or "") })

  local closed = false
  local function close(commit)
    if closed then return end
    closed = true
    -- Confirm/cancel can fire from insert mode; leave it so the window we land
    -- on (the read-only detail buffer) doesn't receive stray insert keystrokes.
    vim.cmd("stopinsert")
    local result
    if commit and vim.api.nvim_buf_is_valid(buf) then
      result = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if commit then
      if opts.on_confirm then opts.on_confirm(result) end
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function map(mode, lhs, commit)
    vim.keymap.set(mode, lhs, function() close(commit) end, { buffer = buf, nowait = true })
  end

  map({ "n", "i" }, "<C-s>", true)
  if not opts.multiline then
    -- single-line: Enter confirms in both modes
    map("n", "<CR>", true)
    map("i", "<CR>", true)
  end
  map("n", "q", false)
  map("n", "<Esc>", false)

  -- Closing the window by any other means (e.g. :q, <C-w>c) counts as cancel.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() close(false) end,
  })

  return win
end

return M
