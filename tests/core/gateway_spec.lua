local gateway = require("ado.core.gateway")
local Fake = require("tests.support.fake_gateway")

test("validate accepts a gateway with every operation", function()
  local fake = Fake.new(require("tests.fixtures.seed"))
  eq(gateway.validate(fake), fake)
end)

test("validate names the missing operations", function()
  fails(function()
    gateway.validate({ query = function() end })
  end, "missing operations: list_projects, get_work_item")
end)

test("error refuses an unknown kind", function()
  fails(function() gateway.error("oops", "x") end, "unknown gateway error kind")
  eq(gateway.error("auth", "log in", { rev = 3 }), { kind = "auth", message = "log in", rev = 3 })
end)
