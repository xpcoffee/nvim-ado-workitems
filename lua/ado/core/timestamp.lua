-- ADO timestamps (ISO 8601 in UTC, such as "2026-10-15T14:02:33.123Z") as
-- epoch seconds, so the presentation layer can show them in local time.
local M = {}

local floor = math.floor

-- Days from 1970-01-01 to a civil date (proleptic Gregorian calendar).
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = floor((z >= 0 and z or z - 146096) / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end

-- Epoch seconds, or nil for text that is not an ISO 8601 date and time.
-- An offset other than Z is applied.
function M.parse(text)
  if type(text) ~= "string" then return nil end
  local y, mo, d, h, mi, s, rest = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)[%.%d]*(.*)$")
  if not y then return nil end
  local epoch = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
  local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
  if sign then
    local offset = tonumber(oh) * 3600 + tonumber(om) * 60
    epoch = sign == "+" and epoch - offset or epoch + offset
  end
  return epoch
end

-- "2026-10-15 14:02" in UTC: the core's default, and the tests' clock.
function M.utc_minute(epoch)
  local days = floor(epoch / 86400)
  local secs = epoch % 86400
  local y, m, d = civil_from_days(days)
  return string.format("%04d-%02d-%02d %02d:%02d", y, m, d, floor(secs / 3600), floor((secs % 3600) / 60))
end

return M
