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

return M
