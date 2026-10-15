-- Area views and query lists (plan 0002 UX2.3): separators dimmed and
-- sub-area rows marked. Syntax rules cost nothing per edit, unlike the
-- extmarks of nvim/decorations.lua.
if vim.b.current_syntax then return end
vim.cmd([[
syntax match AdoSeparator /│/
syntax match AdoAreaMark /^\/\d\+ \zs▸ .*\/$/
]])
vim.b.current_syntax = "adoarea"
