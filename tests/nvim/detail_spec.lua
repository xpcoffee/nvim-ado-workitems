-- The detail buffer on the fake transport: render, edit a field through its
-- float, the rev guard, reload, state and comment.
local Fake = require("tests.support.fake_transport")
local seed = require("tests.fixtures.seed")

local function key(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Fresh fake, session and buffers per test; pandoc is reported absent so the
-- description renders as raw text without starting a process.
local function fresh()
  vim.cmd("silent! %bwipeout!")
  local fake = Fake.new(seed)
  require("ado.config").setup({ transport = fake, org = "test-org", project = "P" })
  require("ado.nvim.session").reset()
  local executable = vim.fn.executable
  vim.fn.executable = function(name)
    if name == "pandoc" then return 0 end
    return executable(name)
  end
  local notes = {}
  vim.notify = function(msg, level) table.insert(notes, { msg = msg, level = level }) end
  local detail = require("ado.nvim.detail")
  return fake, detail, notes
end

local function open(detail, id)
  detail.open(id)
  return vim.api.nvim_get_current_buf()
end

test("open renders the item read-only in ado://<id>", function()
  local fake, detail = fresh()
  local buf = open(detail, 103)
  eq(vim.api.nvim_buf_get_name(buf), "ado://103")
  eq(vim.bo[buf].modifiable, false)
  eq(vim.bo[buf].filetype, "adoitem")
  eq(lines(buf), {
    "# 103  Task  To Do",
    "Title:     Fix login",
    "State:     To Do",
    "Assignee:  Me Myself <me@example.com>",
    "Tags:      ",
    "Iteration: P",
    "---",
    "Area:      P\\Team\\A",
    "Changed:   2026-10-04",
    "Rev:       1",
    "URL:       https://dev.azure.com/test-org/P/_workitems/edit/103",
    "---",
    "## Description",
    "<p>Login fails after the <b>token</b> refresh.</p>",
  })
  eq(#fake.calls, 1)
  eq(fake.calls[1].op, "get_work_item")
end)

test("<CR> on the title opens a float; confirming writes once and re-renders", function()
  local fake, detail, notes = fresh()
  local buf = open(detail, 101)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  key("<CR>")
  local float_buf = vim.api.nvim_get_current_buf()
  ok(float_buf ~= buf, "a float buffer is focused")
  eq(lines(float_buf), { "Write API" })
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { "Write the API" })
  key("<CR>")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(#fake.writes, 1)
  eq(fake.writes[1].params, { id = 101, fields = { ["System.Title"] = "Write the API" } })
  eq(lines(buf)[2], "Title:     Write the API")
  eq(lines(buf)[10], "Rev:       2")
  eq(notes[#notes].msg, "[ado] updated #101")
end)

test("a remote change blocks the write with the reload warning", function()
  local fake, detail, notes = fresh()
  open(detail, 101)
  fake:edit_remotely(101, { ["System.Title"] = "Theirs" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  key("<CR>")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Mine" })
  key("<CR>")
  eq(#fake.writes, 0)
  eq(notes[#notes], {
    msg = "[ado] #101 changed remotely (rev 1 -> 2); reload (,wr) before saving",
    level = vim.log.levels.WARN,
  })
end)

test("<leader>wr reloads from ADO", function()
  local fake, detail = fresh()
  local buf = open(detail, 101)
  fake:edit_remotely(101, { ["System.Title"] = "Theirs" })
  key("<leader>wr")
  eq(lines(buf)[2], "Title:     Theirs")
  eq(lines(buf)[10], "Rev:       2")
end)

test("state edit picks from the type's states and writes the choice", function()
  local fake, detail = fresh()
  local buf = open(detail, 101)
  local offered
  vim.ui.select = function(items, _, on_choice)
    offered = items
    on_choice("Doing")
  end
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  key("<CR>")
  eq(offered, { "To Do", "Doing", "Done", "Discarded" })
  eq(fake.writes[1].params, { id = 101, fields = { ["System.State"] = "Doing" } })
  eq(lines(buf)[3], "State:     Doing")
end)

test("a failed write is reported once and leaves the buffer as it was", function()
  local fake, detail, notes = fresh()
  local buf = open(detail, 101)
  fake:fail_on("update_fields", 1, { kind = "failed", message = "boom" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  key("<CR>")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Changed" })
  key("<CR>")
  eq(lines(buf)[2], "Title:     Write API")
  eq(notes, { { msg = "[ado] boom", level = vim.log.levels.ERROR } })
end)

test("<leader>wc adds a comment", function()
  local fake, detail, notes = fresh()
  open(detail, 103)
  vim.ui.input = function(_, on_confirm) on_confirm("looking into it") end
  key("<leader>wc")
  eq(fake.comments[103], { "looking into it" })
  eq(notes[#notes].msg, "[ado] commented on #103")
end)
