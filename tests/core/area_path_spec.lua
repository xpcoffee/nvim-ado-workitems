local area_path = require("ado.core.area_path")

-- tests/fixtures/az/area_children_platform.json is the trimmed
-- az boards area project list response recorded in the phase 2 route check.
local FIXTURE_CHILD = "\\Example\\Area\\Software\\Platform\\Team A"
local FIELD = "Example\\Software\\Platform\\Team A"

test("node paths drop the Area segment in the field form, and back", function()
  eq(area_path.from_node(FIXTURE_CHILD), FIELD)
  eq(area_path.to_node(FIELD), FIXTURE_CHILD)
  eq(area_path.from_node("\\Example\\Area"), "Example")
  eq(area_path.to_node("Example"), "\\Example\\Area")
  eq(area_path.from_node("\\Example\\Software"), nil, "not a node path")
end)

test("config and URIs may use / for \\, and stray separators are dropped", function()
  eq(area_path.normalise("Example/Software/Platform/"), "Example\\Software\\Platform")
  eq(area_path.normalise("\\P\\Team\\"), "P\\Team")
  eq(area_path.to_uri(FIELD), "Example/Software/Platform/Team A")
  eq(area_path.normalise(""), nil)
  eq(area_path.normalise(nil), nil)
end)

test("project, name, join and parent", function()
  eq(area_path.project(FIELD), "Example")
  eq(area_path.name(FIELD), "Team A")
  eq(area_path.join("P/Team", "A"), "P\\Team\\A")
  eq(area_path.parent(FIELD), "Example\\Software\\Platform")
  eq(area_path.parent("P\\Team"), "P")
end)

test("the parent area of a project's root area is none", function()
  eq(area_path.parent("Example"), nil)
end)
