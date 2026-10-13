-- Browser URLs for ADO's web UI. Building one needs no transport call.
local M = {}

-- Measured 2026-10-12 against dev.azure.com: a query URL of 3,053
-- characters loads and one of 3,061 gets HTTP 404.
M.MAX_QUERY_URL = 3000

-- Percent-encodes everything outside RFC 3986's unreserved characters.
function M.encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local encode = M.encode

-- A work item's page; work item IDs are unique in the organisation.
function M.item(org, id)
  return string.format("https://dev.azure.com/%s/_workitems/edit/%s", org, tostring(id))
end

-- A work item's REST URL, the form a relation's url takes.
function M.work_item_api(org, id)
  return string.format("https://dev.azure.com/%s/_apis/wit/workItems/%s", org, tostring(id))
end

-- The web UI's query page, running `wiql` in `project`.
function M.query(org, project, wiql)
  return string.format("https://dev.azure.com/%s/%s/_queries/query/?wiql=%s",
    encode(org), encode(project), encode(wiql))
end

return M
