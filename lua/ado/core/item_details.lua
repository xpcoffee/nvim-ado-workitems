-- The details of an item buffer (RFC 0003 C3.1): the lines below its
-- `── Details` boundary row, which the presentation layer writes as plain
-- text, never as rows, so the change plan never receives them (C2.1).
local timestamp = require("ado.core.timestamp")

local M = {}

M.INDENT = "    "

local function length(s)
  return #s
end

-- Breaks text into lines no wider than width at spaces. Continuation lines
-- start under the text of the first line, after its indent and any list
-- marker ("-", "*", "+", "1."); a word wider than width stays whole on its
-- own line.
function M.wrap(text, width, measure)
  measure = measure or length
  if not width or width < 1 or measure(text) <= width then return { text } end
  local lead = text:match("^%s*[-*+]%s+") or text:match("^%s*%d+[.)]%s+") or text:match("^%s*")
  local hang = string.rep(" ", #lead)
  local out, current = {}, nil
  for word in text:sub(#lead + 1):gmatch("%S+") do
    if current == nil then
      current = lead .. word
    elseif measure(current) + 1 + measure(word) <= width then
      current = current .. " " .. word
    else
      table.insert(out, current)
      current = hang .. word
    end
  end
  table.insert(out, current or lead)
  return out
end

-- Each line indented, and wrapped to width less the indent.
function M.indented(text_lines, width, measure)
  local out = {}
  for _, l in ipairs(text_lines) do
    if l:match("^%s*$") then
      table.insert(out, "")
    else
      for _, w in ipairs(M.wrap(l, width and width - #M.INDENT or nil, measure)) do
        table.insert(out, M.INDENT .. w)
      end
    end
  end
  return out
end

local function blank(text_lines)
  for _, l in ipairs(text_lines or {}) do
    if l:match("%S") then return false end
  end
  return true
end

-- "2026-10-15 14:02", by opts.format_time (epoch -> text; UTC by default),
-- or the text as ADO sent it when it does not parse.
function M.time(iso, format_time)
  local epoch = timestamp.parse(iso)
  if not epoch then return iso or "" end
  return (format_time or timestamp.utc_minute)(epoch)
end

-- The details lines for item, with description the markdown lines of its
-- description (nil or blank when it has none). opts: format_time, width
-- (the window's text width, for wrapping), measure (display width).
-- Returns the lines and the range of the description's lines in them,
-- { first, last } (1-based), which covers the "description:" line too.
function M.lines(item, description, opts)
  opts = opts or {}
  local out = {
    string.format("%schanged:   %s · rev %s", M.INDENT, M.time(item.changed_at, opts.format_time), tostring(item.rev)),
  }
  local first = #out + 1
  if blank(description) then
    table.insert(out, M.INDENT .. "description: (none)")
  else
    table.insert(out, M.INDENT .. "description:")
    for _, l in ipairs(M.indented(description, opts.width, opts.measure)) do table.insert(out, l) end
  end
  return out, { first = first, last = #out }
end

return M
