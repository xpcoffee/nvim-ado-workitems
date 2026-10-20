-- Structured query specs. A spec is data, so the az gateway can send it as
-- WIQL (core/wiql.lua) and the fake gateway can evaluate it directly.
--
--   spec  = { select = { ref... }, where = cond, order_by = { { field = ref, desc = bool }... } }
--   cond  = { field = ref, op = "=" | "<>" | "<" | "CONTAINS WORDS", value = v }
--         | { field = ref, op = "IN", value = { v... } }
--         | { all = { cond... } } | { any = { cond... } }
--   v     = string | number | { macro = "Me" }
--
-- `scope` arguments below are the condition from M.scope: the configured
-- projects and, for open-only lists, each project's open states.
local wiql = require("ado.core.wiql")

local M = {}

-- az boards query only hydrates the fields named in SELECT, so list these
-- explicitly; description is included so the picker preview needs no extra fetch.
M.FIELDS = {
  "System.Id", "System.Title", "System.State", "System.WorkItemType",
  "System.AssignedTo", "System.Tags", "System.IterationPath", "System.AreaPath",
  "System.TeamProject", "System.ChangedDate", "System.Description",
}

local NEWEST_FIRST = { { field = "System.ChangedDate", desc = true } }

local function where(conds, scope)
  if scope and scope.all then
    for _, c in ipairs(scope.all) do table.insert(conds, c) end
  elseif scope then
    table.insert(conds, scope)
  end
  if #conds == 1 then return conds[1] end
  return { all = conds }
end

-- az boards query --project P still searches the whole organisation, so the
-- project condition is what keeps lists to the configured projects.
-- names: project names; opens: nil for every state, else each project's open
-- condition (types.Catalog:open_condition) in the order of names, so an item
-- is judged by its own project's state categories. nil when names is empty.
function M.scope(names, opens)
  if not names or #names == 0 then return nil end
  local conds = { { field = "System.TeamProject", op = "IN", value = names } }
  if opens and #names == 1 then
    table.insert(conds, opens[1])
  elseif opens then
    local per_project = {}
    for i, name in ipairs(names) do
      table.insert(per_project, { all = {
        { field = "System.TeamProject", op = "=", value = name },
        opens[i],
      } })
    end
    table.insert(conds, { any = per_project })
  end
  return { all = conds }
end

-- Items matching every condition in conds and scope, newest first.
-- select: the fields to hydrate, default M.FIELDS.
function M.list(conds, scope, select)
  local all = {}
  for _, c in ipairs(conds) do table.insert(all, c) end
  return { select = select or M.FIELDS, where = where(all, scope), order_by = NEWEST_FIRST }
end

local function is_me(assignee)
  return type(assignee) == "string" and assignee:lower() == "@me"
end

-- The conditions for a location's filters (core/location.lua). open: the
-- open-state condition, used when filters.state is "open", or nil when the
-- caller puts it in the scope instead. It already limits the types, so
-- filters.types adds no condition then.
function M.filter_conditions(f, open)
  local conds = {}
  if f.state == "open" then
    if open then table.insert(conds, open) end
  else
    if type(f.state) == "table" then
      table.insert(conds, { field = "System.State", op = "IN", value = f.state })
    end
    if f.types then
      table.insert(conds, { field = "System.WorkItemType", op = "IN", value = f.types })
    end
  end
  if is_me(f.assignee) then
    table.insert(conds, { field = "System.AssignedTo", op = "=", value = { macro = "Me" } })
  elseif f.assignee then
    table.insert(conds, { field = "System.AssignedTo", op = "=", value = f.assignee })
  end
  if f.tag then
    table.insert(conds, { field = "System.Tags", op = "CONTAINS", value = f.tag })
  end
  return conds
end

function M.my_items(scope)
  return M.list({ { field = "System.AssignedTo", op = "=", value = { macro = "Me" } } }, scope)
end

-- CONTAINS WORDS is word/prefix match over the indexed long-text fields, not
-- substring/fuzzy; recent edits may lag the index.
function M.text_search(text, scope)
  return {
    select = M.FIELDS,
    where = where({ { any = {
      { field = "System.Title", op = "CONTAINS WORDS", value = text },
      { field = "System.Description", op = "CONTAINS WORDS", value = text },
    } } }, scope),
    order_by = NEWEST_FIRST,
  }
end

-- The gateway's query params: both forms, rendered from one spec.
function M.request(spec)
  return { wiql = wiql.render(spec), spec = spec }
end

return M
