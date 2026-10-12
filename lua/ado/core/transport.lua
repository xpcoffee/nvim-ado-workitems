-- The transport contract: the asynchronous operations through which the core
-- reaches Azure DevOps (ADO). The presentation layer supplies the az CLI
-- transport (nvim/az.lua); tests supply tests/support/fake_transport.lua.
--
-- Every operation is transport.<op>(params, cb). params is always a table ({}
-- when an operation takes none), and cb(err, result) runs exactly once. It may
-- run synchronously or later, so callers must not rely on code after the call
-- running before the callback: the fake in its default sync mode calls back
-- before returning, and only the az transport guarantees delivery on the
-- Neovim main loop. err is nil on success, else
-- { kind = <one of KINDS>, message = string }. Results are ADO REST shapes
-- ({ id, rev, fields, relations }); core/workitem.lua normalises them.
local M = {}

-- work_item_type_states is the per-type fallback for a type that
-- work_item_types lists without state categories (core/types.lua).
M.OPERATIONS = {
  "list_projects",         -- {}                       -> { name... }
  "query",                 -- { wiql, spec, project }  -> { raw item... }
  "get_work_item",         -- { id, relations }        -> raw item; relations = true asks for its links
  "update_fields",         -- { id, fields = { [ref] = value } } -> raw item
  "add_comment",           -- { id, text }             -> raw item
  "work_item_types",       -- { project }              -> { { name, isDisabled, states = { { name, category }... } }... }
  "work_item_type_states", -- { type, project }        -> { { name, category }... }
  -- path is the classification node form, \Project\Area\Team (core/area_path.lua)
  "area_children",         -- { project, path }        -> { { name, path, hasChildren }... }, one level
}

-- Operations that change ADO, including those later phases add.
M.WRITES = {
  update_fields = true,
  add_comment = true,
  add_link = true,
  remove_link = true,
  create_work_item = true,
}

M.KINDS = { auth = true, not_found = true, conflict = true, invalid = true, failed = true }

function M.error(kind, message, extra)
  assert(M.KINDS[kind], "unknown transport error kind: " .. tostring(kind))
  local err = { kind = kind, message = message }
  for k, v in pairs(extra or {}) do err[k] = v end
  return err
end

-- Raises when an operation is missing, so a bad transport fails at session
-- creation instead of on first use.
function M.validate(t)
  if type(t) ~= "table" then error("transport must be a table", 2) end
  local missing = {}
  for _, op in ipairs(M.OPERATIONS) do
    if type(t[op]) ~= "function" then table.insert(missing, op) end
  end
  if #missing > 0 then
    error("transport is missing operations: " .. table.concat(missing, ", "), 2)
  end
  return t
end

return M
