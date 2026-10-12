test("a module that reads vim fails to load", function()
  fails(function() require("tests.fixtures.sandbox.reads_vim") end, "core referenced global 'vim'")
end)

test("a module that reads vim through _G fails to load", function()
  fails(function() require("tests.fixtures.sandbox.reads_g_vim") end, "core referenced global 'vim'")
end)

test("a module that requires ado.nvim.az fails to load", function()
  fails(function() require("tests.fixtures.sandbox.requires_nvim") end, "require%('ado.nvim.az'%) is not allowed")
end)

test("the spec itself cannot read vim", function()
  fails(function() return vim.api end, "core referenced global 'vim'")
end)

test("eq reports the path of the first difference", function()
  fails(function() eq({ a = { b = 1 } }, { a = { b = 2 } }) end, "differs at value%.a%.b")
end)
