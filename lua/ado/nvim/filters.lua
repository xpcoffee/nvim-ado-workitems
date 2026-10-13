-- The filter prompt of the list views (<leader>wf in an area view or a
-- query list): pick a filter, type its value, and get the location with it.
local location = require("ado.core.location")

local M = {}

local PROMPTS = {
  state = "State (open, all, or names separated by commas): ",
  assignee = "Assignee (empty for anyone, @Me, or a name or email): ",
  types = "Types (empty for every type, or names separated by commas): ",
  tag = "Tag (empty for any, or one whole tag): ",
}

local function split_list(text)
  local out = {}
  for part in (text or ""):gmatch("[^,]+") do
    local v = part:match("^%s*(.-)%s*$")
    if v ~= "" then table.insert(out, v) end
  end
  return out
end

local function current_text(f, key)
  local v = f[key]
  if type(v) == "table" then return table.concat(v, ", ") end
  return v or ""
end

local function parse(key, text)
  if key == "state" then
    local t = text:match("^%s*(.-)%s*$"):lower()
    if t == "" or t == "open" then return "open" end
    if t == "all" then return "all" end
    return split_list(text)
  end
  if key == "types" then
    local value = split_list(text)
    return #value > 0 and value or false
  end
  local value = text:match("^%s*(.-)%s*$")
  return value ~= "" and value or false
end

-- keys: the filters offered, in order. defaults(): the location with the
-- default filters. open(loc) shows the chosen location.
function M.choose(loc, keys, defaults, open)
  local choices = {}
  for _, k in ipairs(keys) do table.insert(choices, k) end
  table.insert(choices, "reset to defaults")
  vim.ui.select(choices, { prompt = "Filter" }, function(key)
    if not key then return end
    if key == "reset to defaults" then return open(defaults()) end
    vim.ui.input({ prompt = PROMPTS[key], default = current_text(loc.filters, key) }, function(text)
      if text == nil then return end
      open(location.with_filters(loc, { [key] = parse(key, text) }))
    end)
  end)
end

return M
