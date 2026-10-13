-- Progress in the command line (RFC 0001 R7.3). Progress is transient, so
-- it stays out of :messages, and each message replaces the last on one
-- line: a message wider than the command line would wait for Enter.
local M = {}

function M.echo(msg)
  local text = ("[ado] " .. msg):gsub("%s*\n%s*", "; ")
  local room = vim.v.echospace
  if room > 1 and vim.fn.strdisplaywidth(text) > room then
    text = vim.fn.strcharpart(text, 0, room - 1) .. "…"
  end
  vim.api.nvim_echo({ { text } }, false, {})
end

return M
