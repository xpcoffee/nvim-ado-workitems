-- What a cell of a view holds when the views cut long cells to fit the
-- window (plan 0002 phase 5, option T). The buffer shows a cut text ending
-- in "…", and the full value lives outside the buffer, so every rule that
-- turns buffer text back into a value is here, where the sandbox tests it.
--
-- One map per row ID and column, the cell's "shown map", pairs each text
-- the cell has shown with the value it stands for:
--
--   map = { [shown text] = full value, or false when no value is known }
--
-- A text that is its own value was shown in full. The map gains an entry
-- for every text the cell shows after a load or a re-pad, so after `u` or
-- `<C-r>` the text in the buffer finds its value again with no state to
-- rewind. A cell that was never cut or edited has no map: its text is its
-- value.
--
-- The rule that protects ADO: a cell with a map whose text the map does
-- not know has no value, and the save rejects its row (UX5.4). A cut value
-- is never taken for a full one.
local table_layout = require("ado.core.table_layout")

local M = {}

local E = table_layout.ELLIPSIS

local function ends_cut(text)
  return #text >= #E and text:sub(-#E) == E
end

-- The value of text in a cell with this map, and how it was found:
-- "plain" (the text is the value), "cut" (a cut text the map knows) or
-- "ambiguous" (no value). loaded: the value the row was loaded with, for
-- a cell with no map. Free text that reads as a cut of the loaded value
-- (a head of it followed by "…") with no map to say so is ambiguous too,
-- so a cut text whose map was lost can never pass for a new value.
function M.lookup(map, text, loaded)
  if map then
    local v = map[text]
    if v == false or v == nil then return nil, "ambiguous" end
    return v, v == text and "plain" or "cut"
  end
  if loaded and text ~= loaded and ends_cut(text) then
    local head = text:sub(1, -#E - 1)
    if #loaded > #head and loaded:sub(1, #head) == head then return nil, "ambiguous" end
  end
  return text, "plain"
end

-- The value of a cell's text after an edit, for the re-pad that follows
-- it. Returns value (nil when ambiguous) and how it was found: "known"
-- (the map knows the text), "plain", "restored" or "ambiguous".
-- ctx:
--   loaded    the value the row was loaded with
--   before    the cell's text before the edit, when the re-pad knows it
--   trusted   before is the text of the state the edit was made from
--   replaced  true, or the text expected, when the edit replaced the
--             whole cell (`cic`, a picker, <leader>wx): the new text is the
--             value
--   enum      the column takes one of a list of names (the type), which
--             the save checks, so text the map does not know is a value
function M.resolve(map, now, ctx)
  ctx = ctx or {}
  if map and map[now] ~= nil then
    if map[now] == false then return nil, "ambiguous" end
    return map[now], "known"
  end
  if ctx.replaced == true or (ctx.replaced ~= nil and ctx.replaced == now) then return now, "plain" end
  if not map then
    local v, how = M.lookup(nil, now, ctx.loaded)
    return v, how
  end
  if ctx.enum then return now, "plain" end
  -- Without the text of the state the edit was made from, the hidden part
  -- of the value is not known.
  if ctx.before == nil or not ctx.trusted then return nil, "ambiguous" end
  local bv = map[ctx.before]
  if bv == nil or bv == false then return nil, "ambiguous" end
  if bv == ctx.before then return now, "plain" end
  local r = table_layout.restore(bv, ctx.before, now)
  if r then return r, "restored" end
  return nil, "ambiguous"
end

-- Records that the cell shows `shown` for value, and returns the text to
-- show: shown, or value itself when shown already stands for another value
-- in this map (two values with one cut text would make `u` find the wrong
-- one). The map is created when needed and seeded with the loaded value,
-- which the cell shows again after enough `u`. value nil marks shown as
-- having no value. Returns the text and the map (nil when none is needed).
function M.remember(map, shown, value, loaded)
  if value == nil then
    map = map or {}
    if map[shown] == nil then map[shown] = false end
    return shown, map
  end
  if not map and shown == value and (loaded == nil or value == loaded) then return shown, nil end
  map = map or {}
  if loaded ~= nil and map[loaded] == nil then map[loaded] = loaded end
  if shown ~= value and map[shown] ~= nil and map[shown] ~= value then shown = value end
  if map[shown] == nil then
    map[shown] = value
  elseif map[shown] ~= value then
    -- The full text is itself a cut text of another value; neither can be
    -- told apart any more.
    map[shown] = false
  end
  return shown, map
end

-- How many texts the maps hold, for ux_stats.
function M.size(map)
  local n = 0
  for _ in pairs(map or {}) do n = n + 1 end
  return n
end

return M
