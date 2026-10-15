-- The values behind cut cells (plan 0002 phase 5, UX5.1 to UX5.4): the
-- shown map, the restore after an edit, and the rule that a text the map
-- does not know has no value.
local fit = require("ado.core.fit")
local layout = require("ado.core.table_layout")

local function codepoints(s)
  return #(s:gsub("[\128-\191]", ""))
end

local FULL = "Fix the login bug on mobile"

-- The map a load leaves for a title cut to width.
local function loaded_map(full, width)
  local shown = layout.cut(full, width, codepoints)
  local text, map = fit.remember(nil, shown, full, full)
  return text, map
end

test("UX5.4 a cell with no map is its text; one with a map knows only its texts", function()
  eq({ fit.lookup(nil, "Anything") }, { "Anything", "plain" })
  local shown, map = loaded_map(FULL, 10)
  eq(shown, "Fix the l…")
  eq({ fit.lookup(map, shown) }, { FULL, "cut" })
  eq({ fit.lookup(map, FULL) }, { FULL, "plain" }, "the loaded value is seeded")
  eq({ fit.lookup(map, "Fix the l") }, { nil, "ambiguous" }, "a text the map does not know has no value")
end)

test("UX5.4 without a map, a text that reads as a cut of the loaded value is ambiguous", function()
  eq({ fit.lookup(nil, "Fix the l…", FULL) }, { nil, "ambiguous" })
  eq({ fit.lookup(nil, "Fix the dog…", FULL) }, { "Fix the dog…", "plain" }, "not a head of the loaded value")
  eq({ fit.lookup(nil, "Wait…", "Wait") }, { "Wait…", "plain" }, "longer than the loaded value")
end)

test("UX5.1 an edit in the head of a cut cell restores the hidden part", function()
  local shown, map = loaded_map(FULL, 10)
  eq({ fit.resolve(map, "Mend the l…", { before = shown, trusted = true, loaded = FULL }) },
    { "Mend the login bug on mobile", "restored" })
end)

test("UX5.4 an edit that touches the mark, or one made from an unknown state, is ambiguous", function()
  local shown, map = loaded_map(FULL, 10)
  local ctx = { before = shown, trusted = true, loaded = FULL }
  eq({ fit.resolve(map, "Fix the l", ctx) }, { nil, "ambiguous" }, "the mark deleted")
  eq({ fit.resolve(map, "Fix the l…x", ctx) }, { nil, "ambiguous" }, "text after the mark")
  eq({ fit.resolve(map, "Fix th…", { before = shown, trusted = false, loaded = FULL }) }, { nil, "ambiguous" },
    "an untrusted before")
  eq({ fit.resolve(map, "Fix th…", { loaded = FULL }) }, { nil, "ambiguous" }, "no before")
  local _, marked = fit.remember(map, "Fix the l", nil, FULL)
  eq({ fit.resolve(marked, "Fix the lo", { before = "Fix the l", trusted = true, loaded = FULL }) },
    { nil, "ambiguous" }, "an edit of an ambiguous text stays ambiguous")
  eq({ fit.resolve(marked, shown, { before = "Fix the l", trusted = true, loaded = FULL }) }, { FULL, "known" },
    "typing the mark back finds the value again")
end)

test("UX5.3 a whole-cell replacement, a known text, and a type name are values", function()
  local shown, map = loaded_map(FULL, 10)
  eq({ fit.resolve(map, "New title", { before = shown, trusted = true, replaced = true }) }, { "New title", "plain" })
  eq({ fit.resolve(map, "New title", { before = shown, trusted = true, replaced = "New title" }) },
    { "New title", "plain" })
  eq({ fit.resolve(map, "Other", { before = shown, trusted = true, replaced = "New title" }) }, { nil, "ambiguous" },
    "a replacement whose text is not what was written")
  eq({ fit.resolve(map, FULL, { before = shown, trusted = false }) }, { FULL, "known" })
  local _, types = fit.remember(nil, "T", "Task", "Task")
  eq({ fit.resolve(types, "B", { before = "T", trusted = true, enum = true }) }, { "B", "plain" })
end)

test("UX5.1 an edit of a cell shown in full is a plain edit", function()
  local _, map = loaded_map(FULL, 10)
  eq({ fit.resolve(map, "Fix the login", { before = FULL, trusted = true }) }, { "Fix the login", "plain" })
end)

test("remember shows the value in full rather than give one text two values", function()
  local shown, map = loaded_map(FULL, 10)
  local other = "Fix the lights"
  local text = fit.remember(map, layout.cut(other, 10, codepoints), other, FULL)
  eq(text, other, "the cut text of another value is taken")
  eq(map[shown], FULL)
  eq(map[other], other)
  eq(select(2, fit.remember(nil, "Same", "Same", "Same")), nil, "an unedited cell that fits needs no map")
  local _, edited = fit.remember(nil, "Changed", "Changed", "Loaded")
  eq(edited, { Changed = "Changed", Loaded = "Loaded" }, "an edited cell gets a map, with its loaded value")
end)

-- A small deterministic generator, so a failing sequence can be repeated.
local function rng(seed)
  local state = seed
  return function(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
end

-- The re-pad's cycle, as nvim/realign.lua runs it: resolve the edited
-- text, then show it cut again and remember it.
local function settle(map, now, ctx, width)
  local value = fit.resolve(map, now, ctx)
  local shown = value and layout.cut(value, width, codepoints) or now
  shown, map = fit.remember(map, shown, value, ctx.loaded)
  return shown, value, map
end

test("UX5.4 random edits and undos: a value is the true one or none, never a cut text", function()
  for seed = 1, 300 do
    local r = rng(seed)
    local loaded = "Investigate the flaky login test on the build agents " .. seed
    local width = 8 + r(12)
    local shown, map = fit.remember(nil, layout.cut(loaded, width, codepoints), loaded, loaded)
    -- The undo history: the text shown and the true value at each state,
    -- nil when the edit could not be restored.
    local history = { { shown = shown, value = loaded } }
    local at = 1
    for _ = 1, 30 do
      local cur = history[at]
      local kind = r(10)
      if kind <= 2 and #history > 1 then
        at = r(#history)
        local v = fit.lookup(map, history[at].shown, loaded)
        eq(v, history[at].value, "seed " .. seed .. ": u or <C-r> finds the value of that state")
      else
        local text, truth, ctx = cur.shown, nil, { before = cur.shown, trusted = true, loaded = loaded }
        local cut = text:sub(-#layout.ELLIPSIS) == layout.ELLIPSIS and cur.value ~= text
        if kind == 3 then
          text, truth = "Replaced " .. r(1000), nil
          ctx.replaced = true
          truth = text
        elseif kind == 4 and cut then
          text = text:sub(1, -#layout.ELLIPSIS - 1)
        elseif kind == 5 and cut then
          text = text .. "x"
        else
          local pos = r(math.max(1, #text - (cut and #layout.ELLIPSIS or 0)))
          text = text:sub(1, pos - 1) .. "z" .. text:sub(pos)
          if cur.value then
            truth = cut and (text:sub(1, -#layout.ELLIPSIS - 1) .. cur.value:sub(#cur.shown - #layout.ELLIPSIS + 1))
              or text
          end
        end
        local new_shown, value
        new_shown, value, map = settle(map, text, ctx, width)
        eq(value, truth, "seed " .. seed .. ": " .. text)
        if value then
          eq(value ~= nil and value:sub(-#layout.ELLIPSIS) == layout.ELLIPSIS and value ~= truth, false)
        end
        -- A new change drops the states after the current one.
        for i = #history, at + 1, -1 do history[i] = nil end
        table.insert(history, { shown = new_shown, value = value })
        at = #history
      end
    end
  end
end)
