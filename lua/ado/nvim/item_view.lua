-- The item buffer (RFC 0001 R3, RFC 0003): one buffer per work item, named
-- ado://item/<id>. Its header is the item view: its rows are edited in
-- place and saved with :w (nvim/save.lua). Below the `── Details` row it
-- shows the details as read-only text (nvim/region.lua); the description
-- is edited in a float and staged for the next :w. It shows in the item
-- window that nvim/layout.lua keeps beneath the list.
local browser = require("ado.nvim.browser")
local config = require("ado.config")
local core = require("ado.core.item_view")
local details = require("ado.core.item_details")
local fit = require("ado.nvim.fit")
local float = require("ado.nvim.float")
local keymaps = require("ado.nvim.keymaps")
local layout = require("ado.nvim.layout")
local lines_mod = require("ado.nvim.lines")
local location = require("ado.core.location")
local markup = require("ado.nvim.markup")
local progress = require("ado.nvim.progress")
local region = require("ado.nvim.region")
local registry = require("ado.nvim.registry")
local session = require("ado.nvim.session")
local urls = require("ado.core.urls")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

-- buf -> { location, view, display (nil until loaded), ids = { row id per
-- header line }, expanding = { [id] = true }, description = the loaded
-- description as markdown lines, staged = { markdown, html, added,
-- removed } | nil, details = { count = lines below the boundary row,
-- description = { first, last } of the description's lines, counted from
-- the boundary row } }
local state = {}

local DETAILS_NS = vim.api.nvim_create_namespace("ado_details")

local READONLY = "the details and comments are read-only; <leader>wd edits the description"

local LABELS = { self = "this item", parent = "parent" }

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

local function local_time(epoch)
  return os.date("%Y-%m-%d %H:%M", epoch)
end

local function winbar(entry)
  local loc = entry.location
  local text = "#" .. loc.id
  if entry.view then
    local it = entry.view.item
    text = string.format("%s %s  ·  rev %s  ·  changed %s", text, it.type, tostring(it.rev),
      details.time(it.changed_at, local_time))
  end
  text = text .. "  ·  " .. (loc.all and "children and links: all states"
    or "children and links: open only (<leader>wt for all)")
  if entry.view and entry.view.truncated then text = text .. "  ·  links truncated" end
  return text
end

-- The children and linked items the rows show, under the view's filter.
local function counts(rows)
  local children, linked = 0, 0
  for _, row in ipairs(rows) do
    if row.kind == "item" and row.slot == "child" and (row.depth or 0) == 0 then children = children + 1 end
    if row.kind == "item" and row.slot == "link" then linked = linked + 1 end
  end
  return string.format("%d children · %d linked", children, linked)
end

local function add_ids(name, rows)
  local ids = {}
  for i, row in ipairs(rows) do ids[i] = registry.add({ kind = row.kind, view = name, row = row }) end
  return ids
end

-- The lines below the boundary row: the details, from the staged
-- description when there is one.
local function details_lines(buf, entry)
  local description = entry.staged and entry.staged.markdown or entry.description
  local out, range = details.lines(entry.view.item, description, { format_time = local_time,
    width = (fit.window_width(buf) or (vim.o.columns - 2)) - 1, measure = lines_mod.measure })
  entry.details = { count = #out, description = range }
  return out
end

-- A staged description's lines carry the change sign, as edited rows do.
local function mark_details(buf, entry)
  vim.api.nvim_buf_clear_namespace(buf, DETAILS_NS, 0, -1)
  local boundary = region.boundary(buf)
  if not entry.staged or not boundary then return end
  local icon = require("ado.nvim.decorations").icons().changed
  for i = entry.details.description.first, entry.details.description.last do
    vim.api.nvim_buf_set_extmark(buf, DETAILS_NS, boundary + i - 1, 0, { sign_text = icon,
      sign_hl_group = "AdoChanged" })
  end
end

local function render(buf)
  local entry = state[buf]
  registry.release(entry.ids)
  local rows = core.rows(entry.display)
  local ids = add_ids(vim.api.nvim_buf_get_name(buf), rows)
  local text = fit.render(buf, rows, ids)
  entry.ids = ids
  local boundary = #text
  vim.list_extend(text, details_lines(buf, entry))
  view_buffer.set_lines(buf, text, { line = boundary, row_id = ids[#ids] })
  mark_details(buf, entry)
  local labels = {}
  for i, row in ipairs(rows) do
    if row.kind == "item" and LABELS[row.slot] then labels[i - 1] = LABELS[row.slot] end
  end
  view_buffer.set_labels(buf, labels)
  view_buffer.set_winbar(buf, winbar(entry), counts(rows))
end

-- opts.quiet leaves the command line alone, for a caller that reports the
-- load itself; opts.on_done(err) runs once the load ends, also when the
-- buffer went away or a newer load replaced it.
function M.load(buf, opts)
  opts = opts or {}
  local echo = opts.quiet and function() end or progress.echo
  local done_cb = opts.on_done or function() end
  local entry = state[buf]
  if not entry then return done_cb(nil) end
  local id = entry.location.id
  entry.loading = true
  view_buffer.set_editable(buf, false)
  view_buffer.set_winbar(buf, winbar(entry), "loading")
  core.load(session.get(), entry.location, {
    link_types = config.get().link_types,
    on_progress = function(done, total, what)
      echo(string.format("loading #%d: %s (%d/%d)", id, what, done, total))
    end,
  }, function(err, view)
    entry.loading = false
    if not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= entry then return done_cb(nil) end
    view_buffer.set_editable(buf, true)
    if err then
      -- Transport errors are already reported by nvim/session.lua.
      view_buffer.set_winbar(buf, winbar(entry), "load failed, <leader>wr retries")
      return done_cb(err)
    end
    entry.view = view
    entry.display = core.display(view, entry.location)
    entry.expanding = {}
    entry.description = markup.html_to_md(view.item.description_html)
    entry.staged = nil
    render(buf)
    local linked = 0
    for _, s in ipairs(view.sections) do linked = linked + #s.items end
    echo(string.format("#%d: %d children, %d linked", id, #view.children.items, linked))
    done_cb(nil)
  end)
end

local function current()
  local buf = vim.api.nvim_get_current_buf()
  return buf, state[buf]
end

-- The registry entry of the row under the cursor, its line (1-based), the
-- buffer and its state.
local function row_under_cursor()
  local buf, entry = current()
  if not entry or not entry.display then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local id = entry.ids[line]
  return id and registry.get(id) or nil, line, buf, entry
end

local function line_of(entry, row_id)
  for i, id in ipairs(entry.ids) do
    if id == row_id then return i end
  end
end

-- The rows shown beneath an expanded row: the lines after it that are
-- deeper child rows.
local function block_end(entry, line, depth)
  local last = line
  for i = line + 1, #entry.ids do
    local r = registry.get(entry.ids[i])
    if not (r and r.row.slot == "child" and r.row.depth > depth) then break end
    last = i
  end
  return last
end

local actions = {}

-- The description's lines (1-based) while the read-only text is as the
-- plugin wrote it, else nil.
local function description_lines(buf, entry)
  local boundary = region.boundary(buf)
  if not boundary or not entry.details or region.readonly_changed(buf) then return nil end
  local d = entry.details.description
  return boundary + d.first, boundary + d.last
end

-- Opens the description in a markdown float; <C-s> stages the edit for
-- the next :w instead of writing it (RFC 0003 C3.2 to C3.4), so every edit
-- of the item goes in one revision-checked patch.
function actions.description()
  local buf, entry = current()
  if not entry or not entry.view then return end
  if not vim.bo[buf].modifiable then return notify("the item is loading; try again once it has loaded") end
  if not description_lines(buf, entry) then
    return notify("the details were edited; undo the change (u) before editing the description",
      vim.log.levels.WARN)
  end
  local view = entry.view
  float.text({
    title = string.format("Description of #%d  (<C-s> keeps it for :w · q cancels)", view.item.id),
    lines = entry.staged and entry.staged.markdown or entry.description,
    filetype = "markdown",
    multiline = true,
    width = math.floor(vim.o.columns * 0.7),
    height = math.floor(vim.o.lines * 0.6),
    on_confirm = function(new_lines) M.stage_description(buf, view, new_lines) end,
  })
end

local function line_counts(old, new)
  local added, removed = 0, 0
  local hunks = vim.diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n",
    { result_type = "indices" })
  for _, h in ipairs(hunks) do
    removed = removed + h[2]
    added = added + h[4]
  end
  return added, removed
end

-- Stages new_lines (markdown) as the description of the item buffer buf
-- loaded as view, and shows them in the details. Text equal to the loaded
-- description stages nothing and drops a staged edit.
function M.stage_description(buf, view, new_lines)
  local entry = state[buf]
  if not entry or entry.view ~= view or not vim.api.nvim_buf_is_valid(buf) then
    return notify("the item reloaded while the description was open; nothing was kept", vim.log.levels.WARN)
  end
  local boundary = region.boundary(buf)
  if not boundary or region.readonly_changed(buf) then
    return notify("the details were edited; undo the change (u), then edit the description again",
      vim.log.levels.WARN)
  end
  local was = entry.staged
  if vim.deep_equal(new_lines, entry.description) then
    if not was then return notify("description unchanged") end
    entry.staged = nil
  elseif was and vim.deep_equal(new_lines, was.markdown) then
    return notify("description unchanged")
  else
    local added, removed = line_counts(entry.description, new_lines)
    entry.staged = { markdown = new_lines, html = markup.md_to_html(new_lines), added = added, removed = removed }
  end
  local old_count = entry.details.count
  local text = details_lines(buf, entry)
  view_buffer.replace_readonly(buf, boundary, boundary + old_count, text)
  mark_details(buf, entry)
  if entry.staged then
    vim.bo[buf].modified = true
    notify("description changed; :w saves it with the item's other edits")
  else
    notify("description back as loaded")
  end
end

function actions.select()
  local buf, entry = current()
  if not entry or not entry.display then return end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if not region.readable(buf, line) then
    local first, last = description_lines(buf, entry)
    if first and line >= first and line <= last then return actions.description() end
    return
  end
  local reg = row_under_cursor()
  if not reg then return end
  local loc = core.select(entry.display, reg.row, config.get().area_filters)
  if loc then layout.go(loc) end
end

actions.back = layout.back
actions.forward = layout.forward

local function item_id()
  local reg, line, buf = row_under_cursor()
  if not reg or not region.readable(buf, line) then return nil end
  return reg.row.kind == "item" and reg.row.id or nil
end

-- K: the row's item in a float beside the cursor, from one get_work_item
-- call (RFC 0003 C6.7). The float closes when the cursor moves.
M.PREVIEW_DESCRIPTION_LINES = 12

function actions.preview()
  local id = item_id()
  if not id then return end
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  session.get():get(id, function(err, item)
    if err or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win
        or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor) then
      return
    end
    local out = {
      string.format("#%d %s · %s", item.id, item.type, item.state),
      item.title,
      "",
      "assignee: " .. (item.assignee_display ~= "" and item.assignee_display or "none"),
      "tags:     " .. item.tags,
      "area:     " .. item.area,
      "changed:  " .. details.time(item.changed_at, local_time),
      "",
    }
    local md = markup.html_to_md(item.description_html)
    if #md == 1 and md[1] == "" then
      table.insert(out, "description: (none)")
    else
      table.insert(out, "description:")
      for i = 1, math.min(#md, M.PREVIEW_DESCRIPTION_LINES) do table.insert(out, md[i]) end
      if #md > M.PREVIEW_DESCRIPTION_LINES then table.insert(out, "…") end
    end
    vim.lsp.util.open_floating_preview(out, "markdown", { focus_id = "ado_item_preview", max_width = 80,
      max_height = 24, border = "rounded" })
  end)
end

-- <leader>wc: a comment typed in a markdown float, sent as soon as the
-- float is confirmed, through the write guard. A comment notifies people,
-- so it is not staged for :w. Refused while the item has unsaved edits:
-- the comment raises the item's rev, and the next :w would then fail as
-- changed remotely.
function actions.comment()
  local buf, entry = current()
  if not entry or not entry.view then return end
  if vim.bo[buf].modified then
    return notify("save (:w) or reload (<leader>wr) first: a comment raises the item's revision, so the"
      .. " unsaved edits could no longer be saved", vim.log.levels.WARN)
  end
  local id = entry.view.item.id
  float.text({
    title = string.format("Comment on #%d  (<C-s> sends it now · q cancels)", id),
    lines = { "" },
    filetype = "markdown",
    multiline = true,
    width = math.floor(vim.o.columns * 0.6),
    height = math.floor(vim.o.lines * 0.4),
    on_confirm = function(text)
      if not table.concat(text, "\n"):find("%S") then return notify("empty comment; nothing was sent") end
      session.get():add_comment(id, markup.md_to_html(text), function(err)
        if err then return end
        notify("commented on #" .. id)
        if vim.api.nvim_buf_is_valid(buf) and state[buf] == entry and not vim.bo[buf].modified then
          M.load(buf, { quiet = true, after_comment = true })
        end
      end)
    end,
  })
end

local function refuse_if_modified(buf, what)
  if not vim.bo[buf].modified then return false end
  notify("this view has unsaved edits; save them (:w) or reload (<leader>wr) before " .. what,
    vim.log.levels.WARN)
  return true
end

-- <Tab> on a child row: collapse it when expanded, else fetch and insert
-- its children (R3.4). Refused while the view has unsaved edits: the
-- cursor line may no longer be where the row was loaded, and a collapse
-- would delete lines that may hold edits.
function actions.expand()
  local reg, line, buf, entry = row_under_cursor()
  if not reg then return end
  local row = reg.row
  if not core.expandable(row) then return notify("only child rows expand") end
  if refuse_if_modified(buf, "expanding or collapsing rows") then return end
  local display = entry.display
  if display.expanded[row.id] then
    local last = block_end(entry, line, row.depth)
    local removed = {}
    for i = last, line + 1, -1 do table.insert(removed, table.remove(entry.ids, i)) end
    view_buffer.delete_lines(buf, line, last)
    registry.release(removed)
    core.collapse(display, row.id)
    return
  end
  if entry.expanding[row.id] then return end
  entry.expanding[row.id] = true
  local row_id = entry.ids[line]
  progress.echo(string.format("expanding #%d", row.id))
  view_buffer.set_editable(buf, false)
  core.expand(session.get(), display, row, function(err, rows, info)
    entry.expanding[row.id] = nil
    if next(entry.expanding) == nil then view_buffer.set_editable(buf, true) end
    if err or not vim.api.nvim_buf_is_valid(buf) or state[buf] ~= entry or entry.display ~= display then return end
    local at = line_of(entry, row_id)
    if not at then return end
    local ids = add_ids(vim.api.nvim_buf_get_name(buf), rows)
    -- Laid out on their own; the re-pad of insert_lines fits them to the
    -- rows already shown.
    local text = fit.render_more(buf, rows, ids)
    for i, id in ipairs(ids) do table.insert(entry.ids, at + i, id) end
    view_buffer.insert_lines(buf, at, text)
    if #rows == 0 then
      progress.echo(info.total == 0 and string.format("#%d has no children", row.id)
        or string.format("#%d has no open children; <leader>wt shows all", row.id))
    else
      progress.echo(string.format("#%d: %d children", row.id, #rows))
    end
  end)
end

-- Shows children and links in every state, or open only again (R3.8). The
-- rows are already loaded, so this makes no call and keeps expansions.
function actions.toggle_all()
  local buf, entry = current()
  if not entry or not entry.display then return end
  if refuse_if_modified(buf, "showing other states") then return end
  layout.go(location.with_all(entry.location, not entry.location.all), { keep_expansion = true })
end

function actions.browser()
  local _, entry = current()
  if not entry then return end
  local id = item_id() or entry.location.id
  browser.open(urls.item(session.get().org, id))
end

function actions.reload()
  local buf, entry = current()
  if not entry or entry.loading then return end
  view_buffer.confirm_discard(buf, function() M.load(buf) end)
end

M.actions = actions

-- Opens loc in the item panel and records it in the history.
function M.open(loc, opts)
  return layout.go(loc, opts)
end

-- Shows loc in the current window. The first showing of an item loads it;
-- later ones show the loaded rows again, collapsed (going back shows a
-- location collapsed), except opts.keep_expansion for the all-states
-- toggle. A view with unsaved edits is shown as it is, so going back to it
-- keeps the edits. Called by layout.go.
function M.show(loc, opts)
  opts = opts or {}
  local buf, created = view_buffer.get_or_create(location.buffer_name(loc), "adoitemview", {
    syntax = "adoitem",
    ids = function(b) return state[b] and state[b].ids end,
    project = function(b) return state[b] and state[b].view and state[b].view.item.project end,
  })
  if created then
    state[buf] = { location = loc, ids = {}, expanding = {} }
    keymaps.item(buf, actions)
    region.guard_insert(buf, READONLY)
    -- A staged description is an unsaved edit that the undo history does
    -- not hold, so `u` back to the loaded header must not clear the flag.
    vim.api.nvim_create_autocmd({ "TextChanged", "BufModifiedSet" }, {
      buffer = buf,
      callback = function()
        local e = state[buf]
        if e and e.staged and not vim.bo[buf].modified then vim.bo[buf].modified = true end
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        if state[buf] then registry.release(state[buf].ids) end
        state[buf] = nil
      end,
    })
    view_buffer.set_lines(buf, { "" })
  end
  view_buffer.show(vim.api.nvim_get_current_win(), buf)
  local entry = state[buf]
  if vim.bo[buf].modified then return buf end
  entry.location = loc
  if entry.view then
    if opts.keep_expansion and entry.display then
      entry.display.location = loc
    else
      entry.display = core.display(entry.view, loc)
    end
    render(buf)
  elseif not entry.loading then
    M.load(buf)
  end
  return buf
end

-- The view record for the change plan, or nil until the view has loaded.
-- It holds the header's rows only, with the staged description and where
-- the read-only text first differs from what the plugin wrote.
function M.record(buf)
  local entry = state[buf]
  if not entry or not entry.display then return nil end
  local record = view_buffer.record(buf, "item", entry.display.location.all and "all" or "open", entry.ids,
    core.plan_fields(entry.view))
  record.readonly_changed = region.readonly_changed(buf)
  if entry.staged then
    record.description = { html = entry.staged.html, added = entry.staged.added, removed = entry.staged.removed }
  end
  return record
end

-- Whether the buffer has unsaved edits, a staged description included.
function M.modified(buf)
  local entry = state[buf]
  return vim.bo[buf].modified or (entry ~= nil and entry.staged ~= nil)
end

function M.busy(buf)
  local entry = state[buf]
  return entry ~= nil and (entry.loading == true or next(entry.expanding or {}) ~= nil)
end

function M.state(buf)
  if buf == nil or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return state[buf]
end

return M
