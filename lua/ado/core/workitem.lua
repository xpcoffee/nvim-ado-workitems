-- Work-item model: normalises raw ADO JSON into the flat item the views use,
-- and maps editable field names to ADO reference names.
local urls = require("ado.core.urls")

local M = {}

M.FIELD_REFS = {
  title = "System.Title",
  state = "System.State",
  assignee = "System.AssignedTo",
  iteration = "System.IterationPath",
  tags = "System.Tags",
  description = "System.Description",
}

-- The fields a view row shows, plus what judges it open (type, state,
-- project) and orders it.
M.ROW_FIELDS = {
  "System.Id", "System.Title", "System.State", "System.WorkItemType",
  "System.AssignedTo", "System.Tags", "System.AreaPath", "System.TeamProject",
  "System.ChangedDate",
}

-- A view row for a normalised item (RFC 0001 R5.17 columns).
function M.row(item)
  return { kind = "item", id = item.id, rev = item.rev, type = item.type, state = item.state,
    assignee = item.assignee_display, tags = item.tags, title = item.title }
end

function M.normalise(raw, org)
  local f = raw.fields or {}
  local assignee = f["System.AssignedTo"]
  local display, unique = "", ""
  if type(assignee) == "table" then
    display = assignee.displayName or ""
    unique = assignee.uniqueName or ""
  end
  local url = raw._links and raw._links.html and raw._links.html.href
  return {
    id = raw.id,
    rev = raw.rev,
    type = f["System.WorkItemType"] or "",
    title = f["System.Title"] or "",
    state = f["System.State"] or "",
    assignee_display = display,
    assignee_unique = unique,
    tags = f["System.Tags"] or "",
    iteration = f["System.IterationPath"] or "",
    area = f["System.AreaPath"] or "",
    project = f["System.TeamProject"] or "",
    changed = (f["System.ChangedDate"] or ""):sub(1, 10),
    description_html = f["System.Description"] or "",
    -- az boards query omits _links, so synthesise the edit URL when absent.
    url = url or urls.item(org, raw.id),
    raw = raw,
  }
end

M.PARENT = "System.LinkTypes.Hierarchy-Reverse"
M.CHILD = "System.LinkTypes.Hierarchy-Forward"

-- The work item links of a raw item fetched with relations:
--   { parent = id | nil, children = { id... }, links = { { rel, name, id }... } }
-- links holds every other link to a work item, in ADO's order; name is the
-- link's display name ("Related"). Relations to anything else (pull
-- requests, attachments, hyperlinks) are left out.
function M.relations(raw)
  local out = { children = {}, links = {} }
  for _, r in ipairs((raw and type(raw.relations) == "table") and raw.relations or {}) do
    local id = type(r.url) == "string" and tonumber(r.url:match("/_apis/wit/workItems/(%d+)$"))
    if id then
      if r.rel == M.PARENT then
        out.parent = id
      elseif r.rel == M.CHILD then
        table.insert(out.children, id)
      else
        table.insert(out.links, { rel = r.rel, name = r.attributes and r.attributes.name or r.rel, id = id })
      end
    end
  end
  return out
end

-- { title = "x" } -> { ["System.Title"] = "x" }. Raises on a name not in
-- FIELD_REFS, since a silently dropped edit would look saved.
function M.to_fields(changes)
  local fields = {}
  for name, value in pairs(changes) do
    local ref = M.FIELD_REFS[name]
    if not ref then error("unknown work item field: " .. tostring(name), 2) end
    fields[ref] = value
  end
  return fields
end

return M
