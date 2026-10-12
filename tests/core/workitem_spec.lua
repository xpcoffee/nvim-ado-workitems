local workitem = require("ado.core.workitem")

local function raw(extra)
  local r = {
    id = 42,
    rev = 3,
    fields = {
      ["System.WorkItemType"] = "Task",
      ["System.Title"] = "Fix login",
      ["System.State"] = "Doing",
      ["System.AssignedTo"] = { displayName = "Me Myself", uniqueName = "me@example.com" },
      ["System.Tags"] = "api; backend",
      ["System.IterationPath"] = "P\\Sprint 1",
      ["System.AreaPath"] = "P\\Team\\A",
      ["System.ChangedDate"] = "2026-10-04T09:00:00.123Z",
      ["System.Description"] = "<p>Body</p>",
    },
  }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

test("normalise flattens fields and keeps the raw item", function()
  local r = raw({ _links = { html = { href = "https://dev.azure.com/o/P/_workitems/edit/42" } } })
  local item = workitem.normalise(r, "o")
  eq(item.id, 42)
  eq(item.rev, 3)
  eq(item.type, "Task")
  eq(item.title, "Fix login")
  eq(item.state, "Doing")
  eq(item.assignee_display, "Me Myself")
  eq(item.assignee_unique, "me@example.com")
  eq(item.tags, "api; backend")
  eq(item.iteration, "P\\Sprint 1")
  eq(item.area, "P\\Team\\A")
  eq(item.changed, "2026-10-04")
  eq(item.description_html, "<p>Body</p>")
  eq(item.url, "https://dev.azure.com/o/P/_workitems/edit/42")
  ok(item.raw == r)
end)

test("normalise without _links builds the edit URL from the org parameter", function()
  eq(workitem.normalise(raw(), "my-org").url, "https://dev.azure.com/my-org/_workitems/edit/42")
end)

test("normalise with a missing assignee and fields gives empty strings", function()
  local item = workitem.normalise({ id = 7, rev = 1, fields = {} }, "o")
  eq(item.assignee_display, "")
  eq(item.assignee_unique, "")
  eq(item.title, "")
  eq(item.tags, "")
  eq(item.changed, "")
end)

test("to_fields maps editable names to reference names", function()
  eq(workitem.to_fields({ title = "T", tags = "a; b", description = "<p/>" }),
    { ["System.Title"] = "T", ["System.Tags"] = "a; b", ["System.Description"] = "<p/>" })
end)

test("to_fields refuses an unknown name", function()
  fails(function() workitem.to_fields({ colour = "red" }) end, "unknown work item field: colour")
end)

local function rel(name, kind, id)
  return { rel = kind, url = "https://dev.azure.com/o/00000000-0000-0000-0000-000000000001/_apis/wit/workItems/" .. id,
    attributes = { isLocked = false, name = name } }
end

test("relations: the parent, children in ADO's order, and other work item links", function()
  local r = raw({ relations = {
    rel("Child", "System.LinkTypes.Hierarchy-Forward", 9),
    rel("Parent", "System.LinkTypes.Hierarchy-Reverse", 1),
    rel("Child", "System.LinkTypes.Hierarchy-Forward", 3),
    rel("Related", "System.LinkTypes.Related", 5),
    { rel = "ArtifactLink", url = "vstfs:///GitHub/PullRequest/x%2f5", attributes = { name = "GitHub Pull Request" } },
    { rel = "AttachedFile", url = "https://dev.azure.com/o/p/_apis/wit/attachments/00000000-0000-0000-0000-000000000002",
      attributes = { name = "a.json" } },
  } })
  eq(workitem.relations(r), {
    parent = 1,
    children = { 9, 3 },
    links = { { rel = "System.LinkTypes.Related", name = "Related", id = 5 } },
  })
end)

test("relations of an item fetched without them are empty", function()
  eq(workitem.relations(raw()), { children = {}, links = {} })
end)
