-- <leader>we in the views (plan 0002 UX3.2, UX6.6): picks a type or state
-- with vim.ui.select, or a person found by a name asked with vim.ui.input,
-- and writes it into that cell of the cursor's row, or of every selected
-- row in Visual mode. The write is one undo step, joined by its re-pad, so
-- it reaches the save summary as a typed edit would.
local cells = require("ado.nvim.cells")
local choices = require("ado.core.choices")
local complete = require("ado.nvim.complete")
local people = require("ado.nvim.people")
local progress = require("ado.nvim.progress")
local realign = require("ado.nvim.realign")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local EXPLAIN = "<leader>we picks a type, state or assignee from a list and writes it into that cell, or into"
  .. " that column of every selected row in Visual mode; "

local function label(item)
  return item.menu ~= "" and string.format("%s  (%s)", item.word, item.menu) or item.word
end

local UNASSIGN = { unassign = true }

local function person_label(p)
  return p.unassign and "unassign" or people.label(p)
end

-- The assignee picked for targets: cb(value, label), value an email or ""
-- to unassign. Asks for a name, searches, and offers the matches.
local function ask_person(targets, cb)
  vim.ui.input({ prompt = "Assignee name or email: " }, function(text)
    text = text and vim.trim(text) or nil
    if not text then return end
    local function offer(list)
      if not list then return end
      table.insert(list, UNASSIGN)
      local prompt = #targets > 1 and string.format("Assignee for %d rows", #targets) or "Assignee"
      vim.ui.select(list, { prompt = prompt, format_item = person_label, kind = "ado_assignee" }, function(choice)
        if not choice then return end
        if choice.unassign then return cb("", "nobody") end
        people.picked(choice)
        cb(choice.unique_name, people.label(choice))
      end)
    end
    if text == "" then return offer(people.local_candidates()) end
    people.find(text, offer)
  end)
end

-- visual: the key was pressed in Visual mode, over the lines from the
-- selection's start to the cursor.
function M.pick(visual)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local at, col = unpack(vim.api.nvim_win_get_cursor(win))
  local first, last = at, at
  if visual then
    first = vim.fn.line("v")
    if first > last then first, last = last, first end
    vim.cmd("normal! \27")
  end
  local t = complete.target(buf, at, col + 1)
  if not t or not (choices.COLUMNS[t.column] or t.column == "assignee") then
    return notify(EXPLAIN .. (t and ("the cursor is on the " .. t.column .. " cell") or "this line has no cells"))
  end
  if not vim.bo[buf].modifiable then return notify("the view is loading; try again once it has loaded") end
  local targets = { t }
  if visual and not t.cell.field then
    targets = {}
    for i = first, last do
      local row = complete.target(buf, i, nil, t.index)
      if row then table.insert(targets, row) end
    end
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local function write(value, shown)
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      or not vim.bo[buf].modifiable then
      return notify("the view changed while the list was open; nothing was written", vim.log.levels.WARN)
    end
    local line_numbers = {}
    for i, x in ipairs(targets) do line_numbers[i] = x.line end
    local n = cells.write(buf, line_numbers, t.index, value)
    realign.run(buf)
    view_buffer.decorate(buf)
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      local line = vim.api.nvim_buf_get_lines(buf, at - 1, at, false)[1]
      local c = t.index and cells.nth(line, t.index) or cells.at(line, #line)
      if c then vim.api.nvim_win_set_cursor(win, { at, c.first - 1 }) end
    end
    progress.echo(string.format("%s %s on %d %s", t.column, shown, n, n == 1 and "row" or "rows"))
  end
  if t.column == "assignee" then return ask_person(targets, write) end
  complete.values(targets, function(items, reason)
    if not items then
      if reason and reason.message then notify(reason.message, vim.log.levels.WARN) end
      return
    end
    tick = vim.api.nvim_buf_get_changedtick(buf)
    local prompt = t.column == "type" and "Type" or "State"
    if #targets > 1 then prompt = string.format("%s for %d rows", prompt, #targets) end
    vim.ui.select(items, { prompt = prompt, format_item = label, kind = "ado_" .. t.column }, function(choice)
      if choice then write(choice.word, choice.word) end
    end)
  end)
end

return M
