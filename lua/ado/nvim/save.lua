-- :w in a view (RFC 0001 R5.2, R5.3, R5.15): one change plan across every
-- modified view, a summary to accept or cancel, then apply, the audit log,
-- and a reload of the views the save touched. Views not in the save keep
-- their edits (R6.8). A save ends in one line in :messages; a save that
-- stops also opens its report.
local apply = require("ado.core.apply")
local audit = require("ado.nvim.audit")
local plan = require("ado.core.plan")
local progress = require("ado.nvim.progress")
local session = require("ado.nvim.session")
local summary = require("ado.core.summary")
local summary_ui = require("ado.nvim.summary_ui")
local view_buffer = require("ado.nvim.view_buffer")

local M = {}

-- Replaceable so tests can answer the summary: confirm(lines, can_apply,
-- cb(accepted)), and see the report: show_report(lines).
M.confirm = summary_ui.open
M.show_report = summary_ui.report

local saving = false

local function notify(msg, level)
  vim.notify("[ado] " .. msg, level or vim.log.levels.INFO)
end

-- Every open view buffer: { buf, mod, name }.
local function views()
  local mods = { require("ado.nvim.area_view"), require("ado.nvim.query_view"), require("ado.nvim.item_view") }
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    for _, mod in ipairs(mods) do
      if vim.api.nvim_buf_is_valid(buf) and mod.state(buf) then
        table.insert(out, { buf = buf, mod = mod, name = vim.api.nvim_buf_get_name(buf) })
      end
    end
  end
  return out
end

local function shows_any(v, ids)
  local record = v.mod.record(v.buf)
  for _, r in ipairs(record and record.snapshot or {}) do
    if r.id and ids[r.id] then return true end
  end
  return false
end

-- The conflict the revision guard finds leads to a reload, so its report
-- says so.
local function error_text(err)
  if err.kind == "conflict" then return err.message .. "; the view reloads to show the change" end
  return err.message
end

-- Reports once the reloads are done, so their progress cannot overwrite
-- the save's line.
local function finish(all, saved, result)
  saving = false
  session.mute_errors(false)
  local touched = {}
  for _, id in ipairs(result.touched) do touched[id] = true end
  local is_saved = {}
  for _, v in ipairs(saved) do is_saved[v.buf] = true end
  local reloads = {}
  for _, v in ipairs(all) do
    if vim.api.nvim_buf_is_valid(v.buf) then
      view_buffer.set_editable(v.buf, true)
      if (is_saved[v.buf] and not result.failed) or shows_any(v, touched) then table.insert(reloads, v) end
    end
  end

  local function report()
    if not result.failed then return notify(summary.result_line(result)) end
    local shown = {}
    for k, x in pairs(result) do shown[k] = x end
    shown.failed = { request = result.failed.request, error = { message = error_text(result.failed.error) } }
    M.show_report(summary.report(shown))
    notify(summary.result_line(result) .. "; the report shows why", vim.log.levels.ERROR)
  end
  if #reloads == 0 then return report() end
  progress.echo(string.format("reloading %d %s", #reloads, #reloads == 1 and "view" or "views"))
  local pending = #reloads
  for _, v in ipairs(reloads) do
    v.mod.load(v.buf, { quiet = true, on_done = function()
      pending = pending - 1
      if pending == 0 then report() end
    end })
  end
end

local function plural(n, one)
  return string.format("%d %s%s", n, one, n == 1 and "" or "s")
end

-- "#101 (2 changes)", "new Task 'Title'".
local function progress_label(req)
  if req.create then return summary.request_label(req) end
  return string.format("%s (%s)", summary.request_label(req), plural(#req.ops, "change"))
end

local function run(all, saved, p)
  for _, v in ipairs(all) do view_buffer.set_editable(v.buf, false) end
  session.mute_errors(true)
  local audit_failed = false
  apply.run(session.get(), p, {
    on_event = function(e)
      if e.kind == "start" then
        progress.echo(string.format("saving %d/%d: %s", e.index, e.total, progress_label(e.request)))
      else
        local ok, err = audit.append(e)
        if not ok and not audit_failed then
          audit_failed = true
          notify("could not write the audit log " .. audit.path() .. ": " .. tostring(err), vim.log.levels.WARN)
        end
      end
    end,
  }, function(result) finish(all, saved, result) end)
end

-- A plan with nothing to send: its one note as a line, or several in the
-- report float.
local function nothing_to_save(lines)
  local notes = {}
  for _, l in ipairs(lines) do
    if l.kind == "note" or l.kind == "warning" then table.insert(notes, (l.text:gsub("^%s+", ""))) end
  end
  if #notes == 0 then return notify("nothing to save") end
  if #notes == 1 then return notify("nothing to save: " .. notes[1]) end
  M.show_report(lines)
  notify(string.format("nothing to save: %d rows changed nothing; the report shows why", #notes))
end

-- The BufWriteCmd of every view buffer. buf is the buffer written; the save
-- covers every modified view.
function M.write(buf)
  if saving then return notify("a save is already in progress", vim.log.levels.WARN) end
  local all = views()
  for _, v in ipairs(all) do
    if v.mod.busy(v.buf) then
      return notify("wait until " .. v.name .. " finishes loading, then save again", vim.log.levels.WARN)
    end
  end
  local saved, records, unloaded = {}, {}, {}
  for _, v in ipairs(all) do
    if vim.bo[v.buf].modified then
      local record = v.mod.record(v.buf)
      if record then
        table.insert(saved, v)
        table.insert(records, record)
      else
        table.insert(unloaded, v.name)
      end
    end
  end
  if #unloaded > 0 then
    notify("not saved, these views never loaded: " .. table.concat(unloaded, ", ") .. "; reload them",
      vim.log.levels.WARN)
  end
  if #records == 0 then
    if #unloaded == 0 then notify("no unsaved edits in the views") end
    return
  end

  saving = true
  local s = session.get()
  plan.prepare(records, s, function(err, prepared)
    if err then
      saving = false
      return
    end
    local p = plan.compute(records, prepared)
    local lines, can_apply = summary.lines(p)
    if #p.ops == 0 and #p.rejections == 0 then
      saving = false
      -- Edits with no effect, such as a row deleted from an area view only
      -- (R5.4), would otherwise stay on screen as if they had been saved.
      for _, v in ipairs(saved) do v.mod.load(v.buf) end
      return nothing_to_save(lines)
    end
    M.confirm(lines, can_apply, function(accepted)
      if not can_apply then
        saving = false
        return notify(string.format("save rejected: %s, nothing was sent; the views keep their edits",
          plural(#p.rejections, "problem")), vim.log.levels.WARN)
      end
      if not accepted then
        saving = false
        return notify("save cancelled; nothing was sent and the views keep their edits")
      end
      run(all, saved, p)
    end)
  end)
end

function M.saving()
  return saving
end

return M
