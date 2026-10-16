-- The transport contract: the asynchronous operations through which the core
-- reaches Azure DevOps (ADO). The presentation layer supplies the az CLI
-- transport (nvim/az.lua); tests supply tests/support/fake_transport.lua.
--
-- Every operation is transport.<op>(params, cb). params is always a table ({}
-- when an operation takes none); any params may also carry quiet = true,
-- which transports ignore and which tells a wrapper that notifies failures
-- (nvim/session.lua) that the caller reports them. cb(err, result) runs
-- exactly once. It may
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
  "add_comment",           -- { id, text }             -> raw item
  -- one page of an item's comments, newest first; token is the previous
  -- page's, nil for the first; the result's token is nil on the last page.
  -- comments are raw ADO comments ({ id, version, text, format,
  -- createdBy, createdDate, isDeleted... }); a read
  "list_comments",         -- { id, project, top, token } -> { comments, total, token }
  "work_item_types",       -- { project }              -> { { name, isDisabled, states = { { name, category }... } }... }
  "work_item_type_states", -- { type, project }        -> { { name, category }... }
  -- path is the classification node form, \Project\Area\Team (core/area_path.lua)
  "area_children",         -- { project, path }        -> { { name, path, hasChildren }... }, one level
  -- patch is a JSON Patch document (application/json-patch+json) that ADO
  -- applies whole or not at all: { { op, path, value }... }, with op "test"
  -- on /rev, "add" or "replace" on /fields/<ref>, "add" on /relations/-
  -- with value { rel, url }, and "remove" on /relations/<index>. A failed
  -- test op is a "conflict" error and writes nothing.
  "patch_work_item",       -- { id, patch }            -> raw item
  -- patch as for patch_work_item, without test or remove ops
  "create_work_item",      -- { project, type, patch } -> raw item with its new id
  -- identities whose name or email starts with text, as ADO's people picker
  -- finds them; a read
  "resolve_identity",      -- { text }                 -> { { display_name, unique_name, mail, id }... }
}

-- Operations that change ADO, including those later phases add.
M.WRITES = {
  add_comment = true,
  patch_work_item = true,
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
