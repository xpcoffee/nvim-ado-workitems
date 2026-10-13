-- The audit log (RFC 0001 R7.4): one JSON line per applied or failed work
-- item request, listing every change in it, so a save can be read back,
-- and reversed by hand, afterwards.
local config = require("ado.config")

local M = {}

function M.path()
  return config.get().audit_log or (vim.fn.stdpath("state") .. "/ado-workitems/audit.log")
end

local function change(op)
  local create = op.kind == "create"
  return {
    op = op.kind,
    field = op.field,
    from = op.from,
    to = op.to,
    state_from = op.state_from,
    state_to = op.state_to,
    rel = op.rel,
    target = op.target,
    copy_of = op.copy_of,
    type = create and op.type or nil,
    title = create and op.title or nil,
    area = create and op.area or nil,
    parent = create and op.parent or nil,
    assignee = create and op.assignee or nil,
    tags = create and op.tags ~= "" and op.tags or nil,
  }
end

-- event: a "request" event from core/apply.lua. Returns false and a
-- message when the log cannot be written; the save goes on regardless.
function M.append(event)
  local req = event.request
  local changes = {}
  for _, op in ipairs(req.ops) do table.insert(changes, change(op)) end
  local entry = {
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    id = req.id,
    created = event.created,
    result = event.result,
    rev = event.rev,
    error = event.error and event.error.message or nil,
    changes = changes,
  }
  local path = M.path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "a")
  if not f then return false, err end
  f:write(vim.json.encode(entry), "\n")
  f:close()
  return true
end

return M
