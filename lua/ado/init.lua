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
  if not config.get().gateway and vim.fn.executable("az") ~= 1 then
    vim.notify("[ado] az CLI not found; work-item actions will no-op", vim.log.levels.WARN)
  end
end

-- Opens the "mine" query list (RFC 0001 R9): the open work items assigned
-- to the user, in the top window of the view column.
function M.my_items()
  M.setup()
  require("ado.nvim.session").ensure_project(function(ok)
    if ok then require("ado.nvim.query_view").open(require("ado.core.location").query("mine")) end
  end)
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

-- Closes the top window (an area view or a query list), else reopens the
-- list last shown there, else asks for an area as area_view() does.
function M.toggle_area_view()
  M.setup()
  if not require("ado.nvim.layout").toggle_list() then M.area_view() end
end

-- Closes the item window, else reopens the last item shown, else asks for
-- an ID.
function M.toggle_item_view()
  M.setup()
  if not require("ado.nvim.layout").toggle_item() then M.item_view() end
end

-- Opens the item buffer for id, or for an ID typed at a prompt, in the item
-- window.
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

-- Prints how often the views' editing helpers ran and how long they took
-- (plan 0002 UX1.8): counts, last and largest durations. Returns the lines.
function M.ux_stats()
  local lines = require("ado.nvim.ux_stats").lines()
  if #lines == 0 then lines = { "no re-pads yet" } end
  vim.api.nvim_echo({ { "[ado] " .. table.concat(lines, "\n[ado] ") } }, true, {})
  return lines
end

-- Opens the item buffer for id in the item window (RFC 0003 C6.4).
function M.open(id)
  M.item_view(id)
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
    M.item_view(id)
  end)
end

return M
