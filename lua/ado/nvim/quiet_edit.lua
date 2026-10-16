-- Changes to a buffer that add no undo step and keep the undo history
-- (RFC 0003 C2.6, C2.7). Neovim leaves a change out of the history only
-- when 'undolevels' is -1, and then clears the whole history at that
-- change. So the history is written to an undo file first and read back
-- after: :rundo accepts a file only for the text it was written for, so
-- the file's text hash and line count are replaced by those of a second
-- file written for the new text.
local ux_stats = require("ado.nvim.ux_stats")

local M = {}

-- The undo file starts with a 9-byte magic number and a 2-byte version,
-- then the text's SHA-256 hash (32 bytes) and its line count (4 bytes).
local HASH_AT, HASH_LEN = 11, 36

local warned = false

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

-- Runs change(), which edits buf, outside the undo history. The caller
-- keeps the modified flag and 'modifiable'. Returns true when the history
-- was kept, false when it had to be cleared.
function M.run(buf, change)
  local started = vim.uv.hrtime()
  local kept = vim.api.nvim_buf_call(buf, function()
    local undolevels = vim.bo[buf].undolevels
    local function plain()
      vim.bo[buf].undolevels = -1
      change()
      vim.bo[buf].undolevels = undolevels
    end
    if vim.fn.undotree().seq_last == 0 then
      plain()
      return true
    end
    local cursors = {}
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do cursors[win] = vim.api.nvim_win_get_cursor(win) end
    local before, after = vim.fn.tempname(), vim.fn.tempname()
    local ok = pcall(vim.cmd, "silent wundo! " .. vim.fn.fnameescape(before))
    plain()
    if ok then
      -- Changes that leave the new text as it is, so that :wundo has
      -- something to write: a space added and removed at the end of the
      -- last line, which moves no extmark (labels, signs).
      local last = vim.api.nvim_buf_line_count(buf) - 1
      local len = #vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
      vim.api.nvim_buf_set_text(buf, last, len, last, len, { " " })
      vim.api.nvim_buf_set_text(buf, last, len, last, len + 1, { "" })
      ok = pcall(vim.cmd, "silent wundo! " .. vim.fn.fnameescape(after))
    end
    if ok then
      local old, new = read(before), read(after)
      ok = old ~= nil and new ~= nil and #old > HASH_AT + HASH_LEN and #new > HASH_AT + HASH_LEN
        and old:sub(1, HASH_AT) == new:sub(1, HASH_AT)
        and write(before, old:sub(1, HASH_AT) .. new:sub(HASH_AT + 1, HASH_AT + HASH_LEN)
          .. old:sub(HASH_AT + HASH_LEN + 1))
    end
    if ok then ok = pcall(vim.cmd, "silent rundo " .. vim.fn.fnameescape(before)) end
    os.remove(before)
    os.remove(after)
    for win, cur in pairs(cursors) do pcall(vim.api.nvim_win_set_cursor, win, cur) end
    return ok
  end)
  ux_stats.record("quiet_write", (vim.uv.hrtime() - started) / 1e6)
  if not kept then
    ux_stats.count("quiet_write_failed")
    if not warned then
      warned = true
      vim.notify("[ado] could not keep the undo history while writing the details or comments; u cannot"
        .. " undo edits made before this point", vim.log.levels.WARN)
    end
  end
  return kept
end

return M
