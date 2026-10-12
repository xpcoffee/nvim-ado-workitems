local transport = require("ado.core.transport")
local Fake = require("tests.support.fake_transport")

test("validate accepts a transport with every operation", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  eq(transport.validate(fake), fake)
end)

test("validate names the missing operations", function()
  fails(function()
    transport.validate({ query = function() end })
  end, "missing operations: list_projects, get_work_item")
end)

test("error refuses an unknown kind", function()
  fails(function() transport.error("oops", "x") end, "unknown transport error kind")
  eq(transport.error("auth", "log in", { rev = 3 }), { kind = "auth", message = "log in", rev = 3 })
end)
