-- Buffers for the area and item views: named by their location URI,
-- acwrite so that :w reaches the plugin and never the file system, row ID
-- prefixes concealed, and a window bar per buffer.
local M = {}

local NS = vim.api.nvim_create_namespace("ado_view")
local LABELS = vim.api.nvim_create_namespace("ado_view_labels")

-- vim.fn.bufnr() treats its argument as a file pattern, and these names
-- hold "?", so buffers are matched by exact name instead.
function M.find(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then return buf end
  end
end

local function apply_window_options(buf, win)
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  set("conceallevel", 2)
  set("concealcursor", "nvic")
  set("wrap", false)
  set("winbar", (vim.b[buf].ado_winbar or ""):gsub("%%", "%%%%"))
end

-- Returns the buffer and whether it was created now.
function M.get_or_create(name, filetype)
  local existing = M.find(name)
  if existing then return existing, false end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      vim.notify("[ado] views are read-only in this version; nothing was saved", vim.log.levels.WARN)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function() apply_window_options(buf, vim.api.nvim_get_current_win()) end,
  })
  return buf, true
end

local function conceal(buf, first, prefixes)
  for i, len in ipairs(prefixes or {}) do
    if len > 0 then
      vim.api.nvim_buf_set_extmark(buf, NS, first + i - 1, 0, { end_col = len, conceal = "" })
    end
  end
end

-- Changes lines of a view that is not modifiable, keeping its modified flag.
local function edit(buf, first, last, lines)
  local modified = vim.bo[buf].modified
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = modified
end

-- prefixes: per line, the byte length to conceal from column 0.
function M.set_lines(buf, lines, prefixes)
  edit(buf, 0, -1, lines)
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, LABELS, 0, -1)
  conceal(buf, 0, prefixes)
end

-- Inserts lines before line `at` (0-based) without redrawing the others.
function M.insert_lines(buf, at, lines, prefixes)
  edit(buf, at, at, lines)
  conceal(buf, at, prefixes)
end

-- Deletes lines first to last - 1 (0-based).
function M.delete_lines(buf, first, last)
  -- A deleted line's extmarks would otherwise move onto the next line.
  vim.api.nvim_buf_clear_namespace(buf, NS, first, last)
  vim.api.nvim_buf_clear_namespace(buf, LABELS, first, last)
  edit(buf, first, last, {})
end

-- labels: { [0-based line] = text }, shown after the end of the line.
function M.set_labels(buf, labels)
  for line, text in pairs(labels) do
    vim.api.nvim_buf_set_extmark(buf, LABELS, line, 0, { virt_text = { { text, "Comment" } }, virt_text_pos = "eol" })
  end
end

function M.set_winbar(buf, text)
  vim.b[buf].ado_winbar = text
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do apply_window_options(buf, win) end
end

function M.show(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  apply_window_options(buf, win)
end

return M
