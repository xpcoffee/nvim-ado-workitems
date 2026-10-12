-- The telescope pickers on the fake transport. Telescope is stubbed, so the
-- spec checks what the plugin hands it: titles, items and the <C-a> toggle.
local Fake = require("tests.support.fake_transport")
local seed = require("tests.fixtures.seed")

local opened

local function stub_telescope()
  opened = {}
  package.loaded["ado.nvim.picker"] = nil
  package.loaded["telescope.pickers"] = {
    new = function(_, spec)
      return {
        find = function()
          local maps = {}
          spec.attach_mappings(0, function(_, lhs, fn) maps[lhs] = fn end)
          table.insert(opened, { title = spec.prompt_title, results = spec.finder.results, maps = maps })
        end,
      }
    end,
  }
  package.loaded["telescope.finders"] = {
    new_table = function(o) return { results = o.results } end,
  }
  package.loaded["telescope.config"] = { values = { generic_sorter = function() return {} end } }
  package.loaded["telescope.actions"] = {
    select_default = { replace = function() end },
    close = function() end,
  }
  package.loaded["telescope.actions.state"] = { get_selected_entry = function() end }
  package.loaded["telescope.previewers"] = { new_buffer_previewer = function() return {} end }
end

local function fresh(items)
  local data = {}
  for k, v in pairs(seed) do data[k] = v end
  data.items = items or seed.items
  local fake = Fake.new(data)
  require("ado.config").setup({ transport = fake, org = "test-org", project = "P", projects = false,
    write_guard = false })
  require("ado.nvim.session").reset()
  vim.notify = function() end
  stub_telescope()
  return require("ado.nvim.picker"), fake
end

local function ids(items)
  local out = {}
  for _, it in ipairs(items) do table.insert(out, it.id) end
  table.sort(out)
  return out
end

local function answer(text)
  vim.ui.input = function(_, on_confirm) on_confirm(text) end
end

local SEARCH_ITEMS = {
  { id = 1, type = "Task", title = "Login open", state = "Doing", area = "P\\Team" },
  { id = 2, type = "Task", title = "Login done", state = "Done", area = "P\\Team" },
}

test("my work items lists only open items", function()
  local picker = fresh()
  picker.my_items()
  eq(#opened, 1)
  eq(opened[1].title, "My work items")
  eq(ids(opened[1].results), { 100, 101, 103, 112 })
  eq(opened[1].maps["<C-a>"], nil)
end)

test("search shows open items; <C-a> re-runs it in every state and back", function()
  local picker, fake = fresh(SEARCH_ITEMS)
  answer("login")
  picker.search()
  eq(opened[1].title, "Search (open, <C-a> toggles): login")
  eq(ids(opened[1].results), { 1 })
  opened[1].maps["<C-a>"]()
  eq(opened[2].title, "Search (all states, <C-a> toggles): login")
  eq(ids(opened[2].results), { 1, 2 })
  opened[2].maps["<C-a>"]()
  eq(ids(opened[3].results), { 1 })
  eq(#fake.calls, 4, "one catalog load and three queries")
end)

test("search with all_states starts in every state without loading the catalog", function()
  local picker, fake = fresh(SEARCH_ITEMS)
  answer("login")
  picker.search({ all_states = true })
  eq(ids(opened[1].results), { 1, 2 })
  eq(#fake.calls, 1)
  eq(fake.calls[1].op, "query")
end)

test("a search with only closed matches opens an empty picker so <C-a> can widen it", function()
  local picker = fresh(SEARCH_ITEMS)
  answer("done")
  picker.search()
  eq(opened[1].results, {})
  opened[1].maps["<C-a>"]()
  eq(ids(opened[2].results), { 2 })
end)
