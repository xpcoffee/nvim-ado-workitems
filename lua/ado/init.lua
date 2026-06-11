-- Public API for the ADO work-item tooling. Sub-modules are required lazily so
-- the first call pulls in only what it needs (telescope, the buffer logic, etc).
local config = require("ado.config")

local M = {}

local did_setup = false

function M.setup(opts)
  if did_setup then return end
  did_setup = true
  if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("[ado] requires neovim 0.10+ (vim.system/vim.ui.open)", vim.log.levels.ERROR)
    return
  end
  config.setup(opts)
  if vim.fn.executable("az") ~= 1 then
    vim.notify("[ado] az CLI not found; work-item actions will no-op", vim.log.levels.WARN)
  end
end

function M.my_items()
  M.setup()
  require("ado.picker").my_items()
end

function M.search()
  M.setup()
  require("ado.picker").search()
end

function M.open(id)
  M.setup()
  require("ado.workitem").open(id)
end

function M.open_prompt()
  M.setup()
  vim.ui.input({ prompt = "Work item ID: " }, function(input)
    if not input or input == "" then return end
    local id = tonumber(input)
    if not id then
      vim.notify("[ado] invalid work item id: " .. input, vim.log.levels.WARN)
      return
    end
    require("ado.workitem").open(id)
  end)
end

return M
