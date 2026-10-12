-- Back and forward over locations, as a browser does (RFC 0001 R4.1). A new
-- navigation after going back drops the forward entries.
local location = require("ado.core.location")

local M = {}

local History = {}
History.__index = History

function M.new()
  return setmetatable({ entries = {}, index = 0 }, History)
end

function History:current()
  return self.entries[self.index]
end

-- Visiting the current location again adds no entry.
function History:visit(loc)
  if location.equal(self:current(), loc) then return end
  for i = #self.entries, self.index + 1, -1 do self.entries[i] = nil end
  table.insert(self.entries, loc)
  self.index = #self.entries
end

-- The previous location, or nil at the start; moves only when there is one.
function History:back()
  if self.index <= 1 then return nil end
  self.index = self.index - 1
  return self.entries[self.index]
end

function History:forward()
  if self.index >= #self.entries then return nil end
  self.index = self.index + 1
  return self.entries[self.index]
end

return M
