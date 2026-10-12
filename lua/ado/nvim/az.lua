-- The az CLI transport (see core/transport.lua for the contract). The only
-- module that shells out to `az`. All calls are async via vim.system;
-- callbacks are scheduled onto the main loop so callers may touch the nvim API
-- freely. Org (and project where required) are threaded per call; we never
-- mutate the user's global `az devops configure` defaults.
local transport = require("ado.core.transport")

local M = {}

-- Map az's noisier failure stderr onto a single actionable line.
local function stderr_error(stderr)
  local s = (stderr or ""):lower()
  if s:find("az login") or s:find("run the login command")
      or s:find("refresh token") or s:find("aadsts") then
    return transport.error("auth", "auth expired - run `az login` (then `az devops login` if prompted)")
  end
  return transport.error("failed", (stderr ~= nil and stderr ~= "") and stderr or "az command failed")
end

-- Each update field has a dedicated flag except System.Tags, which goes
-- through --fields. A list, not a map, so the argv order is fixed.
local UPDATE_FLAGS = {
  { "System.Title", "--title" },
  { "System.State", "--state" },
  { "System.AssignedTo", "--assigned-to" },
  { "System.IterationPath", "--iteration" },
  { "System.Description", "--description" },
}

-- ADO documents a 32,000 character WIQL limit. The open-state condition grows
-- with the number of types and states, so warn well before the limit.
local WIQL_LIMIT = 32000
local WIQL_WARN_LENGTH = 16000

-- Without this projection the types response carries every type's form XML
-- and field list: 1.2 MB on the Example project, against 8.5 KB.
-- The REST API versions each route was verified against on 2026-10-11; both
-- return state categories.
local TYPES_API_VERSION = "7.1"
local TYPE_STATES_API_VERSION = "6.0"

local TYPES_PROJECTION = "value[].{name: name, isDisabled: isDisabled, "
  .. "states: states[].{name: name, category: category}}"

-- opts:
--   org         string                 ADO organisation name
--   system      function|nil           vim.system stand-in, for tests
--   executable  function()->bool|nil   az-on-PATH check, for tests
function M.new(opts)
  local system = opts.system or vim.system
  local executable = opts.executable or function() return vim.fn.executable("az") == 1 end
  local org_args = { "--org", "https://dev.azure.com/" .. opts.org }

  local function finish(cb, err, result)
    vim.schedule(function()
      cb(err, result)
    end)
  end

  -- args: full argv starting with "az"; --org goes after it, then tail.
  -- empty: the result when az prints nothing.
  local function run(args, cb, tail, empty)
    if not executable() then
      finish(cb, transport.error("failed", "az CLI not found"))
      return
    end
    local argv = vim.list_extend({}, args)
    vim.list_extend(argv, org_args)
    vim.list_extend(argv, tail or {})
    system(argv, { text = true }, function(res)
      if res.code ~= 0 then
        finish(cb, stderr_error(res.stderr))
        return
      end
      if empty ~= nil and not (res.stdout or ""):find("%S") then
        finish(cb, nil, empty)
        return
      end
      local ok, decoded = pcall(vim.json.decode, res.stdout or "")
      if not ok then
        finish(cb, transport.error("failed", "failed to parse az output"))
        return
      end
      finish(cb, nil, decoded)
    end)
  end

  local t = {}

  function t.list_projects(_, cb)
    run({ "az", "devops", "project", "list", "--output", "json" }, function(err, data)
      if err then return cb(err) end
      local names = {}
      for _, p in ipairs((data and data.value) or {}) do
        table.insert(names, p.name)
      end
      cb(nil, names)
    end)
  end

  function t.query(params, cb)
    if #params.wiql > WIQL_WARN_LENGTH then
      vim.notify(string.format("[ado] query is %d characters; ADO rejects WIQL over %d",
        #params.wiql, WIQL_LIMIT), vim.log.levels.WARN)
    end
    local args = { "az", "boards", "query", "--wiql", params.wiql, "--output", "json" }
    -- az prints nothing at all for a query with no results (checked 2026-10-12).
    run(args, function(err, data)
      if err then return cb(err) end
      if type(data) == "table" and data.value then data = data.value end
      cb(nil, data or {})
    end, params.project and { "--project", params.project } or nil, {})
  end

  -- Work items are org-unique, so show/update need no project. show's
  -- default --expand is "all", which also carries relations; "relations"
  -- drops computed fields such as System.AreaLevel1 that no caller reads.
  function t.get_work_item(params, cb)
    local args = { "az", "boards", "work-item", "show", "--id", tostring(params.id) }
    if params.relations then vim.list_extend(args, { "--expand", "relations" }) end
    vim.list_extend(args, { "--output", "json" })
    run(args, cb)
  end

  function t.update_fields(params, cb)
    local args = { "az", "boards", "work-item", "update", "--id", tostring(params.id), "--output", "json" }
    local remaining = {}
    for ref, value in pairs(params.fields) do remaining[ref] = value end
    for _, pair in ipairs(UPDATE_FLAGS) do
      local value = remaining[pair[1]]
      if value then
        vim.list_extend(args, { pair[2], value })
        remaining[pair[1]] = nil
      end
    end
    if remaining["System.Tags"] then
      -- --fields takes space-separated field=value pairs; the value itself holds
      -- semicolons, so it must arrive as one argv element.
      vim.list_extend(args, { "--fields", "System.Tags=" .. remaining["System.Tags"] })
      remaining["System.Tags"] = nil
    end
    local unsupported = vim.tbl_keys(remaining)
    if #unsupported > 0 then
      table.sort(unsupported)
      finish(cb, transport.error("invalid", "az transport cannot update " .. table.concat(unsupported, ", ")))
      return
    end
    run(args, cb)
  end

  function t.add_comment(params, cb)
    run({ "az", "boards", "work-item", "update", "--id", tostring(params.id),
      "--discussion", params.text, "--output", "json" }, cb)
  end

  function t.work_item_types(params, cb)
    if not params.project then
      finish(cb, transport.error("invalid", "a project is required to list work item types"))
      return
    end
    run({ "az", "devops", "invoke",
      "--area", "wit", "--resource", "workitemtypes",
      "--route-parameters", "project=" .. params.project,
      "--api-version", TYPES_API_VERSION, "--query", TYPES_PROJECTION,
      "--output", "json" }, function(err, data)
      if err then return cb(err) end
      cb(nil, data or {})
    end)
  end

  function t.work_item_type_states(params, cb)
    if not params.project then
      finish(cb, transport.error("invalid", "a project is required to list states"))
      return
    end
    run({ "az", "devops", "invoke",
      "--area", "wit", "--resource", "workitemtypestates",
      "--route-parameters", "project=" .. params.project, "type=" .. params.type,
      "--api-version", TYPE_STATES_API_VERSION, "--output", "json" }, function(err, data)
      if err then return cb(err) end
      cb(nil, (data and data.value) or {})
    end)
  end

  -- --path takes only the absolute node form (\Project\Area\...); the
  -- children are one level deep, each with a null children list.
  function t.area_children(params, cb)
    run({ "az", "boards", "area", "project", "list", "--project", params.project,
      "--path", params.path, "--depth", "1", "--output", "json" }, function(err, node)
      if err then return cb(err) end
      cb(nil, (type(node) == "table" and type(node.children) == "table") and node.children or {})
    end)
  end

  return t
end

return M
