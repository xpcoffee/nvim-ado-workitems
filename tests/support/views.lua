-- Helpers for the presentation specs of the views: a fresh editor, session
-- and layout on the fake gateway per test, keys, and row lookup by text.
-- Uses vim, so only tests/nvim specs load it.
local Fake = require("tests.support.fake_gateway")
local lines = require("ado.nvim.lines")
local seed = require("tests.fixtures.seed")

local M = {}

local executable = vim.fn.executable

-- opts: seed (default tests/fixtures/seed.lua), and any setup() option.
function M.fresh(opts)
  opts = opts or {}
  vim.o.columns, vim.o.lines = 200, 50
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then pcall(vim.api.nvim_win_close, w, true) end
  end
  vim.cmd("silent! only")
  -- Headless Neovim keeps the first window at 80 columns after 'columns'
  -- grows, until a split rebuilds the layout; without this, a spec run
  -- first (ORDER=shuffle) fits its rows to 80 columns.
  vim.cmd("silent! vsplit")
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
  local fake = Fake.new(opts.seed or seed)
  local types = {}
  for _, t in ipairs((opts.seed or seed).types) do table.insert(types, t.name) end
  local c = { gateway = fake, org = "test-org", project = "P", projects = { { name = "P", types = types } },
    write_guard = false,
    area_paths = { "P/Team" }, area_filters = { state = "open" },
    link_types = { "System.LinkTypes.Hierarchy", "System.LinkTypes.Related" } }
  for k, v in pairs(opts) do if k ~= "seed" then c[k] = v end end
  require("ado.config").reset()
  require("ado.config").setup(c)
  require("ado.nvim.session").reset()
  for _, m in ipairs({ "ado.nvim.area_view", "ado.nvim.query_view", "ado.nvim.item_view", "ado.nvim.layout",
    "ado.nvim.save" }) do
    package.loaded[m] = nil
  end
  vim.fn.executable = function(name)
    if name == "pandoc" then return 0 end
    return executable(name)
  end
  local env = { fake = fake, notes = {}, echoes = {}, urls = {} }
  vim.notify = function(msg, level) table.insert(env.notes, { msg = msg, level = level }) end
  require("ado.nvim.progress").echo = function(msg) table.insert(env.echoes, msg) end
  vim.ui.open = function(url) table.insert(env.urls, url) end
  env.area_view = require("ado.nvim.area_view")
  env.query_view = require("ado.nvim.query_view")
  env.item_view = require("ado.nvim.item_view")
  env.layout = require("ado.nvim.layout")
  return env
end

-- Stands in for vim.notify as Neovim defines it, which adds each message
-- to :messages, for specs that count what a user would find there.
function M.history_notify(msg, level)
  vim.api.nvim_echo({ { msg, (level or 0) >= vim.log.levels.WARN and "WarningMsg" or nil } }, true, {})
end

-- The real progress.echo, which fresh() replaces with a recorder.
function M.real_echo()
  return loadfile(vim.api.nvim_get_runtime_file("lua/ado/nvim/progress.lua", false)[1])().echo
end

function M.key(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

-- The row lines of a view: in an item buffer, up to its `── Details` row.
function M.row_lines(buf)
  return require("ado.nvim.region").lines(buf or 0)
end

-- The lines below an item buffer's `── Details` row: its details and
-- comments.
function M.readonly_lines(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_get_lines(buf, require("ado.nvim.region").last_row(buf), -1, false)
end

-- What each row line shows: a sub-area or area name, a heading, a title, or
-- "<field>: <value>" for the viewed item's field lines. An item buffer's
-- rows end with its "Details" heading.
function M.shown(buf)
  local out = {}
  for _, l in ipairs(M.row_lines(buf)) do
    local p = lines.parse(l)
    if p.kind == "field" then
      table.insert(out, p.field .. ": " .. p.value)
    else
      table.insert(out, p.kind == "area" and p.name or p.kind == "heading" and p.label or p.title)
    end
  end
  return out
end

-- As shown(), without the viewed item's field lines and the closing
-- Details row, so section specs need not repeat them.
function M.parsed(buf)
  local out = {}
  for _, l in ipairs(M.row_lines(buf)) do
    local p = lines.parse(l)
    local reg = p.row_id and require("ado.nvim.registry").get(p.row_id)
    if p.kind ~= "field" and not (reg and reg.row.slot == "boundary") then
      table.insert(out, p.kind == "area" and p.name or p.kind == "heading" and p.label or p.title)
    end
  end
  return out
end

-- Moves the cursor to the first line showing `text`; returns its line.
function M.cursor_to(text)
  for i, shown in ipairs(M.shown(0)) do
    if shown == text then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error("no row " .. text)
end

function M.buf_name(win)
  return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win or 0))
end

return M
