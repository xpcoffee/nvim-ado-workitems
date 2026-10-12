local location = require("ado.core.location")

test("an area location takes default filters", function()
  eq(location.area("P/Team"), {
    kind = "area", path = "P\\Team",
    filters = { state = "open" }, sub = false,
  })
end)

test("the buffer name round-trips every filter", function()
  local loc = location.area("Example\\Platform\\Team A", {
    state = { "New", "Won't fix, ever" }, assignee = "@Me", types = { "Task", "User Story" }, tag = "a&b=c",
  }, true)
  local uri = location.uri(loc)
  eq(uri, "ado://area/Example/Platform/Team A"
    .. "?state=New,Won't fix%2C ever&type=Task,User Story&assignee=@Me&tag=a%26b%3Dc&sub=1")
  eq(location.parse(uri), loc)
end)

test("the default location's buffer name", function()
  local loc = location.area("P\\Team")
  eq(location.uri(loc), "ado://area/P/Team?state=open&type=&assignee=&tag=&sub=0")
  eq(location.parse(location.uri(loc)), loc)
  eq(location.parse("ado://103"), nil)
end)

test("at, with_filters and with_sub keep everything else", function()
  local loc = location.area("P\\Team", { assignee = "@Me", tag = "api" }, true)
  local child = location.at(loc, "P\\Team\\A")
  eq(child.path, "P\\Team\\A")
  eq(child.filters, loc.filters)
  eq(child.sub, true)
  local f = location.with_filters(loc, { tag = false, state = "all" })
  eq(f.filters, { state = "all", assignee = "@Me" })
  eq(location.with_sub(loc, false).sub, false)
  eq(loc.filters.tag, "api", "the original is unchanged")
end)

test("describe names every filter for the window bar", function()
  eq(location.describe(location.area("P", { assignee = "@Me", types = { "Bug" } })),
    "state: open  ·  assignee: @Me  ·  type: Bug  ·  tag: any  ·  sub-areas: excluded")
end)

test("an item location round-trips its URI; its buffer name leaves out the toggle", function()
  local loc = location.item(1234)
  eq(loc, { kind = "item", id = 1234, all = false })
  eq(location.uri(loc), "ado://item/1234?all=0")
  eq(location.uri(location.with_all(loc, true)), "ado://item/1234?all=1")
  eq(location.parse("ado://item/1234?all=1"), location.item(1234, true))
  eq(location.parse("ado://item/1234"), loc)
  eq(location.buffer_name(location.item(1234, true)), "ado://item/1234")
  eq(location.item("12"), location.item(12))
  eq(location.item("x"), nil)
  eq(location.item(0), nil)
  ok(not location.equal(loc, location.with_all(loc, true)), "the toggle is part of the location")
end)
