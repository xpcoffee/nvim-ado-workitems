-- Area paths in the three forms the plugin meets:
--
--   field  Project\Team\Sub          System.AreaPath, WIQL, the write guard
--   node   \Project\Area\Team\Sub    classification nodes (area_children)
--   uri    Project/Team/Sub          buffer names, and accepted in config
--
-- The project's root area is the field path "Project" and the node path
-- "\Project\Area". ADO does not allow "/" or "\" in an area name, so either
-- one can separate segments.
local M = {}

-- Segments of a path in the field or uri form, or nil for an empty path.
function M.segments(path)
  if type(path) ~= "string" then return nil end
  local out = {}
  for seg in path:gmatch("[^\\/]+") do table.insert(out, seg) end
  if #out == 0 then return nil end
  return out
end

-- The field form of a path given with "\" or "/", or nil.
function M.normalise(path)
  local segs = M.segments(path)
  return segs and table.concat(segs, "\\") or nil
end

function M.to_uri(path)
  local segs = M.segments(path)
  return segs and table.concat(segs, "/") or nil
end

function M.to_node(path)
  local segs = M.segments(path)
  if not segs then return nil end
  table.insert(segs, 2, "Area")
  return "\\" .. table.concat(segs, "\\")
end

-- nil when the path is not a node path (no "Area" second segment).
function M.from_node(node)
  local segs = M.segments(node)
  if not segs or #segs < 2 or segs[2]:lower() ~= "area" then return nil end
  table.remove(segs, 2)
  return table.concat(segs, "\\")
end

function M.project(path)
  local segs = M.segments(path)
  return segs and segs[1] or nil
end

function M.name(path)
  local segs = M.segments(path)
  return segs and segs[#segs] or nil
end

-- The parent area in the field form; nil for a project's root area.
function M.parent(path)
  local segs = M.segments(path)
  if not segs or #segs < 2 then return nil end
  table.remove(segs)
  return table.concat(segs, "\\")
end

function M.join(path, name)
  return M.normalise(path) .. "\\" .. name
end

return M
