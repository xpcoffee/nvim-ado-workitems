-- Buffers for the area and item views: named by their location URI,
-- acwrite so that :w reaches the plugin and never the file system, row ID
-- prefixes concealed, and a window bar per buffer.
local lines_mod = require("ado.nvim.lines")
local registry = require("ado.nvim.registry")

local M = {}

local NS = vim.api.nvim_create_namespace("ado_view")
local LABELS = vim.api.nvim_create_namespace("ado_view_labels")

-- vim.fn.bufnr() treats its argument as a file pattern, and these names
-- hold "?", so buffers are matched by exact name instead.
function M.find(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then return buf end
  end
end

local function apply_window_options(buf, win)
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  set("conceallevel", 2)
  set("concealcursor", "nvic")
  set("wrap", false)
  set("winbar", (vim.b[buf].ado_winbar or ""):gsub("%%", "%%%%"))
end

-- Conceals the row ID prefix of every line, including lines the user has
-- pasted or typed, by reading it from the text.
local function conceal(buf)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local prefix = line:match("^/%d+ ")
    if prefix then vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 0, { end_col = #prefix, conceal = "" }) end
  end
end

-- Returns the buffer and whether it was created now.
function M.get_or_create(name, filetype)
  local existing = M.find(name)
  if existing then return existing, false end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = filetype
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    -- Neovim returns the cursor to the written buffer once BufWriteCmd
    -- ends, which would pull it out of the summary float the save opens.
    callback = function() vim.schedule(function() require("ado.nvim.save").write(buf) end) end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function() conceal(buf) end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function() apply_window_options(buf, vim.api.nvim_get_current_win()) end,
  })
  return buf, true
end


-- Changes lines whether or not the view is modifiable, keeping its modified
-- flag. The change is left out of the undo history, so `u` cannot undo a
-- load or an expansion into an empty or half-shown view.
local function edit(buf, first, last, lines)
  local modified, modifiable = vim.bo[buf].modified, vim.bo[buf].modifiable
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].modifiable = true
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = modified
end

-- Views cannot be edited while they load or while a save applies, since
-- the load or the save's reload would replace the edits.
function M.set_editable(buf, editable)
  if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = editable end
end

function M.set_lines(buf, lines)
  edit(buf, 0, -1, lines)
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, LABELS, 0, -1)
  conceal(buf)
end

-- Inserts lines before line `at` (0-based) without redrawing the others.
function M.insert_lines(buf, at, lines)
  edit(buf, at, at, lines)
  conceal(buf)
end

-- Deletes lines first to last - 1 (0-based).
function M.delete_lines(buf, first, last)
  -- A deleted line's labels would otherwise move onto the next line.
  vim.api.nvim_buf_clear_namespace(buf, LABELS, first, last)
  edit(buf, first, last, {})
  conceal(buf)
end

-- labels: { [0-based line] = text }, shown after the end of the line.
function M.set_labels(buf, labels)
  for line, text in pairs(labels) do
    vim.api.nvim_buf_set_extmark(buf, LABELS, line, 0, { virt_text = { { text, "Comment" } }, virt_text_pos = "eol" })
  end
end

function M.set_winbar(buf, text)
  vim.b[buf].ado_winbar = text
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do apply_window_options(buf, win) end
end

-- The view record the change plan reads (core/plan.lua): the rows shown at
-- the last load, from the registry, and the rows parsed from the buffer
-- now. ids: the row ID of each loaded line, in order. extra: fields the
-- plan needs about the view itself (rel, item, ...), copied in.
-- A row ID this buffer did not load is a row pasted from another view; its
-- registry entry becomes the row's origin, so the plan knows which item it
-- shows. An ID the registry no longer holds gets no origin, and the plan
-- rejects the line.
function M.record(buf, kind, state_filter, ids, extra)
  local name = vim.api.nvim_buf_get_name(buf)
  local snapshot, loaded = {}, {}
  for i, rid in ipairs(ids) do
    local s = vim.deepcopy(registry.get(rid).row)
    s.row_id, s.line = rid, i
    snapshot[i] = s
    loaded[rid] = true
  end
  local current = {}
  for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local p = lines_mod.parse(text)
    local reg = p.row_id and registry.get(p.row_id)
    if reg and reg.row.kind == "item" and reg.row.slot == "self" then
      p = { row_id = p.row_id, kind = "item", title = lines_mod.body(text) }
    end
    if reg and not loaded[p.row_id] then p.origin = { key = reg.view, row = vim.deepcopy(reg.row) } end
    p.line = i
    table.insert(current, p)
  end
  local record = { key = name, kind = kind, state_filter = state_filter, snapshot = snapshot, current = current }
  for k, v in pairs(extra or {}) do record[k] = v end
  return record
end

-- Runs fn now when buf has no unsaved edits, else after the user agrees to
-- discard them (R4.4).
function M.confirm_discard(buf, fn)
  if not vim.bo[buf].modified then return fn() end
  vim.ui.select({ "Discard the edits and reload", "Keep editing" },
    { prompt = "This view has unsaved edits" }, function(choice)
      if choice == "Discard the edits and reload" then fn() end
    end)
end

function M.show(win, buf)
  vim.api.nvim_win_set_buf(win, buf)
  apply_window_options(buf, win)
end

return M
