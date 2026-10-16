-- Conversions between the HTML ADO stores descriptions in and the markdown
-- the plugin edits them as, with pandoc. Without pandoc, or when it fails,
-- the text is used as it is. pandoc's "markdown" bundles raw_html, so a
-- real <a href> survives the round trip; gfm would autolink bare emails.
local M = {}

local function pandoc(args, input)
  if vim.fn.executable("pandoc") ~= 1 then return nil end
  local argv = { "pandoc" }
  vim.list_extend(argv, args)
  local res = vim.system(argv, { stdin = input, text = true }):wait()
  if res.code ~= 0 then return nil end
  return ((res.stdout or ""):gsub("\n+$", ""))
end

-- Markdown lines for an HTML description; { "" } when it is empty.
-- Descriptions are small, so a blocking call is not noticeable once
-- pandoc has started.
function M.html_to_md(html)
  if html == nil or html == "" then return { "" } end
  local out = pandoc({ "-f", "html", "-t", "markdown", "--wrap=none" }, html)
  return vim.split(out or html, "\n", { plain = true })
end

function M.md_to_html(lines)
  local md = table.concat(lines, "\n")
  return pandoc({ "-f", "markdown", "-t", "html", "--wrap=none" }, md) or md
end

-- A line pandoc keeps as it is, between comments converted in one call.
local SPLIT = "ADO-COMMENT-SPLIT-7f3a"

-- Plain text lines for each HTML text in htmls, with one pandoc call for
-- all of them that does not block the editor (RFC 0003 C5.2, risk R4).
-- cb(list of line lists, in order) runs on the main loop. Without pandoc,
-- or when it fails, the HTML loses its tags instead (core/comments.lua).
function M.html_to_plain(htmls, cb)
  local plain = require("ado.core.comments").plain
  local function fallback()
    local out = {}
    for i, h in ipairs(htmls) do out[i] = plain(h) end
    cb(out)
  end
  if #htmls == 0 then return cb({}) end
  if vim.fn.executable("pandoc") ~= 1 then return fallback() end
  local parts = {}
  for i, h in ipairs(htmls) do
    if i > 1 then table.insert(parts, "<p>" .. SPLIT .. "</p>") end
    table.insert(parts, h)
  end
  local ok = pcall(vim.system, { "pandoc", "-f", "html", "-t", "plain", "--wrap=none" },
    { stdin = table.concat(parts, "\n"), text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then return fallback() end
        local out, current = {}, {}
        for _, line in ipairs(vim.split((res.stdout or ""):gsub("\n+$", ""), "\n", { plain = true })) do
          if line == SPLIT then
            table.insert(out, current)
            current = {}
          else
            table.insert(current, line)
          end
        end
        table.insert(out, current)
        if #out ~= #htmls then return fallback() end
        for i, l in ipairs(out) do
          while #l > 0 and l[1] == "" do table.remove(l, 1) end
          while #l > 0 and l[#l] == "" do table.remove(l) end
          out[i] = l
        end
        cb(out)
      end)
    end)
  if not ok then fallback() end
end

return M
