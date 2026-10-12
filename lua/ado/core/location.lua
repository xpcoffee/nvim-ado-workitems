-- Locations name what a view shows (RFC 0001 section 4), and each encodes to
-- a URI (R4.5):
--
--   ado://area/Project/Team?state=open&type=Task,Bug&assignee=@Me&tag=api&sub=0
--   ado://item/1234?all=0
--
-- An area URI is also its buffer name. An item view's buffer is named
-- ado://item/1234 for every value of `all`, because the show-all toggle
-- filters rows already loaded and needs no other buffer or fetch.
--
--   location = { kind = "area", path = "Project\\Team" (field form),
--                filters = { state, assignee, types, tag }, sub = bool }
--            | { kind = "item", id = 1234, all = bool }
--   all               false: children and links in an open state only (R3.8)
--   filters.state     "open" | "all" | { state name... }
--   filters.assignee  nil (anyone) | "@Me" | an identity's name or email
--   filters.types     nil (every type) | { type name... }
--   filters.tag       nil | one tag, matched whole
--   sub               false: this area only; true: also every sub-area (R2.5)
local area_path = require("ado.core.area_path")

local M = {}

local function copy_list(list)
  if type(list) ~= "table" then return nil end
  local out = {}
  for _, v in ipairs(list) do table.insert(out, v) end
  return out
end

local function blank(s)
  return s == nil or (type(s) == "string" and not s:find("%S"))
end

-- filters may be partial or nil; missing entries take the defaults.
function M.area(path, filters, sub)
  filters = filters or {}
  local state = filters.state
  if type(state) == "table" then
    state = #state > 0 and copy_list(state) or "open"
  elseif state ~= "all" then
    state = "open"
  end
  local types = copy_list(filters.types)
  if types and #types == 0 then types = nil end
  return {
    kind = "area",
    path = area_path.normalise(path),
    filters = {
      state = state,
      assignee = not blank(filters.assignee) and filters.assignee or nil,
      types = types,
      tag = not blank(filters.tag) and filters.tag or nil,
    },
    sub = sub == true,
  }
end

-- nil when id is not a positive whole number.
function M.item(id, all)
  id = tonumber(id)
  if not id or id < 1 or id % 1 ~= 0 then return nil end
  return { kind = "item", id = id, all = all == true }
end

function M.with_all(loc, all)
  return M.item(loc.id, all)
end

-- The same filters and toggle at another path (R2.3, R2.9).
function M.at(loc, path)
  return M.area(path, loc.filters, loc.sub)
end

function M.with_filters(loc, changes)
  local f = {}
  for k, v in pairs(loc.filters) do f[k] = v end
  for k, v in pairs(changes) do
    if v == false then f[k] = nil else f[k] = v end
  end
  return M.area(loc.path, f, loc.sub)
end

function M.with_sub(loc, sub)
  return M.area(loc.path, loc.filters, sub)
end

-- Characters that would end a query value or split a list.
local function encode(s)
  return (tostring(s):gsub("[%%&=?#,]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function encode_list(list)
  local parts = {}
  for _, v in ipairs(list or {}) do table.insert(parts, encode(v)) end
  return table.concat(parts, ",")
end

local function decode_list(s)
  local out = {}
  for part in s:gmatch("[^,]+") do table.insert(out, decode(part)) end
  return out
end

function M.uri(loc)
  if loc.kind == "item" then
    return string.format("ado://item/%d?all=%d", loc.id, loc.all and 1 or 0)
  end
  local f = loc.filters
  local state = type(f.state) == "table" and encode_list(f.state) or f.state
  local segs = area_path.segments(loc.path)
  for i, seg in ipairs(segs) do segs[i] = encode(seg) end
  return string.format("ado://area/%s?state=%s&type=%s&assignee=%s&tag=%s&sub=%d",
    table.concat(segs, "/"), state, encode_list(f.types),
    f.assignee and encode(f.assignee) or "", f.tag and encode(f.tag) or "", loc.sub and 1 or 0)
end

function M.buffer_name(loc)
  if loc.kind == "item" then return "ado://item/" .. loc.id end
  return M.uri(loc)
end

-- The location a URI or buffer name encodes, or nil when it is neither an
-- area nor an item URI.
function M.parse(uri)
  local id, flags = tostring(uri):match("^ado://item/(%d+)%??(.*)$")
  if id then return M.item(id, flags:match("all=1") ~= nil) end
  local path, query = tostring(uri):match("^ado://area/([^?]+)%??(.*)$")
  if not path then return nil end
  local params = {}
  for key, value in query:gmatch("([^&=]+)=([^&]*)") do params[key] = value end
  local state = params.state or "open"
  if state ~= "open" and state ~= "all" then state = decode_list(state) end
  local segs = {}
  for seg in path:gmatch("[^/]+") do table.insert(segs, decode(seg)) end
  return M.area(table.concat(segs, "\\"), {
    state = state,
    types = decode_list(params.type or ""),
    assignee = params.assignee and decode(params.assignee) or nil,
    tag = params.tag and decode(params.tag) or nil,
  }, params.sub == "1")
end

function M.equal(a, b)
  return a ~= nil and b ~= nil and M.uri(a) == M.uri(b)
end

-- One line for the window bar (R2.6).
function M.describe(loc)
  local f = loc.filters
  local parts = {
    "state: " .. (type(f.state) == "table" and table.concat(f.state, ", ") or f.state),
    "assignee: " .. (f.assignee or "any"),
    "type: " .. (f.types and table.concat(f.types, ", ") or "any"),
    "tag: " .. (f.tag or "any"),
    loc.sub and "sub-areas: included" or "sub-areas: excluded",
  }
  return table.concat(parts, "  ·  ")
end

return M
