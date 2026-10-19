-- Timings of the views' re-pad (plan 0002 phase 1), decoration (phase 2)
-- and full layout fitted to the window (phase 5) at 200 and 1,000 rows,
-- and of the item buffer's read-only region (plan 0003): a header edit
-- with 1,000 read-only lines below it, and a write below the header that
-- keeps the undo history:
--   make bench
-- Not part of `make test`, because timings vary by machine. Prints the
-- median and largest of each case against the plan's targets, and the
-- lines the last re-pad rewrote. "TextChanged" is all the work one change
-- starts: the re-pad, the conceal pass and the decoration of
-- nvim/view_buffer.lua.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(root)

local fit = require("ado.nvim.fit")
local lines = require("ado.nvim.lines")
local C = require("ado.core.table_layout").INDEX
local realign = require("ado.nvim.realign")
local registry = require("ado.nvim.registry")
local types = require("ado.core.types")
local ux_stats = require("ado.nvim.ux_stats")
local view_buffer = require("ado.nvim.view_buffer")

local RUNS = 40
-- The plan sets the decoration target at 1,000 rows only.
local TARGETS = { [200] = { same = 5, widen = 25 }, [1000] = { same = 25, widen = 50, decorate = 25, layout = 50 } }
local STATES = { "New", "Active", "To Do", "Doing", "Resolved", "Closed" }
local TYPES = { "Task", "User Story", "Bug", "Feature" }
local PEOPLE = { "", "Alex Smith", "Janet Doe", "Bartholomew Featherstonehaugh" }
local WORDS = { "fix", "the", "login", "redirect", "loop", "on", "expired", "sessions", "checkout", "flow" }

local function rows(n)
  local out = {}
  for i = 1, n do
    local words = {}
    for w = 1, 2 + i % 7 do words[w] = WORDS[(i * 3 + w) % #WORDS + 1] end
    out[i] = { kind = "item", id = 1000 + i, type = TYPES[i % #TYPES + 1], state = STATES[i % #STATES + 1],
      title = table.concat(words, " "), assignee = PEOPLE[i % #PEOPLE + 1], tags = i % 5 == 0 and "api; ux" or "" }
  end
  return out
end

local function median(xs)
  table.sort(xs)
  return xs[math.ceil(#xs / 2)]
end

-- Every type and state with a colour, as on the Example project, so
-- each row gets a colour group.
local CATALOG = (function()
  local list = {}
  for i, t in ipairs(TYPES) do
    local states = {}
    for j, st in ipairs(STATES) do
      states[j] = { name = st, category = "InProgress", color = string.format("%02x%02x%02x", i * 40, j * 30, 99) }
    end
    list[i] = { name = t, color = string.format("%02x%02x%02x", 200, i * 40, 10), states = states }
  end
  return types.new(list)
end)()

local function view(n)
  local ids = {}
  local buf = view_buffer.get_or_create("ado://bench/" .. n, "adoarea", { syntax = "adoarea",
    ids = function() return ids end, project = function() return "Bench" end,
    catalog = function() return CATALOG end })
  vim.api.nvim_set_current_buf(buf)
  local data = rows(n)
  for i, r in ipairs(data) do ids[i] = registry.add({ kind = "item", view = "bench", row = r }) end
  view_buffer.set_lines(buf, (fit.render(buf, data, ids)))
  return buf, data, ids
end

-- Replaces cell `index` (table_layout.INDEX) of line `row` (0-based) with text, as an edit of
-- the user's: a new undo step.
local function set_cell(buf, row, index, text)
  vim.o.undolevels = vim.o.undolevels
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local ranges, offset = lines.row_ranges(line)
  local r = ranges[index]
  vim.api.nvim_buf_set_text(buf, row, offset + r.first - 1, row, offset + r.last, { text })
end

local function time(fn)
  local started = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - started) / 1e6
end

-- edit(i) makes the i-th change; returns the medians and largest times
-- of the re-pad alone and of the whole TextChanged.
local function measure(buf, edit)
  local repad, changed, rewritten = {}, {}, 0
  for i = 1, RUNS do
    edit(i)
    repad[i] = time(function() realign.run(buf) end)
    rewritten = ux_stats.get().repad.lines
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
    edit(i)
    changed[i] = time(function() vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf }) end)
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent undo") end)
  end
  local max_repad = math.max(unpack(repad))
  return median(repad), max_repad, median(changed), rewritten
end

local out = { string.format("%-6s %-16s %8s %10s %10s %14s %8s", "rows", "edit", "rewrites", "median ms",
  "largest ms",
  "TextChanged ms", "target") }
local missed = 0
vim.o.termguicolors = true
for _, n in ipairs({ 200, 1000 }) do
  local buf, data, ids = view(n)
  -- The whole layout of a load or a resize: widths, cuts and shown maps.
  local layout = {}
  for i = 1, RUNS do layout[i] = time(function() fit.render(buf, data, ids) end) end
  local layout_max = math.max(unpack(layout))
  local layout_target = TARGETS[n].layout
  local layout_ok = not layout_target or layout_max < layout_target
  if not layout_ok then missed = missed + 1 end
  table.insert(out, string.format("%-6d %-16s %8s %10.2f %10.2f %14s %6s %s", n, "full layout", "-",
    median(layout), layout_max, "-", layout_target and ("< " .. layout_target) or "-", layout_ok and "ok" or "MISSED"))
  local decorate = {}
  for i = 1, RUNS do decorate[i] = time(function() view_buffer.decorate(buf, true) end) end
  local decorate_max = math.max(unpack(decorate))
  local target = TARGETS[n].decorate
  local decorate_ok = not target or decorate_max < target
  if not decorate_ok then missed = missed + 1 end
  table.insert(out, string.format("%-6d %-16s %8s %10.2f %10.2f %14s %6s %s", n, "decorate all", "-",
    median(decorate), decorate_max, "-", target and ("< " .. target) or "-", decorate_ok and "ok" or "MISSED"))
  -- A short title on a row that holds no column's widest cell: only its
  -- own line needs new padding.
  local row = 1
  local same_med, same_max, same_all, same_lines = measure(buf, function(i)
    set_cell(buf, row, C.title, i % 2 == 0 and "fix" or "fix it")
  end)
  local widen_med, widen_max, widen_all, widen_lines = measure(buf, function()
    set_cell(buf, row, C.state, "Waiting for the review board")
  end)
  for _, c in ipairs({ { "no width change", same_med, same_max, same_all, TARGETS[n].same, same_lines },
    { "widens a column", widen_med, widen_max, widen_all, TARGETS[n].widen, widen_lines } }) do
    local ok = c[3] < c[5]
    if not ok then missed = missed + 1 end
    table.insert(out, string.format("%-6d %-16s %8d %10.2f %10.2f %14.2f %6s %s", n, c[1], c[6], c[2], c[3], c[4],
      "< " .. c[5], ok and "ok" or "MISSED"))
  end
end

-- An item buffer: 30 header rows, the boundary row, then `below` lines of
-- read-only text, each with a separator, as a comment quoting a row would.
local function item_buffer(below)
  local ids = {}
  local buf = view_buffer.get_or_create("ado://bench/item/" .. below, "adoitemview", { syntax = "adoitem",
    ids = function() return ids end, project = function() return "Bench" end,
    catalog = function() return CATALOG end })
  vim.api.nvim_set_current_buf(buf)
  local data = rows(30)
  table.insert(data, { kind = "heading", slot = "boundary", label = "Details" })
  for i, r in ipairs(data) do ids[i] = registry.add({ kind = r.kind, view = "bench", row = r }) end
  local text = fit.render(buf, data, ids)
  local header = #text
  for i = 1, below do text[#text + 1] = "    comment line " .. i .. " │ quoting │ a row" end
  view_buffer.set_lines(buf, text, { line = header, row_id = ids[#ids] })
  return buf, header
end

-- Plan 0003 targets: the read-only lines add under 1 ms to a header
-- edit's TextChanged, and a write below the header that keeps 100 undo
-- steps takes under 25 ms.
local READONLY_EXTRA, QUIET_WRITE = 1, 25
local plain = item_buffer(0)
local _, _, plain_changed = measure(plain, function(i) set_cell(plain, 1, C.title, i % 2 == 0 and "fix" or "fix it") end)
local item = item_buffer(1000)
local _, _, item_changed = measure(item, function(i) set_cell(item, 1, C.title, i % 2 == 0 and "fix" or "fix it") end)
local extra = item_changed - plain_changed
local extra_ok = extra < READONLY_EXTRA
if not extra_ok then missed = missed + 1 end
table.insert(out, string.format("%-6s %-16s %8s %10s %10s %14.2f %6s %s", "item", "1,000 below", "-", "-", "-",
  item_changed, string.format("%+.2f", extra) .. " < " .. READONLY_EXTRA, extra_ok and "ok" or "MISSED"))
for i = 1, 100 do
  set_cell(item, 1, C.title, "edit " .. i)
  realign.run(item)
end
local steps = vim.api.nvim_buf_call(item, function() return vim.fn.undotree().seq_last end)
local quiet = {}
for i = 1, RUNS do
  local n = vim.api.nvim_buf_line_count(item)
  quiet[i] = time(function()
    view_buffer.replace_readonly(item, n - 1, n, { "    a comment " .. i, "    its text", "", "── more" })
  end)
end
local kept = vim.api.nvim_buf_call(item, function() return vim.fn.undotree().seq_last end) == steps
local quiet_max = math.max(unpack(quiet))
local quiet_ok = kept and quiet_max < QUIET_WRITE
if not quiet_ok then missed = missed + 1 end
table.insert(out, string.format("%-6s %-16s %8s %10.2f %10.2f %14s %6s %s", "item", "quiet write", "-",
  median(quiet), quiet_max, kept and "history kept" or "HISTORY LOST", "< " .. QUIET_WRITE,
  quiet_ok and "ok" or "MISSED"))


io.stdout:write(table.concat(out, "\n") .. "\n")
io.stdout:write(string.format("%d runs per case; Neovim %s\n", RUNS, tostring(vim.version())))
os.exit(missed == 0 and 0 or 1)
