-- Opens a URL in the system browser.
local M = {}

function M.open(url)
  if not url or url == "" then return end
  if vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  end
end

return M
