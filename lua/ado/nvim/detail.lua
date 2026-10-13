-- Detail buffer for one work item. The buffer is read-only; pressing <CR> or an
-- insert key on a field opens a floating editor for that one field (float.lua
-- owns the editor lifecycle). State uses a select; the description uses a
-- markdown float. Field writes go through do_update, as one patch that ADO
-- refuses whole if the item changed since it was loaded.
local float = require("ado.nvim.float")
local plan = require("ado.core.plan")
local session = require("ado.nvim.session")

local M = {}

-- bufnr -> { item, field_lines, desc_start, desc_editable }
local detail = {}

-- ── conversion ────────────────────────────────────────────────────────────
-- Synchronous pandoc round-trip. Descriptions are small, so a blocking :wait()
-- on the main loop is imperceptible; falls back to raw text if pandoc is absent
-- or errors. pandoc's "markdown" bundles raw_html, so real <a href> survives the
-- round-trip; do not switch to gfm (it autolinks bare emails).
local function to_editable(html)
  if html == nil or html == "" then return { "" } end
  if vim.fn.executable("pandoc") ~= 1 then
    return vim.split(html, "\n", { plain = true })
  end
  local res = vim.system(
    { "pandoc", "-f", "html", "-t", "markdown", "--wrap=none" },
    { stdin = html, text = true }):wait()
  if res.code ~= 0 then
    return vim.split(html, "\n", { plain = true })
  end
  return vim.split((res.stdout or ""):gsub("\n+$", ""), "\n", { plain = true })
end
M.to_editable = to_editable
M.html_to_md = to_editable -- picker preview requires this name

local function from_editable(lines)
  local md = table.concat(lines, "\n")
  if vim.fn.executable("pandoc") ~= 1 then return md end
  local res = vim.system(
    { "pandoc", "-f", "markdown", "-t", "html", "--wrap=none" },
    { stdin = md, text = true }):wait()
  if res.code ~= 0 then return md end
  return (res.stdout or ""):gsub("\n+$", "")
end

-- ── model ───────────────────────────────────────────────────────────────────
local function render_assignee(item)
  if item.assignee_unique ~= "" then
    return string.format("%s <%s>", item.assignee_display, item.assignee_unique)
  end
  return item.assignee_display
end

-- ── browser ──────────────────────────────────────────────────────────────────
local function browser_open(url)
  if not url or url == "" then return end
  if vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  end
end
M.browser_open = browser_open

-- ── detail buffer ────────────────────────────────────────────────────────────
-- Header line indices map to editable fields; lines from desc_start on are the
-- description. Kept in lockstep with the literal below so they can't drift.
local FIELD_LINES = { [2] = "title", [3] = "state", [4] = "assignee", [5] = "tags", [6] = "iteration" }
local FIELD_LABELS = { title = "Title", tags = "Tags", iteration = "Iteration", assignee = "Assignee" }

local function render(buf, item)
  local entry = detail[buf]
  if not entry then return end
  local header = {
    string.format("# %s  %s  %s", item.id, item.type, item.state),
    "Title:     " .. item.title,
    "State:     " .. item.state,
    "Assignee:  " .. render_assignee(item),
    "Tags:      " .. item.tags,
    "Iteration: " .. item.iteration,
    "---",
    "Area:      " .. item.area,
    "Changed:   " .. item.changed,
    "Rev:       " .. tostring(item.rev),
    "URL:       " .. item.url,
    "---",
    "## Description",
  }
  local desc_editable = to_editable(item.description_html)
  entry.field_lines = FIELD_LINES
  entry.desc_start = #header -- the "## Description" line
  entry.desc_editable = desc_editable

  local lines = {}
  vim.list_extend(lines, header)
  vim.list_extend(lines, desc_editable)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Single write path: one rev-guarded patch, then re-render. The editor float is already
-- closed by the time this runs, so a slow `az` never leaves a window behind.
local function do_update(buf, fields)
  local entry = detail[buf]
  if not entry then return end
  local item = entry.item
  session.get():update_if_unchanged(item, fields, function(err, updated)
    if err then
      if err.kind == "conflict" then
        vim.notify("[ado] " .. err.message .. "; reload (,wr) before saving", vim.log.levels.WARN)
      end
      return
    end
    if not detail[buf] or not vim.api.nvim_buf_is_valid(buf) then return end
    entry.item = updated
    render(buf, entry.item)
    vim.notify("[ado] updated #" .. item.id, vim.log.levels.INFO)
  end)
end

-- Resolves the typed assignee as a view save does (RFC 0001 R5.19) and
-- writes only when it names one identity. An empty text unassigns, and the
-- "Name <email>" form the line shows uses its email as is.
local function set_assignee(buf, text)
  text = vim.trim(text)
  local email = text:match("<([^<>]+)>$")
  if text == "" or email then return do_update(buf, { assignee = email or "" }) end
  session.get():resolve_identity(text, function(err, found)
    if err then return end
    local who, problem = plan.choose_identity(found or {}, text)
    if not who then
      vim.notify("[ado] assignee not changed: " .. problem, vim.log.levels.WARN)
      return
    end
    do_update(buf, { assignee = who.unique_name })
  end)
end

-- Open the right editor for one field. Text fields use a single-line float,
-- state a select, description a markdown float.
function M.edit_field(buf, field)
  local entry = detail[buf]
  if not entry then return end
  local item = entry.item

  if field == "state" then
    M.pick_state(item, function(state)
      if state == item.state then return end
      do_update(buf, { state = state })
    end)
    return
  end

  if field == "description" then
    -- Snapshot the baseline now; a reload/re-render could swap entry.desc_editable
    -- underneath us before the float is confirmed.
    local baseline = entry.desc_editable
    float.text({
      title = "Description  (<C-s> save · q cancel)",
      lines = baseline,
      filetype = "markdown",
      multiline = true,
      width = math.floor(vim.o.columns * 0.7),
      height = math.floor(vim.o.lines * 0.6),
      on_confirm = function(new_lines)
        -- Unchanged body: skip the lossy round-trip and leave the HTML as-is.
        if vim.deep_equal(new_lines, baseline) then
          vim.notify("[ado] description unchanged", vim.log.levels.INFO)
          return
        end
        do_update(buf, { description = from_editable(new_lines) })
      end,
    })
    return
  end

  local current = ({
    title = item.title,
    tags = item.tags,
    iteration = item.iteration,
    assignee = render_assignee(item),
  })[field]
  if current == nil then return end
  float.text({
    title = (FIELD_LABELS[field] or field) .. "  (<CR> save · q cancel)",
    lines = { current },
    height = 1,
    on_confirm = function(new_lines)
      local val = table.concat(new_lines, " ")
      if val == current then return end
      if field == "assignee" then return set_assignee(buf, val) end
      do_update(buf, { [field] = val })
    end,
  })
end

-- Dispatch from the cursor line to the field under it; no-op on other lines.
local function dispatch_edit(buf)
  local entry = detail[buf]
  if not entry then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local field = entry.field_lines and entry.field_lines[row]
  if not field and entry.desc_start and row >= entry.desc_start then
    field = "description"
  end
  if field then M.edit_field(buf, field) end
end

local function load(buf, id)
  session.get():get(id, function(err, item)
    if err then return end
    detail[buf] = { item = item }
    render(buf, detail[buf].item)
  end)
end

local function set_detail_keymaps(buf)
  local function k(lhs, fn, d)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = d, remap = false, nowait = true })
  end
  -- <CR> and insert-entry keys edit the field under the cursor.
  for _, key in ipairs({ "<CR>", "i", "a", "I", "A", "o", "O" }) do
    k(key, function() dispatch_edit(buf) end, "ado: edit field under cursor")
  end
  k("<leader>wc", function() M.add_comment(buf) end, "Add comment")
  k("<leader>wS", function() M.edit_field(buf, "state") end, "Change state")
  k("<leader>we", function() M.edit_field(buf, "description") end, "Edit description")
  k("<leader>wb", function() browser_open(detail[buf] and detail[buf].item.url) end, "Open in browser")
  k("<leader>wr", function() M.reload(buf) end, "Reload work item")
  k("<leader>wi", function()
    if detail[buf] then require("ado.nvim.layout").toggle_item(detail[buf].item.id) end
  end, "Toggle the item view")
end

function M.open(id)
  local name = "ado://" .. id
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_set_current_buf(existing)
    -- If a prior load failed, detail[existing] is nil and reload can't recover
    -- (it needs the stored id); load fresh from the id we have.
    if detail[existing] then M.reload(existing) else load(existing, id) end
    return
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "adoitem"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[loading #" .. id .. "]" })
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function() detail[buf] = nil end,
  })
  set_detail_keymaps(buf)
  load(buf, id)
end

function M.reload(buf)
  local entry = detail[buf]
  if entry then load(buf, entry.item.id) end
end

-- ── comments & state ──────────────────────────────────────────────────────────
function M.add_comment(buf)
  local entry = detail[buf]
  if not entry then return end
  local item = entry.item
  vim.ui.input({ prompt = "Comment on #" .. item.id .. ": " }, function(text)
    if not text or text == "" then return end
    session.get():add_comment(item.id, text, function(err, updated)
      if err then return end
      entry.item = updated
      vim.notify("[ado] commented on #" .. item.id, vim.log.levels.INFO)
    end)
  end)
end

-- Pick a valid state for an item (used from the detail buffer and the picker).
function M.pick_state(item, cb)
  local function could_not_load()
    vim.notify("[ado] could not load states for " .. (item.type ~= "" and item.type or "?"),
      vim.log.levels.WARN)
  end
  session.ensure_project(function(ok)
    if not ok then return could_not_load() end
    session.get():states(item.type, item.project, function(err, states)
      if err or not states or #states == 0 then return could_not_load() end
      vim.ui.select(states, { prompt = "State for #" .. item.id }, function(choice)
        if choice then cb(choice) end
      end)
    end)
  end)
end

return M
