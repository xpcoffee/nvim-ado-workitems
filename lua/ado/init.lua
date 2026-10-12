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
  require("ado.nvim.picker").my_items()
end

-- opts.all_states: include items in every state, not only open ones.
function M.search(opts)
  M.setup()
  require("ado.nvim.picker").search(opts)
end

-- Opens the area view on path, or on one picked from config area_paths.
function M.area_view(path)
  M.setup()
  local c = config.get()
  local function open(p)
    local loc = require("ado.core.location").area(p, c.area_filters)
    if not loc.path then
      vim.notify("[ado] not an area path: " .. tostring(p), vim.log.levels.WARN)
      return
    end
    require("ado.nvim.area_view").open(loc)
  end
  if type(path) == "string" and path ~= "" then return open(path) end
  if #(c.area_paths or {}) == 0 then
    vim.notify("[ado] no area_paths configured; set them in setup()", vim.log.levels.WARN)
    return
  end
  vim.ui.select(c.area_paths, { prompt = "Area" }, function(choice)
    if choice then open(choice) end
  end)
end

-- Opens the item view for id, or for an ID typed at a prompt. From a detail
-- buffer the item view opens beside it.
-- Closes the area view, else reopens the last area shown, else asks for
-- an area as area_view() does.
function M.toggle_area_view()
  M.setup()
  if not require("ado.nvim.layout").toggle_area() then M.area_view() end
end

-- Closes the item view, else opens it for the work item in the current
-- detail buffer, else reopens the last item shown, else asks for an ID.
function M.toggle_item_view()
  M.setup()
  local id = vim.api.nvim_buf_get_name(0):match("^ado://(%d+)$")
  if not require("ado.nvim.layout").toggle_item(tonumber(id)) then M.item_view() end
end

function M.item_view(id)
  M.setup()
  local function open(value)
    local loc = require("ado.core.location").item(value)
    if not loc then
      vim.notify("[ado] invalid work item id: " .. tostring(value), vim.log.levels.WARN)
      return
    end
    require("ado.nvim.layout").open_item(loc.id)
  end
  if id ~= nil then return open(id) end
  vim.ui.input({ prompt = "Work item ID: " }, function(input)
    if input and input ~= "" then open(input) end
  end)
end

function M.open(id)
  M.setup()
  require("ado.nvim.detail").open(id)
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
    require("ado.nvim.detail").open(id)
  end)
end

return M
