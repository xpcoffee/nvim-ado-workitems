-- Resolved configuration for the ADO work-item tooling. Session state (the
-- chosen project, the type catalog) lives in core/session.lua.
local M = {}

local function defaults()
  return {
    -- The ADO organisation, as in https://dev.azure.com/<org>. Required.
    org = os.getenv("ADO_ORG"),
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
    -- The type a new line gets when its type column is empty (RFC 0001
    -- R5.18): one for area views, one for an item view's children.
    default_types = { area = "Task", children = "Task" },
    -- State categories that count as open in every list (RFC 0002 R1.3).
    open_categories = { "Proposed", "InProgress" },
    -- Limits writes to one area and its sub-areas (core/write_guard.lua):
    -- { area = "Project\\Area", deny_types = { ... }, title_prefix = "..." }.
    -- Without an area every write is refused; false turns the guard off.
    write_guard = {},
    -- File the audit log appends one JSON line to per saved change (RFC 0001
    -- R7.4); nil means stdpath("state") .. "/ado-workitems/audit.log".
    audit_log = nil,
    -- Replaces the az gateway; tests pass the fake gateway here.
    gateway = nil,
    -- The views' look (plan 0002). icons: the state dot and the sign
    -- column's markers for a changed and a new row, each one column wide,
    -- for example Nerd Font glyphs; a missing key keeps its default.
    -- type_letters: the letter a type shows as in a narrow window, by type
    -- name, for example { ["Test Case"] = "C" }; otherwise the first
    -- letter of the name's last word.
    ui = { icons = { state = "●", changed = "~", new = "+" }, type_letters = {} },
  }
end

local config = defaults()
local warned_transport = false

-- `transport` is the name gateway had before v0.9.0, kept as a deprecated
-- alias; gateway wins when both are passed.
local function rename_transport(opts)
  if opts.transport == nil then return opts end
  if not warned_transport then
    warned_transport = true
    local msg = opts.gateway ~= nil
      and "[ado] setup(): `transport` is deprecated and ignored because `gateway` is also set; remove `transport`"
      or "[ado] setup(): `transport` is deprecated; pass `gateway` instead"
    vim.notify(msg, vim.log.levels.WARN)
  end
  opts = vim.tbl_extend("force", {}, opts)
  if opts.gateway == nil then opts.gateway = opts.transport end
  opts.transport = nil
  return opts
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, rename_transport(opts or {}))
end

function M.get()
  return config
end

-- Back to the defaults, so a later setup() starts from them.
function M.reset()
  config = defaults()
  warned_transport = false
end

return M
