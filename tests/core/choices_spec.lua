-- The values a type or state cell may take (plan 0002 UX3.1 to UX3.3).
local choices = require("ado.core.choices")
local seed = require("tests.fixtures.seed")
local types = require("ado.core.types")

local catalog = types.new(seed.types)
local CONFIGURED = { "Task", "User Story", "Bug" }

local function words(items)
  local out = {}
  for _, it in ipairs(items or {}) do table.insert(out, it.word) end
  return out
end

local function lookup(configured)
  return {
    catalog = function(project) return project == "P" and catalog or nil end,
    types = function(project) return configured and configured[project] end,
  }
end

local function cell(column, fields)
  local c = { column = column, project = "P" }
  for k, v in pairs(fields or {}) do c[k] = v end
  return c
end

test("UX3.1 a state cell offers the states of the row's type, with category and colour", function()
  local items = choices.for_cell("state", { project = "P", type = "Bug", snapshot_type = "Bug" }, catalog, CONFIGURED)
  eq(words(items), { "New", "Active", "Resolved", "Closed" })
  eq(items[2].menu, "InProgress")
  eq(items[2].color, "007acc")
end)

test("UX3.1 a state cell follows a type typed on the line when the save would change to it", function()
  local items = choices.for_cell("state", { project = "P", type = "task", snapshot_type = "Bug" }, catalog, CONFIGURED)
  eq(words(items), { "To Do", "Doing", "Done", "Discarded" })
end)

test("UX3.1 a state cell falls back to the loaded type when the typed one would not be saved", function()
  local not_in_catalog = choices.for_cell("state", { project = "P", type = "Epic", snapshot_type = "Bug" }, catalog,
    { "Task", "Bug", "Epic" })
  eq(words(not_in_catalog), { "New", "Active", "Resolved", "Closed" })
  local not_configured = choices.for_cell("state", { project = "P", type = "Issue", snapshot_type = "Bug" }, catalog,
    CONFIGURED)
  eq(words(not_configured), { "New", "Active", "Resolved", "Closed" }, "the save keeps the type, so the Bug's states")
  local no_types = choices.for_cell("state", { project = "P", type = "Task", snapshot_type = "Bug" }, catalog, nil)
  eq(words(no_types), { "New", "Active", "Resolved", "Closed" })
end)

test("UX3.1 a new line's state cell offers nothing, with the save's reason", function()
  local items, reason = choices.for_cell("state", { project = "P", type = "Task", new = true }, catalog, CONFIGURED)
  eq(items, nil)
  eq(reason.kind, "new_state")
  eq(reason.message, choices.NEW_STATE)
end)

test("UX3.1 a type cell offers the project's configured types the catalog has", function()
  local items = choices.for_cell("type", { project = "P", type = "Task", snapshot_type = "Task", state = "To Do" },
    catalog, { "Task", "Bug", "Epic" })
  eq(words(items), { "Task", "Bug" }, "Epic is not in the catalog, so the save could not check its states")
  eq(items[1].color, "a4880a")
  eq(items[1].menu, "")
  eq(items[2].menu, "no state To Do", "a Bug has no To Do, so the row needs a new state too")
end)

test("UX3.3 a type cell in a project without configured types gives the save's message", function()
  local items, reason = choices.for_cell("type", { project = "P", type = "Task", snapshot_type = "Task" }, catalog, nil)
  eq(items, nil)
  eq(reason.kind, "no_types")
  eq(reason.message, choices.no_types("P", catalog))
  ok(reason.message:find('projects = { { name = "P", types = { ... } } }', 1, true))
end)

test("UX3.4 a cell whose catalog is not loaded asks for it", function()
  local items, reason = choices.for_cells({ cell("state", { type = "Bug", snapshot_type = "Bug", project = "Q" }) },
    lookup({ Q = CONFIGURED }))
  eq(items, nil)
  eq(reason.kind, "no_catalog")
  eq(reason.project, "Q")
end)

test("UX3.2 several state cells offer only the states every row's type has", function()
  local items = choices.for_cells({
    cell("state", { type = "Bug", snapshot_type = "Bug" }),
    cell("state", { type = "User Story", snapshot_type = "User Story" }),
  }, lookup({ P = CONFIGURED }))
  eq(words(items), { "New", "Active", "Resolved", "Closed" })
  eq(items[3].menu, "", "Resolved is InProgress for a Bug and Resolved for a User Story")
  eq(items[1].menu, "Proposed")
end)

test("UX3.2 several state cells whose types share no state say which types", function()
  local items, reason = choices.for_cells({
    cell("state", { type = "Bug", snapshot_type = "Bug" }),
    cell("state", { type = "Task", snapshot_type = "Task" }),
    cell("state", { type = "Bug", snapshot_type = "Bug" }),
  }, lookup({ P = CONFIGURED }))
  eq(items, nil)
  eq(reason.kind, "none_shared")
  eq(reason.message, "the selected rows' types (Bug, Task) have no state in common")
end)

test("UX3.2 a column without a list of values gives a reason", function()
  local items, reason = choices.for_cells({ cell("title") }, lookup({ P = CONFIGURED }))
  eq(items, nil)
  eq(reason.kind, "not_enum")
end)

test("UX3.1 filter keeps the items starting with the typed text, or all of them", function()
  local items = choices.for_cell("state", { project = "P", type = "Bug", snapshot_type = "Bug" }, catalog, CONFIGURED)
  eq(words(choices.filter(items, "re")), { "Resolved" })
  eq(words(choices.filter(items, "  ")), { "New", "Active", "Resolved", "Closed" })
  eq(words(choices.filter(items, "Active")), { "New", "Active", "Resolved", "Closed" },
    "a whole value shows every item, to pick another")
  eq(words(choices.filter(items, "zz")), { "New", "Active", "Resolved", "Closed" })
end)

test("types state_entries lists each state with its category and colour", function()
  eq(catalog:state_entries("task")[3], { name = "Done", category = "Completed", color = "339933" })
  eq(catalog:state_entries("Issue")[1], { name = "To Do", category = "Proposed" })
  eq(catalog:state_entries("Epic"), nil)
end)

-- Every value offered for a loaded row, saved alone, plans with no
-- rejection: the menus never offer what the save refuses.
test("UX3.1 every offered type and state of a row is one the save accepts", function()
  local records = require("tests.support.records")
  local checked = 0
  local function each_row(fn)
    local s = records.new({ projects = { { name = "P", types = { "Task", "User Story", "Bug", "Epic" } } } })
    local v = records.area(s, "P\\Team\\A")
    local lk = { catalog = function(p) return s:cached_catalog(p) end,
      types = function() return { "Task", "User Story", "Bug", "Epic" } end }
    for i, c in ipairs(v.current) do
      if c.kind == "item" and c.row_id then fn(s, v, i, c, lk) end
    end
  end
  local rows = 0
  each_row(function() rows = rows + 1 end)
  for n = 1, rows do
    local states
    each_row(function(s, v, i, c, lk)
      if i ~= n then return end
      local snap = v.snapshot[i]
      states = choices.for_cells({ { column = "state", type = c.type, snapshot_type = snap.type, project = "P" } }, lk)
      ok(states, "a loaded row offers states")
    end)
    for _, st in ipairs(states) do
      each_row(function(s, v, i, c, lk)
        if i ~= n then return end
        c.state = st.word
        eq(records.compute(s, { v }).rejections, {}, "state " .. st.word)
        checked = checked + 1
      end)
    end
    local offered
    each_row(function(s, v, i, c, lk)
      if i ~= n then return end
      offered = choices.for_cells({ { column = "type", type = c.type, state = c.state, snapshot_type = c.type,
        project = "P" } }, lk)
    end)
    for _, t in ipairs(offered) do
      each_row(function(s, v, i, c, lk)
        if i ~= n then return end
        c.type = t.word
        if t.menu ~= "" then
          -- The hint says the row needs a new state: pick the first offered.
          local st = choices.for_cells({ { column = "state", type = c.type, snapshot_type = v.snapshot[i].type,
            project = "P" } }, lk)
          c.state = st[1].word
        end
        eq(records.compute(s, { v }).rejections, {}, "type " .. t.word)
        checked = checked + 1
      end)
    end
  end
  ok(checked > 10, "checked " .. checked)
end)
