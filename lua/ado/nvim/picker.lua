-- The Telescope picker for text search. A WIQL query returns full work items
-- in one call, so a static table finder is correct (no async job / batch
-- fetch).
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local browser = require("ado.nvim.browser")
local markup = require("ado.nvim.markup")
local session = require("ado.nvim.session")

local M = {}

-- Picks a valid state for an item with vim.ui.select.
local function pick_state(item, cb)
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

-- id -> markdown description lines, so cursor movement doesn't re-convert.
local preview_cache = {}

local function entry_maker(item)
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
        md = markup.html_to_md(item.description_html)
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

-- opts.on_toggle_states: when set, <C-a> closes the picker and calls it.
local function open_picker(title, items, opts)
  opts = opts or {}
  pickers.new({}, {
    prompt_title = title,
    finder = finders.new_table({ results = items, entry_maker = entry_maker }),
    sorter = conf.generic_sorter({}),
    previewer = make_previewer(),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then require("ado.nvim.layout").open_item(entry.value.id) end
      end)
      map({ "i", "n" }, "<C-s>", function()
        local entry = action_state.get_selected_entry()
        if not entry then return end
        pick_state(entry.value, function(state)
          session.get():update_if_unchanged(entry.value, { state = state }, function(err)
            if err and err.kind == "conflict" then
              vim.notify("[ado] " .. err.message .. "; nothing was changed; reopen the list to see it",
                vim.log.levels.WARN)
            elseif not err then
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
        if entry then browser.open(entry.value.url) end
      end)
      if opts.on_toggle_states then
        map({ "i", "n" }, "<C-a>", function()
          actions.close(prompt_bufnr)
          opts.on_toggle_states()
        end)
      end
      return true
    end,
  }):find()
end

local function run_search(text, all_states)
  session.ensure_project(function(ok)
    if not ok then return end
    session.get():search(text, { all_states = all_states }, function(err, items)
      if err then return end
      local scope = all_states and "all states" or "open"
      -- With no open match the picker still opens, empty, so <C-a> can widen
      -- the search to every state.
      if #items == 0 and all_states then
        vim.notify("[ado] no matches for '" .. text .. "' in any state", vim.log.levels.INFO)
        return
      end
      open_picker(string.format("Search (%s, <C-a> toggles): %s", scope, text), items, {
        on_toggle_states = function() run_search(text, not all_states) end,
      })
    end)
  end)
end

-- Open items only unless opts.all_states (RFC 0002 R1.4); <C-a> re-runs the search in
-- the other mode.
function M.search(opts)
  opts = opts or {}
  vim.ui.input({ prompt = "Search work items: " }, function(text)
    if not text or text == "" then return end
    run_search(text, opts.all_states == true)
  end)
end

return M
