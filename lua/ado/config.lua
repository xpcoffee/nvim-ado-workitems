-- Resolved configuration for the ADO work-item tooling. Holds org/project and
-- session caches (resolved project, per-type valid states).
local M = {}

local config = {
  org = os.getenv("ADO_ORG") or "example-org",
  -- nil until resolved from opts, env, or a first-use project picker.
  project = os.getenv("AZURE_DEVOPS_EXT_DEFAULT_PROJECT"),
  default_query_top = 200,
  description_format = "markdown", -- "markdown" | "html" | "text"
}

local state_cache = {} -- work-item type -> { state names }

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

function M.get()
  return config
end

function M.set_project(project)
  config.project = project
end

function M.cache_states(wtype, states)
  state_cache[wtype] = states
end

function M.get_states(wtype)
  return state_cache[wtype]
end

return M
