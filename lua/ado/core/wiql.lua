-- Renders a query spec (see core/query.lua) to a WIQL string. Pure: no I/O.
-- Result-set capping happens client-side after the query (az boards query has
-- no --top), so the output never contains TOP.
local M = {}

local function literal(value)
  if type(value) == "table" and value.macro then
    return "@" .. value.macro
  end
  if type(value) == "number" then
    return tostring(value)
  end
  if type(value) == "table" then
    local items = {}
    for _, v in ipairs(value) do table.insert(items, literal(v)) end
    return "(" .. table.concat(items, ", ") .. ")"
  end
  -- Single quotes are doubled to escape them inside a WIQL string literal.
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function condition(cond, nested)
  local group, joiner
  if cond.all then
    group, joiner = cond.all, " AND "
  elseif cond.any then
    group, joiner = cond.any, " OR "
  end
  if not group then
    return string.format("[%s] %s %s", cond.field, cond.op, literal(cond.value))
  end
  local parts = {}
  for _, c in ipairs(group) do
    table.insert(parts, condition(c, true))
  end
  local s = table.concat(parts, joiner)
  if nested and #parts > 1 then s = "(" .. s .. ")" end
  return s
end

function M.render(spec)
  local fields = {}
  for _, f in ipairs(spec.select) do
    table.insert(fields, "[" .. f .. "]")
  end
  local parts = { "SELECT " .. table.concat(fields, ", ") .. " FROM WorkItems" }
  if spec.where then
    table.insert(parts, "WHERE " .. condition(spec.where, false))
  end
  if spec.order_by and #spec.order_by > 0 then
    local order = {}
    for _, o in ipairs(spec.order_by) do
      table.insert(order, "[" .. o.field .. "]" .. (o.desc and " DESC" or ""))
    end
    table.insert(parts, "ORDER BY " .. table.concat(order, ", "))
  end
  return table.concat(parts, " ")
end

return M
