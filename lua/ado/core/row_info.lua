-- A view row as labelled values, for the float that shows a row whose
-- cells are cut to fit the window (plan 0002 UX4.4).
local M = {}

local LABEL_WIDTH = #"assignee"

local function label(name, value)
  return name .. string.rep(" ", LABEL_WIDTH - #name) .. "  " .. value
end

-- "Name <email>" for the person the row is loaded with, when the text
-- names them; any other text as it is.
local function person(text, loaded)
  if text == "" then return "none" end
  local name, email = loaded.assignee or "", loaded.assignee_unique or ""
  if email ~= "" and (text == name or text:lower() == email:lower()) then
    return string.format("%s <%s>", name ~= "" and name or email, email)
  end
  return text
end

-- current: the row's values now (type, state, title, assignee, tags);
-- loaded: the row it was loaded as (id, assignee, assignee_unique, area),
-- or nil for a new line. Returns the float's lines.
function M.lines(current, loaded)
  loaded = loaded or {}
  local head = loaded.id and ("#" .. loaded.id) or "new"
  local kind = table.concat({ current.type or "", current.state or "" }, " · "):gsub("^ · ", ""):gsub(" · $", "")
  local out = { kind ~= "" and (head .. "  " .. kind) or head }
  table.insert(out, label("title", current.title or ""))
  table.insert(out, label("assignee", person(current.assignee or "", loaded)))
  table.insert(out, label("tags", (current.tags or "") ~= "" and current.tags or "none"))
  if loaded.area and loaded.area ~= "" then table.insert(out, label("area", loaded.area)) end
  return out
end

return M
