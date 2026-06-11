-- Work-item view model + buffers. Owns the normalised item shape, the detail
-- buffer (editable field block + read-only context + description preview), the
-- separate description-edit buffer, and the BufWriteCmd save-back for both.
local client = require("ado.client")
local config = require("ado.config")

local M = {}

-- bufnr -> { item } for detail buffers.
local detail = {}
-- description bufnr -> { item, parent, original_html, md } for edit buffers.
local desc = {}

-- ── conversion ────────────────────────────────────────────────────────────
-- Synchronous pandoc round-trip. Descriptions are small, so a blocking :wait()
-- on the main loop is imperceptible; falls back to raw text if pandoc is absent
-- or errors.
local function html_to_md(html)
  if html == nil or html == "" then return {} end
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
M.html_to_md = html_to_md

local function md_to_html(md)
  if vim.fn.executable("pandoc") ~= 1 then return md end
  local res = vim.system(
    { "pandoc", "-f", "markdown", "-t", "html", "--wrap=none" },
    { stdin = md, text = true }):wait()
  if res.code ~= 0 then return md end
  return (res.stdout or ""):gsub("\n+$", "")
end

-- ── model ───────────────────────────────────────────────────────────────────
local function normalise(raw)
  local f = raw.fields or {}
  local assignee = f["System.AssignedTo"]
  local display, unique = "", ""
  if type(assignee) == "table" then
    display = assignee.displayName or ""
    unique = assignee.uniqueName or ""
  end
  local url = raw._links and raw._links.html and raw._links.html.href
  return {
    id = raw.id,
    rev = raw.rev,
    type = f["System.WorkItemType"] or "",
    title = f["System.Title"] or "",
    state = f["System.State"] or "",
    assignee_display = display,
    assignee_unique = unique,
    tags = f["System.Tags"] or "",
    iteration = f["System.IterationPath"] or "",
    area = f["System.AreaPath"] or "",
    changed = (f["System.ChangedDate"] or ""):sub(1, 10),
    description_html = f["System.Description"] or "",
    -- az boards query omits _links, so synthesise the edit URL when absent.
    url = url or string.format("https://dev.azure.com/%s/_workitems/edit/%s",
      config.get().org, tostring(raw.id)),
    raw = raw,
  }
end
M.normalise = normalise

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
local function render(buf, item)
  local lines = {
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
  vim.list_extend(lines, html_to_md(item.description_html))
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
end

-- Parse the editable field block (everything before the first '---').
local function parse_fields(buf)
  local out = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match("^%-%-%-") then break end
    local key, val = line:match("^(%a+):%s*(.-)%s*$")
    if key then out[key:lower()] = val end
  end
  return out
end

local function save_fields(buf)
  local entry = detail[buf]
  if not entry then return end
  local item = entry.item
  local parsed = parse_fields(buf)

  local update = {}
  if parsed.title and parsed.title ~= item.title then update.title = parsed.title end
  if parsed.state and parsed.state ~= item.state then update.state = parsed.state end
  if parsed.tags and parsed.tags ~= item.tags then update.tags = parsed.tags end
  if parsed.iteration and parsed.iteration ~= item.iteration then update.iteration = parsed.iteration end
  if parsed.assignee and parsed.assignee ~= render_assignee(item) then
    update.assignee = parsed.assignee
  end

  if vim.tbl_isempty(update) then
    vim.notify("[ado] no field changes", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end

  -- Re-check the remote revision before writing; abort rather than clobber a
  -- concurrent edit. A true check-then-write race remains (acceptable single-user).
  client.show(item.id, function(ok, raw)
    if not ok then return end
    if raw.rev ~= item.rev then
      vim.notify(string.format(
        "[ado] #%s changed remotely (rev %s -> %s); reload (,wr) before saving",
        item.id, tostring(item.rev), tostring(raw.rev)), vim.log.levels.WARN)
      return
    end
    client.update(item.id, update, function(ok2, updated)
      if not ok2 then return end
      entry.item = normalise(updated)
      render(buf, entry.item)
      vim.notify("[ado] updated #" .. item.id, vim.log.levels.INFO)
    end)
  end)
end

local function load(buf, id)
  client.show(id, function(ok, raw)
    if not ok then return end
    local item = normalise(raw)
    detail[buf] = { item = item }
    render(buf, item)
  end)
end

local function set_detail_keymaps(buf)
  local function k(lhs, fn, d)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = d, remap = false })
  end
  k("<leader>ww", function() vim.cmd("write") end, "Save work item")
  k("<leader>wc", function() M.add_comment(buf) end, "Add comment")
  k("<leader>wS", function() M.change_state(buf) end, "Change state")
  k("<leader>we", function() M.edit_description(buf) end, "Edit description")
  k("<leader>wb", function() browser_open(detail[buf] and detail[buf].item.url) end, "Open in browser")
  k("<leader>wr", function() M.reload(buf) end, "Reload work item")
end

function M.open(id)
  local name = "ado://" .. id
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_set_current_buf(existing)
    M.reload(existing)
    return
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "adoitem"
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[loading #" .. id .. "]" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function() save_fields(buf) end,
  })
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

-- ── description-edit buffer ───────────────────────────────────────────────────
local function save_description(buf)
  local base = desc[buf]
  if not base then return end
  local item = base.item
  local md = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

  -- Unchanged body: leave the original HTML untouched, skip the lossy round-trip.
  if md == base.md then
    vim.notify("[ado] description unchanged", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end

  client.show(item.id, function(ok, raw)
    if not ok then return end
    if raw.rev ~= item.rev then
      vim.notify(string.format(
        "[ado] #%s changed remotely (rev %s -> %s); reopen before saving",
        item.id, tostring(item.rev), tostring(raw.rev)), vim.log.levels.WARN)
      return
    end
    client.update(item.id, { description = md_to_html(md) }, function(ok2, updated)
      if not ok2 then return end
      base.item = normalise(updated)
      base.md = md
      vim.bo[buf].modified = false
      vim.notify("[ado] updated description #" .. item.id, vim.log.levels.INFO)
      -- Reflect the new rev/body in the parent detail buffer if it's still open.
      local parent = base.parent
      if parent and detail[parent] and vim.api.nvim_buf_is_valid(parent) then
        detail[parent].item = base.item
        render(parent, base.item)
      end
    end)
  end)
end

function M.edit_description(parent_buf)
  local entry = detail[parent_buf]
  if not entry then return end
  local item = entry.item
  local name = "ado://" .. item.id .. "/description"
  local buf = vim.fn.bufnr(name)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function() save_description(buf) end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function() desc[buf] = nil end,
    })
  end
  local md = html_to_md(item.description_html)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, md)
  vim.bo[buf].modified = false
  desc[buf] = {
    item = item,
    parent = parent_buf,
    original_html = item.description_html,
    md = table.concat(md, "\n"),
  }
  vim.api.nvim_set_current_buf(buf)
end

-- ── field actions ─────────────────────────────────────────────────────────────
function M.add_comment(buf)
  local entry = detail[buf]
  if not entry then return end
  local item = entry.item
  vim.ui.input({ prompt = "Comment on #" .. item.id .. ": " }, function(text)
    if not text or text == "" then return end
    client.add_comment(item.id, text, function(ok, updated)
      if not ok then return end
      entry.item = normalise(updated)
      vim.notify("[ado] commented on #" .. item.id, vim.log.levels.INFO)
    end)
  end)
end

-- Pick a valid state for an item (used from both detail buffer and picker).
function M.pick_state(item, cb)
  client.states(item.type, function(ok, states)
    if not ok or not states or #states == 0 then
      vim.notify("[ado] could not load states for " .. (item.type ~= "" and item.type or "?"),
        vim.log.levels.WARN)
      return
    end
    vim.ui.select(states, { prompt = "State for #" .. item.id }, function(choice)
      if choice then cb(choice) end
    end)
  end)
end

function M.change_state(buf)
  local entry = detail[buf]
  if not entry then return end
  local item = entry.item
  M.pick_state(item, function(state)
    client.update(item.id, { state = state }, function(ok, updated)
      if not ok then return end
      entry.item = normalise(updated)
      render(buf, entry.item)
      vim.notify(string.format("[ado] #%s -> %s", item.id, state), vim.log.levels.INFO)
    end)
  end)
end

return M
