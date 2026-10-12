-- Wraps a transport so that, when configured, writes reach ADO only for items
-- in one area path (and its sub-areas) and never for a denied type: the
-- organisation may watch a type, so a test write to one could notify people.
-- Policy and defaults: docs/architecture.md#write-guard. Unrelated to the
-- revision check in Session:update_if_unchanged.
--
-- A refused write never reaches the inner transport. Checks that need the
-- target's area and type read it with get_work_item first; the read and the
-- write are not atomic, and a failed read refuses the write.
local transport = require("ado.core.transport")

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

-- opts: area (required to allow any write), deny_types (default { "Issue" })
function M.wrap(inner, opts)
  local area = normalise_path(opts.area)
  local deny = {}
  for _, t in ipairs(opts.deny_types or { "Issue" }) do deny[t:lower()] = true end

  local function denied_type(wtype)
    return type(wtype) == "string" and deny[wtype:lower()]
  end

  -- Calls cb(nil) when item `id` may be written, else cb(refusal).
  local function check_item(op, id, cb)
    inner.get_work_item({ id = id }, function(err, raw)
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
      cb(nil)
    end)
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

  -- Each check calls back with a refusal or nil; checks on params alone run
  -- before any read.
  local checks = {
    update_fields = function(params, cb)
      local fields = params.fields or {}
      if denied_type(fields["System.WorkItemType"]) then
        return cb(refusal("update_fields", "changing a type to " .. fields["System.WorkItemType"]))
      end
      local new_area = fields["System.AreaPath"]
      if new_area ~= nil and not within(new_area, area) then
        return cb(refusal("update_fields", string.format("new area '%s' is outside '%s'",
          tostring(new_area), opts.area)))
      end
      check_items("update_fields", { params.id }, cb)
    end,
    add_comment = function(params, cb)
      check_items("add_comment", { params.id }, cb)
    end,
    add_link = function(params, cb)
      check_items("add_link", { params.id, params.target }, cb)
    end,
    remove_link = function(params, cb)
      check_items("remove_link", { params.id, params.target }, cb)
    end,
    create_work_item = function(params, cb)
      if denied_type(params.type) then
        return cb(refusal("create_work_item", "type " .. tostring(params.type)))
      end
      if not within(params.area, area) then
        return cb(refusal("create_work_item", string.format("area '%s' is outside '%s'",
          tostring(params.area), opts.area)))
      end
      cb(nil)
    end,
  }

  local guarded = {}
  for op, fn in pairs(inner) do
    if type(fn) == "function" then
      if READS[op] then
        guarded[op] = fn
      elseif not area then
        guarded[op] = function(_, cb) cb(refusal(op, "no allowed area is configured")) end
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
