-- Session-wide row IDs. Every row a view displays gets a fresh ID that maps
-- to what the row shows, so two rows for one work item (in two views, or a
-- pasted copy in phase 5) stay distinguishable.
--   entry = { kind = "area" | "item", view = buffer name, row = core row }
local M = {}

local entries = {}
local last = 0

function M.add(entry)
  last = last + 1
  entries[last] = entry
  return last
end

function M.get(id)
  return entries[id]
end

-- Calls fn(entry, id) for every row the views hold now.
function M.each(fn)
  for id, entry in pairs(entries) do fn(entry, id) end
end

function M.release(ids)
  for _, id in ipairs(ids or {}) do entries[id] = nil end
end

return M
