local Fake = require("tests.support.fake_transport")
local seed = require("tests.fixtures.seed")
local write_guard = require("ado.core.write_guard")

-- Seed areas: 101 and 111 (an Issue) are in P\Team\A; 104 is in P\Team\B.
local function guarded(opts)
  local fake = Fake.new(seed)
  local created = {}
  fake.create_work_item = function(params, cb)
    table.insert(created, params)
    cb(nil, { id = 900, rev = 1, fields = {} })
  end
  local g = write_guard.wrap(fake, opts or { area = "P\\Team\\A" })
  return g, fake, created
end

local function ops(fake)
  local out = {}
  for _, c in ipairs(fake.calls) do table.insert(out, c.op) end
  return out
end

local function result_of(g, op, params)
  local err, result
  g[op](params, function(e, r) err, result = e, r end)
  return err, result
end

test("reads pass through unchanged", function()
  local g, fake = guarded()
  local _, raw = result_of(g, "get_work_item", { id = 104 })
  eq(raw.id, 104)
  local _, names = result_of(g, "list_projects", {})
  eq(names, { "P" })
  eq(ops(fake), { "get_work_item", "list_projects" })
end)

test("a write inside the area reaches the transport", function()
  local g, fake = guarded()
  local err, raw = result_of(g, "update_fields", { id = 101, fields = { ["System.Title"] = "x" } })
  eq(err, nil)
  eq(raw.rev, 2)
  eq(ops(fake), { "get_work_item", "update_fields" })
end)

test("a write outside the area is refused with zero writes", function()
  local g, fake = guarded()
  local err = result_of(g, "update_fields", { id = 104, fields = { ["System.Title"] = "x" } })
  eq(err.kind, "invalid")
  ok(err.message:find("#104 is in area 'P\\Team\\B', outside 'P\\Team\\A'", 1, true), err.message)
  eq(#fake.writes, 0)
  eq(ops(fake), { "get_work_item" }, "only the guard's own read")
end)

test("a write to an Issue is refused with zero writes", function()
  local g, fake = guarded()
  local err = result_of(g, "update_fields", { id = 111, fields = { ["System.Title"] = "x" } })
  ok(err.message:find("#111 is of type Issue", 1, true), err.message)
  err = result_of(g, "add_comment", { id = 111, text = "hi" })
  ok(err.message:find("#111 is of type Issue", 1, true), err.message)
  eq(#fake.writes, 0)
end)

test("changing a type to Issue is refused with zero transport calls", function()
  local g, fake = guarded()
  local err = result_of(g, "update_fields", { id = 101, fields = { ["System.WorkItemType"] = "issue" } })
  ok(err.message:find("changing a type to issue", 1, true), err.message)
  eq(#fake.calls, 0)
end)

test("moving an item out of the area is refused with zero transport calls", function()
  local g, fake = guarded()
  local err = result_of(g, "update_fields", { id = 101, fields = { ["System.AreaPath"] = "P\\Team\\B" } })
  ok(err.message:find("new area 'P\\Team\\B' is outside", 1, true), err.message)
  eq(#fake.calls, 0)
end)

test("sub-areas are allowed; a sibling sharing the prefix is not", function()
  local g, fake = guarded({ area = "P/Team" })
  eq(result_of(g, "update_fields", { id = 104, fields = { ["System.Title"] = "x" } }), nil)
  fake:edit_remotely(101, { ["System.AreaPath"] = "P\\TeamX" })
  local err = result_of(g, "update_fields", { id = 101, fields = { ["System.Title"] = "x" } })
  eq(err.kind, "invalid")
  eq(#fake.writes, 1)
end)

test("creates need an allowed area and a type other than Issue, checked without calls", function()
  local g, fake, created = guarded()
  local err = result_of(g, "create_work_item", { type = "Issue", title = "t", area = "P\\Team\\A" })
  ok(err.message:find("type Issue", 1, true), err.message)
  err = result_of(g, "create_work_item", { type = "Task", title = "t", area = "P\\Team\\B" })
  ok(err.message:find("area 'P\\Team\\B' is outside", 1, true), err.message)
  err = result_of(g, "create_work_item", { type = "Task", title = "t" })
  eq(err.kind, "invalid")
  eq(#created, 0)
  eq(#fake.calls, 0)
  eq(result_of(g, "create_work_item", { type = "Task", title = "t", area = "P\\Team\\A\\New" }), nil)
  eq(#created, 1)
end)

test("a link write checks both ends", function()
  local g, fake = guarded()
  local refusal_seen
  fake.add_link = function(_, cb) cb(nil, {}) end
  g = write_guard.wrap(fake, { area = "P\\Team\\A" })
  g.add_link({ id = 101, rel = "related", target = 104 }, function(err) refusal_seen = err end)
  ok(refusal_seen and refusal_seen.message:find("#104", 1, true))
  eq(ops(fake), { "get_work_item", "get_work_item" })
end)

test("an operation the guard has no rule for is refused", function()
  local g = write_guard.wrap({ delete_everything = function() error("must not run") end }, { area = "P" })
  local err = result_of(g, "delete_everything", {})
  ok(err.message:find("no rule for this operation", 1, true))
end)

test("with no area configured every write is refused", function()
  local g, fake = guarded({})
  local err = result_of(g, "update_fields", { id = 101, fields = { ["System.Title"] = "x" } })
  ok(err.message:find("no allowed area", 1, true))
  eq(#fake.calls, 0)
end)

test("a failed read refuses the write", function()
  local g, fake = guarded()
  fake:fail_on("get_work_item", 1, { kind = "auth", message = "expired" })
  local err = result_of(g, "update_fields", { id = 101, fields = { ["System.Title"] = "x" } })
  ok(err.message:find("could not read #101: expired", 1, true), err.message)
  eq(#fake.writes, 0)
end)

test("works with deferred callbacks", function()
  local g, fake = guarded()
  fake.mode = "deferred"
  async(fake, function(done)
    g.update_fields({ id = 104, fields = { ["System.Title"] = "x" } }, function(err)
      eq(err.kind, "invalid")
      done()
    end)
  end)
  eq(#fake.writes, 0)
end)

-- Adding an operation to the transport without deciding how the guard treats
-- it would leave it refused for every caller.
test("every transport operation is either a read or has a write check", function()
  local transport = require("ado.core.transport")
  local all = {}
  for _, op in ipairs(transport.OPERATIONS) do all[op] = true end
  for op in pairs(transport.WRITES) do all[op] = true end
  local stub = {}
  for op in pairs(all) do
    stub[op] = function(_, cb)
      cb(nil, { id = 1, rev = 1, fields = { ["System.AreaPath"] = "P\\A", ["System.WorkItemType"] = "Task" } })
    end
  end
  local g = write_guard.wrap(stub, { area = "P\\A" })
  local unruled = {}
  for op in pairs(all) do
    local err = result_of(g, op, { id = 1, target = 2, area = "P\\A", type = "Task", fields = {} })
    if err and err.message:find("has no rule", 1, true) then table.insert(unruled, op) end
  end
  table.sort(unruled)
  eq(unruled, {})
end)
