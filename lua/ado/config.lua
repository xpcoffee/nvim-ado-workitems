-- Resolved configuration for the ADO work-item tooling. Session state (the
-- chosen project, the type catalog) lives in core/session.lua.
local M = {}

local config = {
  org = os.getenv("ADO_ORG") or "example-org",
  -- The projects lists cover, each with the types its rows may be created as
  -- or changed to: { { name = "P", types = { "Task", ... } }... }. When nil,
  -- lists cover the one project below.
  projects = nil,
  -- Used only when projects is nil; nil means a first-use project picker
  -- chooses one for the session.
  project = os.getenv("AZURE_DEVOPS_EXT_DEFAULT_PROJECT"),
  default_query_top = 200,
  description_format = "markdown", -- "markdown" | "html" | "text"
  -- Area paths the area view picker offers, with \ or / between segments.
  area_paths = {},
  -- Default area view filters: state ("open", "all" or a list of names),
  -- assignee (nil, "@Me" or a name), types (a list) and tag.
  area_filters = { state = "open" },
  -- Link types the item view shows (RFC 0001 R8.5). The parent and the
  -- children always show; each other type gets a section, its -Forward and
  -- -Reverse ends apart.
  link_types = { "System.LinkTypes.Hierarchy", "System.LinkTypes.Related" },
  -- State categories that count as open in every list (RFC 0002 R1.3).
  open_categories = { "Proposed", "InProgress" },
  -- { area = "Project\\Area", deny_types = { "Issue" } } limits writes to that
  -- area and its sub-areas (core/write_guard.lua). Off by default.
  write_guard = nil,
  -- Replaces the az transport; tests pass the fake transport here.
  transport = nil,
}

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

function M.get()
  return config
end

return M
