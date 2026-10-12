-- Load progress in the command line (RFC 0001 R7.3). Progress is transient,
-- so it stays out of :messages.
local M = {}

function M.echo(msg)
  vim.api.nvim_echo({ { "[ado] " .. msg } }, false, {})
end

return M
