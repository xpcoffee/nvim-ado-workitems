-- Telescope pickers for work-item lists. A WIQL query returns full work items in
-- one call, so a static table finder is correct (no async job / batch fetch).
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local client = require("ado.client")
local config = require("ado.config")
local wiql = require("ado.wiql")
local workitem = require("ado.workitem")

local M = {}

-- id -> markdown description lines, so cursor movement doesn't re-convert.
local preview_cache = {}

local function entry_maker(raw)
  local item = workitem.normalise(raw)
  return {
    value = item,
    ordinal = item.id .. " " .. item.title,
    display = string.format("#%s [%s] %s", item.id, item.state, item.title),
  }
end

local function make_previewer()
  return previewers.new_buffer_previewer({
    title = "Work item",
    define_preview = function(self, entry)
      local pbuf = self.state.bufnr
      local item = entry.value
      local md = preview_cache[item.id]
      if not md then
        md = workitem.html_to_md(item.description_html)
        preview_cache[item.id] = md
      end
      if not vim.api.nvim_buf_is_valid(pbuf) then return end
      local lines = {
        string.format("#%s  %s  %s", item.id, item.type, item.state),
        "Assignee: " .. item.assignee_display,
        "Tags:     " .. item.tags,
        "",
        "## Description",
      }
      vim.list_extend(lines, md)
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
      vim.bo[pbuf].filetype = "markdown"
    end,
  })
end

local function open_picker(title, items)
  pickers.new({}, {
    prompt_title = title,
    finder = finders.new_table({ results = items, entry_maker = entry_maker }),
    sorter = conf.generic_sorter({}),
    previewer = make_previewer(),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then workitem.open(entry.value.id) end
      end)
      map({ "i", "n" }, "<C-s>", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        workitem.pick_state(entry.value, function(state)
          client.update(entry.value.id, { state = state }, function(ok)
            if ok then
              vim.notify(string.format("[ado] #%s -> %s", entry.value.id, state), vim.log.levels.INFO)
            end
          end)
        end)
      end)
      map({ "i", "n" }, "<C-y>", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        vim.fn.setreg("+", string.format("#%s %s", entry.value.id, entry.value.url))
        vim.notify("[ado] yanked #" .. entry.value.id, vim.log.levels.INFO)
      end)
      map({ "i", "n" }, "<C-o>", function()
        local entry = action_state.get_selected_entry()
        if entry then workitem.browser_open(entry.value.url) end
      end)
      return true
    end,
  }):find()
end

-- az boards query returns a bare array; cap client-side (no --top on the CLI).
local function to_items(data)
  local list = data
  if type(data) == "table" and data.value then list = data.value end
  local cap = config.get().default_query_top or 200
  local out = {}
  for i, raw in ipairs(list) do
    if i > cap then break end
    table.insert(out, raw)
  end
  return out
end

function M.my_items()
  client.ensure_project(function(ok)
    if not ok then return end
    client.query(wiql.my_items(), function(ok2, data)
      if not ok2 then return end
      local items = to_items(data)
      if #items == 0 then
        vim.notify("[ado] no open items assigned to you", vim.log.levels.INFO)
        return
      end
      open_picker("My work items", items)
    end)
  end)
end

function M.search()
  vim.ui.input({ prompt = "Search work items: " }, function(text)
    if not text or text == "" then return end
    client.ensure_project(function(ok)
      if not ok then return end
      client.query(wiql.text_search(text), function(ok2, data)
        if not ok2 then return end
        local items = to_items(data)
        if #items == 0 then
          vim.notify("[ado] no matches for '" .. text .. "'", vim.log.levels.INFO)
          return
        end
        open_picker("Search: " .. text, items)
      end)
    end)
  end)
end

return M
