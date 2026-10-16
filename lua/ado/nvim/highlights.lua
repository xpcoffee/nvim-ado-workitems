-- The views' highlight groups (plan 0002 UX2.1, UX2.2). Each Ado* group
-- links to a standard group by default, so a colour scheme colours the
-- views without knowing them, and a user can override any of them. ADO's
-- own type and state colours get one group per colour, AdoColor_<hex>.
local M = {}

M.LINKS = {
  AdoType = "Type",
  AdoState = "Constant",
  AdoSeparator = "NonText",
  AdoAreaMark = "Directory",
  AdoHeading = "Title",
  AdoChanged = "Changed",
  AdoNew = "Added",
  AdoCount = "Comment",
  AdoCommentHeading = "Title",
  AdoCommentText = "Normal",
}

-- hex -> true, for every AdoColor_ group made this session.
local made = {}
local did_setup = false

local function define_links()
  for group, link in pairs(M.LINKS) do vim.api.nvim_set_hl(0, group, { link = link, default = true }) end
end

local function define_color(hex)
  vim.api.nvim_set_hl(0, "AdoColor_" .. hex, { fg = "#" .. hex })
end

-- :colorscheme clears every group first, so they are defined again after it.
function M.setup()
  if did_setup then return end
  did_setup = true
  define_links()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("ado_highlights", { clear = true }),
    callback = function()
      define_links()
      for hex in pairs(made) do define_color(hex) end
    end,
  })
end

-- The group drawing ADO colour hex (six hex digits), or fallback when
-- there is no colour or the terminal draws no RGB colours.
function M.color(hex, fallback)
  if not hex or not vim.o.termguicolors then return fallback end
  if not made[hex] then
    made[hex] = true
    define_color(hex)
  end
  return "AdoColor_" .. hex
end

return M
