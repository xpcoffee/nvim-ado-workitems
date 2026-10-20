-- The az CLI gateway (see core/gateway.lua for the contract). The only
-- module that shells out to `az`. All calls are async via vim.system;
-- callbacks are scheduled onto the main loop so callers may touch the nvim API
-- freely. Org (and project where required) are threaded per call; we never
-- mutate the user's global `az devops configure` defaults.
local gateway = require("ado.core.gateway")
local urls = require("ado.core.urls")

local M = {}

-- Map az's noisier failure stderr onto a single actionable line.
local function stderr_error(stderr)
  local s = (stderr or ""):lower()
  if s:find("az login") or s:find("run the login command")
      or s:find("refresh token") or s:find("aadsts") then
    return gateway.error("auth", "auth expired - run `az login` (then `az devops login` if prompted)")
  end
  return gateway.error("failed", (stderr ~= nil and stderr ~= "") and stderr or "az command failed")
end

-- A patch whose test op fails gets HTTP 412 with this type and writes
-- nothing (checked 2026-10-12); the test ops check /rev and the relations
-- a patch removes. The result is ADO's message, for example "VS403351:
-- Test Operation for path /rev failed, value 2 was not equal to test value
-- 1.", or nil for any other failure.
local function test_failure(stderr)
  local s = tostring(stderr)
  if not s:find("TestPatchOperationFailedException", 1, true) then return nil end
  return s:match('"message":"(.-)","') or s
end

-- ADO documents a 32,000 character WIQL limit. The open-state condition grows
-- with the number of types and states, so warn well before the limit.
local WIQL_LIMIT = 32000
local WIQL_WARN_LENGTH = 16000

-- Without this projection the types response carries every type's form XML
-- and field list: 1.2 MB on the Example project, against 11.4 KB with
-- the colours (8.5 KB without them; measured 2026-10-13).
-- The REST API versions each route was verified against on 2026-10-11; both
-- return state categories.
local TYPES_API_VERSION = "7.1"
local TYPE_STATES_API_VERSION = "6.0"

-- The Azure DevOps application's resource ID, which az rest needs to fetch
-- a token for a URL it does not recognise.
local ADO_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"
local IDENTITY_API_VERSION = "7.1-preview.1"
-- The comments route has no released version: "7.1" fails, and
-- 7.0-preview.3 to 7.2-preview.4 work (checked 2026-10-16, RFC 0003).
local COMMENTS_API_VERSION = "7.1-preview.4"
local WORK_ITEMS_API_VERSION = "7.1"
-- Resolving needs only "none", "one" or "several", so a few results do.
local IDENTITY_MAX = 10

local TYPES_PROJECTION = "value[].{name: name, isDisabled: isDisabled, color: color, "
  .. "states: states[].{name: name, category: category, color: color}}"

-- opts:
--   org         string                 ADO organisation name
--   system      function|nil           vim.system stand-in, for tests
--   executable  function()->bool|nil   az-on-PATH check, for tests
function M.new(opts)
  local system = opts.system or vim.system
  local executable = opts.executable or function() return vim.fn.executable("az") == 1 end
  local base_url = "https://dev.azure.com/" .. opts.org
  local org_args = { "--org", base_url }

  local function finish(cb, err, result)
    vim.schedule(function()
      cb(err, result)
    end)
  end

  -- args: full argv starting with "az"; --org goes after it, then tail.
  -- empty: the result when az prints nothing.
  local function exec(argv, cb, empty)
    if not executable() then
      finish(cb, gateway.error("failed", "az CLI not found"))
      return
    end
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
        finish(cb, gateway.error("failed", "failed to parse az output"))
        return
      end
      finish(cb, nil, decoded)
    end)
  end

  local function run(args, cb, tail, empty)
    local argv = vim.list_extend({}, args)
    vim.list_extend(argv, org_args)
    vim.list_extend(argv, tail or {})
    exec(argv, cb, empty)
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

  -- Work items are org-unique, so show and the patch route need no project. show's
  -- default --expand is "all", which also carries relations; "relations"
  -- drops computed fields such as System.AreaLevel1 that no caller reads.
  function t.get_work_item(params, cb)
    local args = { "az", "boards", "work-item", "show", "--id", tostring(params.id) }
    if params.relations then vim.list_extend(args, { "--expand", "relations" }) end
    vim.list_extend(args, { "--output", "json" })
    run(args, cb)
  end

  -- Writes go through az rest, which calls ADO's REST API directly with an
  -- ADO token and takes the organisation in the URL. az boards work-item
  -- update cannot send a patch with a test op, and merges tags rather than
  -- replacing them; az devops invoke routes the workitems resource to the
  -- create URL (both checked 2026-10-12).
  local function rest_patch(method, url, patch, cb)
    exec({ "az", "rest", "--method", method, "--url", url, "--resource", ADO_RESOURCE,
      "--headers", "Content-Type=application/json-patch+json", "--body", vim.json.encode(patch),
      "--output", "json" }, cb)
  end

  local function item_url(id)
    return string.format("%s/_apis/wit/workitems/%d?api-version=%s", base_url, id, WORK_ITEMS_API_VERSION)
  end

  function t.patch_work_item(params, cb)
    rest_patch("patch", item_url(params.id), params.patch, function(err, raw)
      local failed_test = err and test_failure(err.message)
      if failed_test then return cb(gateway.error("conflict", failed_test)) end
      cb(err, raw)
    end)
  end

  function t.create_work_item(params, cb)
    if not params.project then
      finish(cb, gateway.error("invalid", "a project is required to create a work item"))
      return
    end
    rest_patch("post", string.format("%s/%s/_apis/wit/workitems/$%s?api-version=%s", base_url,
      urls.encode(params.project), urls.encode(params.type), WORK_ITEMS_API_VERSION), params.patch, cb)
  end

  function t.add_comment(params, cb)
    run({ "az", "boards", "work-item", "update", "--id", tostring(params.id),
      "--discussion", params.text, "--output", "json" }, cb)
  end

  -- The comments route needs the project in the URL. The response's
  -- nextPage URL drops `order`, so each page's URL is built here; the
  -- token (a timestamp) is encoded once.
  function t.list_comments(params, cb)
    if not params.project or params.project == "" then
      finish(cb, gateway.error("invalid", "a project is required to list comments"))
      return
    end
    local url = string.format("%s/%s/_apis/wit/workItems/%d/comments?api-version=%s&$top=%d&order=desc",
      base_url, urls.encode(params.project), params.id, COMMENTS_API_VERSION, params.top or 5)
    if params.token then url = url .. "&continuationToken=" .. urls.encode(params.token) end
    exec({ "az", "rest", "--method", "get", "--url", url, "--resource", ADO_RESOURCE, "--output", "json" },
      function(err, data)
        if err then return cb(err) end
        if type(data) ~= "table" then return cb(gateway.error("failed", "unexpected comments response")) end
        local token = data.continuationToken
        cb(nil, { comments = type(data.comments) == "table" and data.comments or {},
          total = tonumber(data.totalCount), token = type(token) == "string" and token ~= "" and token or nil })
      end)
  end

  function t.work_item_types(params, cb)
    if not params.project then
      finish(cb, gateway.error("invalid", "a project is required to list work item types"))
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
      finish(cb, gateway.error("invalid", "a project is required to list states"))
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

  -- az devops invoke cannot reach IdentityPicker: it looks areas up in the
  -- organisation's ResourceAreas, which does not list it (checked
  -- 2026-10-12). az rest calls the route directly with an ADO token. The
  -- "ims" scope searches identities known to the organisation, by prefix of
  -- name or email; the IMS identities route matches whole names only.
  function t.resolve_identity(params, cb)
    local body = vim.json.encode({ query = params.text, identityTypes = { "user" }, operationScopes = { "ims" },
      options = { MinResults = IDENTITY_MAX, MaxResults = IDENTITY_MAX },
      properties = { "DisplayName", "SignInAddress", "Mail", "Active" } })
    exec({ "az", "rest", "--method", "post", "--url", base_url .. "/_apis/IdentityPicker/Identities?api-version="
      .. IDENTITY_API_VERSION, "--resource", ADO_RESOURCE, "--headers", "Content-Type=application/json",
      "--body", body, "--output", "json" }, function(err, data)
      if err then return cb(err) end
      local out = {}
      local result = type(data) == "table" and type(data.results) == "table" and data.results[1] or {}
      for _, ident in ipairs(type(result.identities) == "table" and result.identities or {}) do
        local function str(v) return type(v) == "string" and v or nil end
        if ident.active ~= false then
          table.insert(out, { display_name = str(ident.displayName) or "", unique_name = str(ident.signInAddress) or "",
            mail = str(ident.mail), id = str(ident.localId) })
        end
      end
      cb(nil, out)
    end)
  end

  return t
end

return M
