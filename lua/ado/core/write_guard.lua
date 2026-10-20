-- Wraps a transport so that writes reach ADO only for items in one area path
-- (and its sub-areas) and never for a denied type. Policy and defaults:
-- docs/architecture.md#write-guard. Unrelated to the revision check, the
-- test op on /rev that each patch starts with.
--
-- A refused write never reaches the inner transport. Checks that need the
-- target's area and type read it with get_work_item first; the read and the
-- write are not atomic, and a failed read refuses the write. A patch is
-- checked whole: every op in it, every field it sets, and the item at the
-- other end of every link it adds or removes.
local transport = require("ado.core.transport")
local workitem = require("ado.core.workitem")

local M = {}

local READS = {
  list_projects = true,
  query = true,
  get_work_item = true,
  work_item_type_states = true,
  work_item_types = true,
  query_children = true,
  area_children = true,
  resolve_identity = true,
  list_comments = true,
}

-- Area paths compare case-insensitively, with "/" accepted for "\".
local function normalise_path(path)
  if type(path) ~= "string" then return nil end
  local p = path:gsub("/", "\\"):gsub("^\\+", ""):gsub("\\+$", ""):lower()
  if p == "" then return nil end
  return p
end

local function within(path, area)
  local p = normalise_path(path)
  if not p then return false end
  return p == area or p:sub(1, #area + 1) == area .. "\\"
end

local function refusal(op, reason)
  return transport.error("invalid", "write guard refused " .. op .. ": " .. reason)
end

-- opts: area (required to allow any write), deny_types (default none),
-- title_prefix (optional: writes only to items whose title starts with it,
-- so a test run cannot touch an item it did not create)
function M.wrap(inner, opts)
  local area = normalise_path(opts.area)
  local deny = {}
  for _, t in ipairs(opts.deny_types or {}) do deny[t:lower()] = true end
  local prefix = opts.title_prefix

  local function denied_type(wtype)
    return type(wtype) == "string" and deny[wtype:lower()]
  end

  local function prefixed(title)
    return prefix == nil or (type(title) == "string" and title:sub(1, #prefix) == prefix)
  end

  -- Calls cb(nil, raw) when item `id` may be written, else cb(refusal).
  -- relations = true reads its links too.
  local function check_item(op, id, cb, relations)
    inner.get_work_item({ id = id, relations = relations or nil }, function(err, raw)
      if err then
        return cb(refusal(op, "could not read #" .. tostring(id) .. ": " .. tostring(err.message)))
      end
      local f = raw.fields or {}
      if not within(f["System.AreaPath"], area) then
        return cb(refusal(op, string.format("#%s is in area '%s', outside '%s'",
          tostring(id), tostring(f["System.AreaPath"]), opts.area)))
      end
      if denied_type(f["System.WorkItemType"]) then
        return cb(refusal(op, string.format("#%s is of type %s", tostring(id), f["System.WorkItemType"])))
      end
      if not prefixed(f["System.Title"]) then
        return cb(refusal(op, string.format("#%s's title does not start with '%s'", tostring(id), prefix)))
      end
      cb(nil, raw)
    end, relations)
  end

  local function check_items(op, ids, cb)
    local i = 0
    local function next_id(err)
      if err then return cb(err) end
      i = i + 1
      if i > #ids then return cb(nil) end
      check_item(op, ids[i], next_id)
    end
    next_id(nil)
  end

  -- The refusal for field values, or nil: a new type, title or area must
  -- itself be allowed.
  local function field_refusal(op, fields)
    if denied_type(fields["System.WorkItemType"]) then
      return refusal(op, "changing a type to " .. fields["System.WorkItemType"])
    end
    if fields["System.Title"] ~= nil and not prefixed(fields["System.Title"]) then
      return refusal(op, string.format("the new title does not start with '%s'", prefix))
    end
    local new_area = fields["System.AreaPath"]
    if new_area ~= nil and not within(new_area, area) then
      return refusal(op, string.format("new area '%s' is outside '%s'", tostring(new_area), opts.area))
    end
  end

  -- The fields a patch may set: those the plugin edits. Anything else is
  -- refused, so a field no rule here was written for never reaches ADO.
  local PATCH_FIELDS = {}
  for _, ref in pairs(workitem.FIELD_REFS) do PATCH_FIELDS[ref] = true end

  -- Reads a JSON Patch: { fields = { [ref] = value }, link_targets = { id... },
  -- removals = { index... } }, or nil and the refusal. creating = true allows
  -- no test or remove ops, as a create has neither.
  local function read_patch(op, patch, creating)
    if type(patch) ~= "table" or #patch == 0 then return nil, refusal(op, "the patch is empty") end
    local out = { fields = {}, link_targets = {}, removals = {} }
    for _, p in ipairs(patch) do
      local path = type(p) == "table" and type(p.path) == "string" and p.path or ""
      local ref = path:match("^/fields/(.+)$")
      local index = path:match("^/relations/(%d+)$")
      if p.op == "test" and (path == "/rev" or path:match("^/relations/%d+/url$")) and not creating then
        -- a test op writes nothing
      elseif ref and (p.op == "add" or p.op == "replace") then
        if not PATCH_FIELDS[ref] then return nil, refusal(op, "the guard has no rule for field " .. ref) end
        out.fields[ref] = p.value
      elseif path == "/relations/-" and p.op == "add" then
        local target = type(p.value) == "table" and workitem.relation_target(p.value)
        if not target then return nil, refusal(op, "a relation added must link to a work item") end
        table.insert(out.link_targets, target)
      elseif index and p.op == "remove" and not creating then
        table.insert(out.removals, tonumber(index))
      else
        return nil, refusal(op, string.format("the guard has no rule for '%s %s'", tostring(p.op), path))
      end
    end
    return out
  end

  -- Each check calls back with a refusal or nil; checks on params alone run
  -- before any read.
  local checks = {
    patch_work_item = function(params, cb)
      local op = "patch_work_item"
      local read, refused = read_patch(op, params.patch, false)
      if not read then return cb(refused) end
      refused = field_refusal(op, read.fields)
      if refused then return cb(refused) end
      check_item(op, params.id, function(err, raw)
        if err then return cb(err) end
        local targets = read.link_targets
        local relations = type(raw.relations) == "table" and raw.relations or {}
        for _, i in ipairs(read.removals) do
          local r = relations[i + 1]
          local target = r and workitem.relation_target(r)
          if not target then
            return cb(refusal(op, string.format("relation %d of #%s is not a link to a work item", i,
              tostring(params.id))))
          end
          table.insert(targets, target)
        end
        check_items(op, targets, cb)
      end, true)
    end,
    add_comment = function(params, cb)
      check_items("add_comment", { params.id }, cb)
    end,
    create_work_item = function(params, cb)
      local op = "create_work_item"
      if denied_type(params.type) then
        return cb(refusal(op, "type " .. tostring(params.type)))
      end
      local read, refused = read_patch(op, params.patch, true)
      if not read then return cb(refused) end
      local f = read.fields
      if f["System.WorkItemType"] ~= nil then
        return cb(refusal(op, "a create names its type in the URL, not in a field"))
      end
      if not within(f["System.AreaPath"], area) then
        return cb(refusal(op, string.format("area '%s' is outside '%s'", tostring(f["System.AreaPath"]), opts.area)))
      end
      if not prefixed(f["System.Title"]) then
        return cb(refusal(op, string.format("the title does not start with '%s'", prefix)))
      end
      check_items(op, read.link_targets, cb)
    end,
  }

  local guarded = {}
  for op, fn in pairs(inner) do
    if type(fn) == "function" then
      if READS[op] then
        guarded[op] = fn
      elseif not area then
        guarded[op] = function(_, cb) cb(refusal(op,
          'no allowed area is configured; set write_guard = { area = "Project\\\\Area" } in setup()')) end
      elseif checks[op] then
        guarded[op] = function(params, cb)
          params = params or {}
          checks[op](params, function(refused)
            if refused then return cb(refused) end
            fn(params, cb)
          end)
        end
      else
        -- Fail closed: an operation in neither READS nor checks is refused.
        guarded[op] = function(_, cb) cb(refusal(op, "the guard has no rule for this operation")) end
      end
    end
  end
  return guarded
end

return M
