-- Column widths, padding and cell ranges of the views' item rows (plan 0002
-- phase 1).
local layout = require("ado.core.table_layout")

local FULL = layout.LAYOUTS.full

-- One column per UTF-8 code point, as the plan's core specs measure.
local function codepoints(s)
  return #(s:gsub("[\128-\191]", ""))
end

-- As codepoints, with the CJK block two columns wide, as Neovim draws it.
local function display(s)
  local w = 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local b1 = ch:byte(1)
    w = w + ((b1 >= 0xE4 and b1 <= 0xE9) and 2 or 1)
  end
  return w
end

local function texts(text)
  return layout.cells(text, layout.ranges(text, FULL))
end

test("widths take the widest cell per column, measured, with the indent of child rows", function()
  local w = layout.widths({
    { "Task", "To Do", "修复登录", "", "" },
    { "    Task", "Active", "Fix…", "Alex Smith", "api" },
  }, display)
  eq(w, { 8, 6, 8, 10, 3 })
  eq(layout.widths({ { "Task", "To Do", "修复登录", "", "" } }, codepoints), { 4, 5, 4, 0, 0 })
  eq(layout.widths({ { "Bug", "New", "x", "", "" } }, codepoints, { 10, 2, 0, 0, 0 }), { 10, 3, 1, 0, 0 },
    "kept widths only widen")
end)

test("pad aligns the separators and drops trailing spaces", function()
  local w = { 10, 6, 5, 10, 3 }
  eq(layout.pad({ "Task", "To Do", "Short", "", "" }, w, codepoints),
    "Task       │ To Do  │ Short │            │")
  eq(layout.pad({ "User Story", "Active", "修复", "Alex Smith", "api" }, w, display),
    "User Story │ Active │ 修复  │ Alex Smith │ api")
end)

test("pad round-trips through ranges, for indented rows and empty cells", function()
  local rows = {
    { "Task", "To Do", "Fix the … login", "Alex Smith", "api; backend" },
    { "    Task", "", "修复登录", "", "" },
    { "", "", "", "", "" },
  }
  local w = layout.widths(rows, display)
  for _, cells in ipairs(rows) do
    local text = layout.pad(cells, w, display)
    eq(texts(text), cells, text)
    eq(layout.edits(text, layout.ranges(text, FULL), w, display), {}, "an aligned row needs no edits: " .. text)
  end
end)

test("S13 a title holding the separator and a slash stays one cell", function()
  local text = layout.pad({ "Task", "To Do", "x │ y / z/ │ w", "Alex", "a" }, { 4, 5, 14, 4, 1 }, codepoints)
  eq(texts(text), { "Task", "To Do", "x │ y / z/ │ w", "Alex", "a" })
  local r = layout.ranges(text, FULL)
  eq(text:sub(r[3].first, r[3].last), "x │ y / z/ │ w")
end)

test("a line with fewer separators than the layout needs has no cells", function()
  eq(layout.ranges("Task │ To Do │ title │ me", FULL), nil)
  eq(layout.ranges("just a title", FULL), nil)
end)

test("edits rewrite only the wrong runs of spaces, from the right", function()
  local w = { 4, 11, 5, 4, 1 }
  local text = "Task │ In Progress │ Short │ Alex │ a"
  eq(layout.edits(text, layout.ranges(text, FULL), w, codepoints), {})
  local drifted = "Task │ Active │ Short │ Alex │ a"
  local edits = layout.edits(drifted, layout.ranges(drifted, FULL), w, codepoints)
  eq(#edits, 1, "only the run after the state")
  local fixed = layout.apply(drifted, edits)
  eq(fixed, "Task │ Active      │ Short │ Alex │ a")
  eq(texts(fixed), texts(drifted), "the cells' text is untouched")
end)

test("edits fix missing spaces, tabs, trailing spaces and empty cells", function()
  local w = { 4, 5, 5, 4, 0 }
  local cases = {
    { "Task│To Do│Short│Alex│", "Task │ To Do │ Short │ Alex │" },
    { "Task\t│ To Do │ Short │ Alex │   ", "Task │ To Do │ Short │ Alex │" },
    { "Task │  │ Short │ │", "Task │       │ Short │      │" },
    { "  Task │ To Do │ Short │ Alex │ ", "  Task │ To Do │ Short │ Alex │" },
  }
  for _, c in ipairs(cases) do
    local text = c[1]
    local fixed = layout.apply(text, layout.edits(text, layout.ranges(text, FULL), w, codepoints))
    eq(fixed, c[2], text)
  end
end)

-- Fitting to the window (plan 0002 UX4.1, UX4.2 and the restore rule).

-- Natural widths at least as wide as every budget, so the table of UX4.1
-- holds exactly.
local WIDE = { type = 12, letters = 1, state = 12, title = 120, assignee = 20, tags = 20 }

test("UX4.1 the layout at each boundary of the plan's table, the dot counted", function()
  local cases = {
    -- text width minus prefix, step, title, type, assignee, tags
    { 98, "full", 36, 10, 14, 14 },
    { 82, "full", 20, 10, 14, 14 },
    { 81, "tags", 32, 10, 14, 1 },
    { 69, "tags", 20, 10, 14, 1 },
    { 68, "letters", 28, 1, 14, 1 },
    { 65, "letters", 25, 1, 14, 1 },
    { 64, "letters", 24, 1, 14, 1 },
    { 60, "letters", 20, 1, 14, 1 },
    { 59, "assignee", 25, 1, 8, 1 },
    { 56, "assignee", 22, 1, 8, 1 },
    { 55, "assignee", 21, 1, 8, 1 },
    { 54, "assignee", 20, 1, 8, 1 },
    { 50, "assignee", 20, 1, 8, 1 },
    { 49, "assignee", 20, 1, 8, 1 },
  }
  for _, c in ipairs(cases) do
    local b = layout.budget(c[1], WIDE, 2)
    eq({ b.step, b.widths.title, b.widths.type, b.widths.assignee, b.widths.tags }, { c[2], c[3], c[4], c[5], c[6] },
      "text width " .. c[1])
    eq(b.widths.state, 10)
    eq(b.letters, c[2] == "letters" or c[2] == "assignee")
  end
end)

test("UX4.1 narrow columns keep their width, and the title gets the rest", function()
  local b = layout.budget(98, { type = 4, letters = 1, state = 6, title = 120, assignee = 10, tags = 0 }, 2)
  eq(b.step, "full")
  eq(b.widths, { type = 4, state = 6, title = 98 - 2 - 12 - 20, assignee = 10, tags = 0 })
  local wide = layout.budget(200, { type = 4, letters = 1, state = 6, title = 30, assignee = 25, tags = 40 }, 2)
  eq(wide.widths, { type = 4, state = 6, title = 30, assignee = 25, tags = 40 },
    "with room to spare nothing is cut")
  local short = layout.budget(70, { type = 4, letters = 1, state = 6, title = 10, assignee = 30, tags = 30 }, 2)
  eq(short.widths.title, 10, "a short title keeps its width")
  eq(short.widths.assignee + short.widths.tags, 70 - 2 - 12 - 4 - 6 - 10, "the room left goes back to the cut columns")
end)

test("UX4.1 letters take the widest indent, and a short title is not padded to 20", function()
  local b = layout.budget(60, { type = 12, letters = 5, state = 12, title = 120, assignee = 20, tags = 20 }, 2)
  eq(b.widths.type, 5)
  eq(layout.budget(30, { type = 4, letters = 1, state = 4, title = 8, assignee = 4, tags = 0 }, 2).widths.title, 8)
end)

test("UX4.2 cut ends in the mark, never splits a character, and keeps short text", function()
  eq(layout.cut("Fix the login bug", 8, codepoints), "Fix the…")
  eq(layout.cut("Fix", 8, codepoints), "Fix")
  eq(layout.cut("Fix the", 7, codepoints), "Fix the")
  eq(layout.cut("修复登录问题", 7, display), "修复登…", "three 2-column characters and the mark")
  eq(layout.cut("修复登录问题", 6, display), "修复…", "a wide character that does not fit is left out")
  eq(layout.cut("api; backend", 1, codepoints), "…")
  eq(display(layout.cut("a修复登录问题", 6, display)) <= 6, true)
end)

test("UX4.2 the type letter is the first letter of the last word, unless overridden", function()
  eq(layout.letter("Task"), "T")
  eq(layout.letter("User Story"), "S")
  eq(layout.letter("Test Case", { ["Test Case"] = "C" }), "C")
  eq(layout.letter("Test Case", { Bug = "X" }), "C")
end)

test("restore keeps the hidden part through a deletion, an insertion and a replacement in the head", function()
  local full = "Fix the login bug on mobile"
  local shown = layout.cut(full, 10, codepoints)
  eq(shown, "Fix the l…")
  eq(layout.restore(full, shown, "Fix he l…"), "Fix he login bug on mobile")
  eq(layout.restore(full, shown, "Fix all the l…"), "Fix all the login bug on mobile")
  eq(layout.restore(full, shown, "Mend the l…"), "Mend the login bug on mobile")
  eq(layout.restore(full, shown, shown), full)
end)

test("restore refuses edits that touch the mark", function()
  local full = "Fix the login bug on mobile"
  local shown = "Fix the l…"
  eq(layout.restore(full, shown, "Fix the l"), nil, "the mark deleted")
  eq(layout.restore(full, shown, "Fix the l…x"), nil, "text typed after the mark")
  eq(layout.restore(full, shown, ""), nil, "the cell emptied")
  eq(layout.restore(full, full, "Fix…"), nil, "before was not cut")
  eq(layout.restore("Other title", shown, "Fix the l…"), nil, "before is not a cut of full")
end)

-- A small deterministic generator, so a failing sequence can be repeated.
local function rng(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
end

test("restore: random head edits, cut again after each, equal the same edits made to the full value", function()
  local alphabet = { "a", "b", " ", "x", "修", "…" }
  for seed = 1, 200 do
    local r = rng(seed)
    local full = "The quick brown fox jumps over the lazy dog " .. seed
    local width = 6 + r(20)
    local shown = layout.cut(full, width, display)
    for _ = 1, 25 do
      local head = shown:sub(1, -#layout.ELLIPSIS - 1)
      local chars = {}
      for ch in head:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
      local at = r(#chars + 1)
      local kind = r(3)
      local edited = { unpack(chars) }
      if kind == 1 and #chars > 0 then
        table.remove(edited, math.min(at, #chars))
      elseif kind == 2 then
        table.insert(edited, at, alphabet[r(#alphabet)])
      elseif #chars > 0 then
        edited[math.min(at, #chars)] = alphabet[r(#alphabet)]
      end
      -- The same edit made to the full value: the head is its prefix.
      local expected = table.concat(edited) .. full:sub(#head + 1)
      local now = table.concat(edited) .. layout.ELLIPSIS
      local restored = layout.restore(full, shown, now)
      eq(restored, expected, "seed " .. seed)
      full = restored
      shown = layout.cut(full, width, display)
      if shown == full then break end
    end
  end
end)

test("edits with replacement texts rewrite a cut cell and re-pad around it", function()
  local w = { 4, 6, 10, 4, 1 }
  local text = "Task │ Active │ Fix the lo │ Alex │ …"
  local r = layout.ranges(text, FULL)
  local fixed = layout.apply(text, layout.edits(text, r, w, codepoints, { nil, nil, "Fix the l…" }))
  eq(fixed, "Task │ Active │ Fix the l… │ Alex │ …")
  eq(layout.edits(fixed, layout.ranges(fixed, FULL), w, codepoints, { nil, nil, "Fix the l…" }), {})
  local empty = "Task │ Active │ │ Alex │"
  eq(layout.apply(empty, layout.edits(empty, layout.ranges(empty, FULL), w, codepoints, { nil, nil, "New" })),
    "Task │ Active │ New        │ Alex │")
end)
