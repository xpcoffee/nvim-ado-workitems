-- A clean Neovim configuration for the README's demo recordings:
--   nvim -u scripts/demo/init.lua
-- It boots the plugin on the fake gateway with the invented data in
-- scripts/demo/seed.lua, so a recording never reaches Azure DevOps (ADO)
-- and never starts az. Each call answers after a delay like ADO's, so the
-- loading messages show.
--
-- ADO_DEMO_OPEN opens a view at start: "mine", "area" (Team A) or an item ID.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(root)

local system = vim.system
vim.system = function(cmd, ...)
  if type(cmd) == "table" and cmd[1] == "az" then error("the demo must not call az") end
  return system(cmd, ...)
end

vim.o.termguicolors = true
vim.cmd.colorscheme("habamax")
vim.o.swapfile = false
vim.o.shada = ""
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showcmd = false
vim.o.shortmess = vim.o.shortmess .. "I"

local Fake = require("tests.support.fake_gateway")
local gateway = require("ado.core.gateway")
local seed = dofile(root .. "/scripts/demo/seed.lua")

local fake = Fake.new(seed)
fake.next_id = 1101

-- Milliseconds each operation takes to answer.
local LATENCY = { list_comments = 1200, resolve_identity = 700, patch_work_item = 500, create_work_item = 500 }

local delayed = {}
for _, op in ipairs(gateway.OPERATIONS) do
  delayed[op] = function(params, cb)
    fake[op](params, function(err, result)
      vim.defer_fn(function() cb(err, result) end, LATENCY[op] or 250)
    end)
  end
end

local types = {}
for _, t in ipairs(seed.types) do table.insert(types, t.name) end

require("ado").setup({
  org = seed.org,
  projects = { { name = "Example", types = types } },
  area_paths = { "Example\\Platform\\Team A", "Example\\Platform\\Team B" },
  write_guard = { area = "Example\\Platform" },
  audit_log = vim.fn.tempname(),
  gateway = delayed,
})

local open = os.getenv("ADO_DEMO_OPEN") or ""
vim.schedule(function()
  if open == "mine" then
    require("ado").my_items()
  elseif open == "area" then
    require("ado").area_view("Example\\Platform\\Team A")
  elseif tonumber(open) then
    require("ado").item_view(tonumber(open))
    vim.cmd("silent! only")
  end
end)
