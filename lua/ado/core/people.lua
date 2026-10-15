-- People candidates for an assignee cell (plan 0002 UX6.1 to UX6.4): the
-- people the views already show, the people picked earlier in the session
-- and ADO's answers to a search by prefix, merged into one ranked list
-- with one entry per email. A person is
-- { display_name, unique_name (the email the save resolves), mail, id }.
local M = {}

local People = {}
People.__index = People

local function lower(s)
  return (s or ""):lower()
end

local function starts(s, prefix)
  return s:sub(1, #prefix) == prefix
end

-- Whether text, ignoring case, starts the display name, any word of it,
-- or the email of person. An empty text matches everyone.
function M.matches(person, text)
  local t = lower(text):gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return true end
  local name = lower(person.display_name)
  if starts(name, t) or starts(lower(person.unique_name), t) or starts(lower(person.mail), t) then return true end
  for word in name:gmatch("%S+") do
    if starts(word, t) then return true end
  end
  return false
end

-- Whether text is exactly the display name or the email of person.
function M.names(person, text)
  local t = lower(text):gsub("^%s+", ""):gsub("%s+$", "")
  return t ~= "" and (t == lower(person.display_name) or t == lower(person.unique_name) or t == lower(person.mail))
end

function M.new(session)
  return setmetatable({
    session = session,
    -- lower-case text -> the people ADO found for it
    answers = {},
    -- lower-case text -> { cb... } waiting for the call in flight
    inflight = {},
    -- people picked in this session, most recent first
    recent = {},
    -- the number of the latest search() call
    latest = 0,
  }, People)
end

-- Adds each person of list to out, unless out has their email already.
local function merge(out, seen, list, source)
  for _, p in ipairs(list or {}) do
    local key = lower(p.unique_name)
    if key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(out, { display_name = p.display_name or "", unique_name = p.unique_name, mail = p.mail,
        id = p.id, source = source })
    end
  end
end

local function by_name(list)
  local out = {}
  for i, p in ipairs(list or {}) do out[i] = p end
  table.sort(out, function(a, b)
    local x, y = lower(a.display_name), lower(b.display_name)
    if x ~= y then return x < y end
    return lower(a.unique_name) < lower(b.unique_name)
  end)
  return out
end

-- The answers cached for text and for every shorter prefix of it, the
-- longest first.
function People:cached(text)
  local key = lower(text)
  local out = {}
  for i = #key, 1, -1 do
    local found = self.answers[key:sub(1, i)]
    if found then table.insert(out, { text = key:sub(1, i), found = found }) end
  end
  return out
end

-- The people to offer for text, ranked: picked earlier in the session
-- (most recent first), then local (the people on loaded rows, by name),
-- then ADO's answers. ADO's answer to text itself is kept whole, as ADO
-- matched it; everyone else must match text. One entry per email; each
-- carries source = "picked" | "local" | "ado".
function People:candidates(text, locals)
  local out, seen = {}, {}
  local function matching(list)
    local keep = {}
    for _, p in ipairs(list or {}) do
      if M.matches(p, text) then table.insert(keep, p) end
    end
    return keep
  end
  merge(out, seen, matching(self.recent), "picked")
  merge(out, seen, matching(by_name(locals)), "local")
  for _, c in ipairs(self:cached(text)) do
    merge(out, seen, c.text == lower(text) and c.found or matching(c.found), "ado")
  end
  return out
end

-- Searches ADO for the people whose name or email starts with text:
-- cb(err, found, info). info.calls is the number of calls this search made
-- (0 for a cached answer or one already in flight); info.stale is true
-- when a later search() started before this answer arrived, so a menu
-- showing the later text must ignore it. Answers are cached for the
-- session by lower-case text; a failure is not. opts.quiet: the caller
-- reports a failure itself (see Session:resolve_identity).
function People:search(text, opts, cb)
  self.latest = self.latest + 1
  local mine = self.latest
  local key = lower(text)
  local function reply(err, found, info)
    info.stale = mine ~= self.latest
    cb(err, found, info)
  end
  if self.answers[key] then return reply(nil, self.answers[key], { calls = 0 }) end
  local waiting = self.inflight[key]
  if waiting then
    table.insert(waiting, function(err, found) reply(err, found, { calls = 0 }) end)
    return
  end
  waiting = { function(err, found) reply(err, found, { calls = 1 }) end }
  self.inflight[key] = waiting
  self.session:resolve_identity(text, function(err, found)
    self.inflight[key] = nil
    if not err then self.answers[key] = found or {} end
    for _, w in ipairs(waiting) do w(err, self.answers[key]) end
  end, { quiet = opts and opts.quiet })
end

-- Records that person was picked, so later menus offer them first.
function People:picked(person)
  local key = lower(person.unique_name)
  if key == "" then return end
  for i, p in ipairs(self.recent) do
    if lower(p.unique_name) == key then
      table.remove(self.recent, i)
      break
    end
  end
  table.insert(self.recent, 1, { display_name = person.display_name or "", unique_name = person.unique_name,
    mail = person.mail, id = person.id })
end

return M
