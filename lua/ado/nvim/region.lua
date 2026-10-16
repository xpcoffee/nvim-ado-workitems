-- The header end of an item buffer (RFC 0003 section 6): the lines above
-- its `── Details` boundary line are rows, and every line from the
-- boundary on is read-only text the plugin wrote. Every module that reads
-- buffer lines as rows reads them through last_row(), so a details or
-- comment line is never re-padded, concealed, marked or planned (C2.5).
-- Buffers without a region (area views, query lists) are rows throughout.
local M = {}

local NS = vim.api.nvim_create_namespace("ado_region")

-- buf -> { mark (extmark ID on the boundary line), prefix (the boundary
-- row's "/<row id> "), readonly = the lines from the boundary on, as the
-- plugin last wrote them }
local regions = {}

local function resolve(buf)
  if buf == nil or buf == 0 then return vim.api.nvim_get_current_buf() end
  return buf
end

-- boundary: the boundary line, 1-based; row_id: its row ID; readonly:
-- the lines from the boundary line to the end of the buffer.
function M.set(buf, boundary, row_id, readonly)
  buf = resolve(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  regions[buf] = {
    mark = vim.api.nvim_buf_set_extmark(buf, NS, boundary - 1, 0, {}),
    prefix = "/" .. row_id .. " ",
    readonly = readonly,
  }
end

-- Updates the read-only text after the plugin rewrote part of it.
function M.set_readonly(buf, readonly)
  buf = resolve(buf)
  local r = regions[buf]
  if r then r.readonly = readonly end
end

function M.clear(buf)
  buf = resolve(buf)
  regions[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1) end
end

function M.has(buf)
  buf = resolve(buf)
  return regions[buf] ~= nil
end

-- The extmark follows the boundary line through edits above it. When the
-- line itself was deleted, the mark sits on the line that followed it, so
-- the header still ends there. A boundary pasted higher up, in the
-- header, ends the header there instead, so nothing below it is read as
-- a row. Returns the header end and whether the line after it is the
-- boundary.
local function locate(buf, r)
  local at = vim.api.nvim_buf_get_extmark_by_id(buf, NS, r.mark, {})[1] + 1
  local above = vim.api.nvim_buf_get_lines(buf, 0, at, false)
  for i, line in ipairs(above) do
    if line:sub(1, #r.prefix) == r.prefix then return i - 1, true end
  end
  return at - 1, false
end

-- The number of lines above the boundary line; nil without a region.
function M.header_end(buf)
  buf = resolve(buf)
  local r = regions[buf]
  if not r then return nil end
  return (locate(buf, r))
end

-- The boundary line (1-based) when it is where the header ends, else nil
-- (it was deleted, or edited so that it no longer starts with its row ID).
function M.boundary(buf)
  buf = resolve(buf)
  local r = regions[buf]
  if not r then return nil end
  local n, found = locate(buf, r)
  return found and n + 1 or nil
end

-- The last line that may be read as a row: the boundary line, or the
-- header's last line when the boundary is gone; the buffer's last line
-- without a region.
function M.last_row(buf)
  buf = resolve(buf)
  local r = regions[buf]
  if not r then return vim.api.nvim_buf_line_count(buf) end
  local n, found = locate(buf, r)
  return found and n + 1 or n
end

-- The lines that may be read as rows.
function M.lines(buf)
  buf = resolve(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, M.last_row(buf), false)
end

-- Whether line lnum (1-based) may be read as a row.
function M.readable(buf, lnum)
  buf = resolve(buf)
  return lnum <= M.last_row(buf)
end

-- The first line (1-based) from the boundary on that differs from what
-- the plugin wrote there, or nil when the read-only text is as written.
function M.readonly_changed(buf)
  buf = resolve(buf)
  local r = regions[buf]
  if not r then return nil end
  local n = locate(buf, r)
  local now = vim.api.nvim_buf_get_lines(buf, n, -1, false)
  for i = 1, math.max(#now, #r.readonly) do
    if now[i] ~= r.readonly[i] then return n + math.min(i, math.max(#now, 1)) end
  end
  return nil
end

-- Leaves Insert mode at once when it starts on the boundary line or below
-- (C2.4): the read-only text cannot be edited, and an edit there would
-- only make :w reject the save.
function M.guard_insert(buf, message)
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    callback = function()
      if not regions[buf] then return end
      local line = vim.api.nvim_win_get_cursor(0)[1]
      if line > (M.header_end(buf) or math.huge) then
        -- :stopinsert in InsertEnter is undone when Insert mode then
        -- starts; an <Esc> put before any typed keys ends it at once.
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "ni", false)
        vim.schedule(function() vim.notify("[ado] " .. message, vim.log.levels.WARN) end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function() regions[buf] = nil end })
end

return M
