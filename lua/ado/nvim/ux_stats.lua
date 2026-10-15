-- Counts and durations of the views' editing helpers (plan 0002 UX1.8)
-- and of people searches (UX6.7), for require("ado").ux_stats(). Kept for
-- the Neovim session.
local M = {}

-- A re-pad or decoration slower than this is reported once per session.
M.SLOW_MS = { repad = 50, decorate = 50 }
local LABELS = { repad = "re-pad", decorate = "decoration" }

local stats = {}
local warned = {}

-- name: what ran ("repad", "decorate", "people_search"); ms: its duration; extra: counts to keep from
-- the last run, such as the lines it rewrote.
function M.record(name, ms, extra)
  local s = stats[name]
  if not s then
    s = { count = 0, last_ms = 0, max_ms = 0 }
    stats[name] = s
  end
  s.count = s.count + 1
  s.last_ms = ms
  if ms > s.max_ms then s.max_ms = ms end
  for k, v in pairs(extra or {}) do s[k] = v end
  local slow = M.SLOW_MS[name]
  if slow and ms > slow and not warned[name] then
    warned[name] = true
    vim.notify(string.format("[ado] a %s took %.1f ms, more than %d ms; require('ado').ux_stats() shows the times",
      LABELS[name] or name, ms, slow), vim.log.levels.WARN)
  end
end

-- Adds one to a counter without a duration, such as a skipped run.
function M.count(name)
  stats[name] = stats[name] or { count = 0 }
  stats[name].count = stats[name].count + 1
end

function M.get()
  return vim.deepcopy(stats)
end

function M.lines()
  local names = vim.tbl_keys(stats)
  table.sort(names)
  local out = { string.format("shown maps of cut cells: %d texts", require("ado.nvim.fit").map_size()) }
  for _, name in ipairs(names) do
    local s = stats[name]
    if s.max_ms then
      local line = string.format("%s: %d runs, last %.2f ms, largest %.2f ms", name, s.count, s.last_ms, s.max_ms)
      if s.lines then line = line .. string.format(", last rewrote %d lines", s.lines) end
      if s.found then line = line .. string.format(", last found %d people", s.found) end
      table.insert(out, line)
    else
      table.insert(out, string.format("%s: %d", name, s.count))
    end
  end
  return out
end

function M.reset()
  stats, warned = {}, {}
end

return M
