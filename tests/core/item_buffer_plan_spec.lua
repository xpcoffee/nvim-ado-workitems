-- The change plan for an item buffer (RFC 0003): the read-only region and
-- the boundary row (C2.1 to C2.3), and a staged description in the item's
-- one patch (C3.3, C7.5).
local Fake = require("tests.support.fake_gateway")
local apply = require("ado.core.apply")
local item_details = require("ado.core.item_details")
local records = require("tests.support.records")
local requests = require("ado.core.requests")
local summary = require("ado.core.summary")
local timestamp = require("ado.core.timestamp")

local new, item = records.new, records.item
local item_line, heading = records.item_line, records.heading
local compute, messages, texts = records.compute, records.messages, records.texts

local function boundary(v)
  return heading(v, "boundary")
end

test("C2.2 a changed read-only region rejects the plan and plans nothing, whatever else changed", function()
  local s = new()
  local v = item(s, 100)
  item_line(v, 100).title = "Checkout story now"
  v.readonly_changed = 14
  local p = compute(s, { v })
  eq(#p.ops, 1, "the title edit is still planned, but the plan is rejected")
  eq(messages(p.rejections), { "line 14 in ado://item/100: the details and comments are read-only;"
    .. " u undoes the change, <leader>wr reloads" })
  local _, can_apply = summary.lines(p)
  eq(can_apply, false)
end)

test("C2.3 a deleted boundary row rejects as a deleted fixed line", function()
  local s = new()
  local v = item(s, 100)
  records.delete(v, boundary(v))
  local p = compute(s, { v })
  eq(#p.rejections, 1)
  ok(p.rejections[1].message:find("this line was deleted", 1, true), p.rejections[1].message)
end)

test("C2.3 a boundary row moved above the link section rejects as a moved fixed line", function()
  local s = new()
  local v = item(s, 100)
  local b = boundary(v)
  records.delete(v, b)
  table.insert(v.current, 4, b)
  for i, c in ipairs(v.current) do c.line = i end
  local p = compute(s, { v })
  ok(#p.rejections >= 1)
  ok(messages(p.rejections)[1]:find("this line was moved", 1, true), messages(p.rejections)[1])
end)

test("C2.1 a row after the boundary row rejects, and adds no link", function()
  local s = new()
  local v = item(s, 100)
  records.paste(v, records.yank(v, 101), boundary(v))
  local p = compute(s, { v })
  eq(#p.ops, 0)
  ok(messages(p.rejections)[1]:find("rows cannot be pasted below the Details line", 1, true),
    messages(p.rejections)[1])
end)

test("C3.3 C7.5 a staged description is one field update in the item's one request, after a test on /rev", function()
  local s, fake = new()
  local v = item(s, 100)
  item_line(v, 100).title = "Checkout story now"
  v.description = { html = "<p>Pay at checkout.</p>", added = 1, removed = 1 }
  local p = compute(s, { v })
  eq(p.rejections, {})
  local d = p.ops[#p.ops]
  eq({ d.kind, d.id, d.field, d.name, d.from, d.to, d.expect_rev },
    { "update", 100, "System.Description", "description", "<p>Let customers pay at checkout.</p>",
      "<p>Pay at checkout.</p>", 1 })
  eq(texts(summary.lines(p)), { "Save 2 changes to Azure DevOps?", "Field changes",
    "  #100 title: 'Checkout story' -> 'Checkout story now'",
    "  #100 description changed: 1 line added, 1 line removed" })
  local reqs = requests.group(p.ops)
  eq(#reqs, 1)
  local patch = requests.patch(reqs[1], fake.items[100], "test-org", reqs[1].expect_rev)
  eq(patch, {
    { op = "test", path = "/rev", value = 1 },
    { op = "add", path = "/fields/System.Title", value = "Checkout story now" },
    { op = "add", path = "/fields/System.Description", value = "<p>Pay at checkout.</p>" },
  })
  local result
  apply.run(s, p, {}, function(r) result = r end)
  eq(result.failed, nil)
  eq(#fake.writes, 1)
  eq(fake.items[100].fields["System.Description"], "<p>Pay at checkout.</p>")
  eq(fake.items[100].fields["System.Title"], "Checkout story now")
end)

test("a description staged on an item changed remotely is refused whole by the rev test", function()
  local s, fake = new()
  local v = item(s, 100)
  v.description = { html = "<p>Pay.</p>", added = 1, removed = 1 }
  fake:edit_remotely(100, { ["System.Title"] = "Renamed elsewhere" })
  local result
  apply.run(s, compute(s, { v }), {}, function(r) result = r end)
  ok(result.failed, "the request failed")
  eq(fake.items[100].fields["System.Description"], "<p>Let customers pay at checkout.</p>")
end)

test("C3.1 the details: changed with rev, then the description indented, or none", function()
  local item = { rev = 17, changed_at = "2026-10-15T14:02:33.12Z" }
  local out, range = item_details.lines(item, { "The export writes one file.", "", "-   CSV first." })
  eq(out, { "    changed:   2026-10-15 14:02 · rev 17", "    description:", "    The export writes one file.", "",
    "    -   CSV first." })
  eq(range, { first = 2, last = 5 })
  out, range = item_details.lines(item, { "" })
  eq(out, { "    changed:   2026-10-15 14:02 · rev 17", "    description: (none)" })
  eq(range, { first = 2, last = 2 })
end)

test("long description lines wrap at spaces to the width, keeping a list item's indent", function()
  eq(item_details.wrap("one two three four", 9), { "one two", "three", "four" })
  eq(item_details.wrap("  - alpha beta gamma", 12), { "  - alpha", "    beta", "    gamma" })
  eq(item_details.wrap("1. alpha beta", 9), { "1. alpha", "   beta" })
  eq(item_details.wrap("short", 40), { "short" })
  eq(item_details.wrap("averyveryverylongword x", 5), { "averyveryverylongword", "x" })
  eq(item_details.indented({ "one two three" }, 11), { "    one two", "    three" })
end)

test("timestamps parse to epoch seconds, with offsets applied, and format to the minute", function()
  eq(timestamp.parse("1970-01-01T00:00:00Z"), 0)
  eq(timestamp.parse("2026-10-15T14:02:33.1234567Z"), 1792072953)
  eq(timestamp.utc_minute(timestamp.parse("2024-02-29T23:59:00+01:00")), "2024-02-29 22:59")
  eq(timestamp.parse("2026-10-15"), nil)
  eq(item_details.time("not a date"), "not a date")
end)
