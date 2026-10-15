-- Item views (plan 0002 UX2.3): separators dimmed, the area row marked and
-- the section headings shown as headings.
if vim.b.current_syntax then return end
vim.cmd([[
syntax match AdoSeparator /│/
syntax match AdoAreaMark /^\/\d\+ \zs▸ .*\/$/
syntax match AdoHeading /^\/\d\+ \zs── .*$/
]])
vim.b.current_syntax = "adoitem"
