-- People candidates and search for the assignee menu (plan 0002 UX6.1 to
-- UX6.4), against the fake gateway.
local Fake = require("tests.support.fake_gateway")
local people = require("ado.core.people")
local plan = require("ado.core.plan")
local seed = require("tests.fixtures.seed")
local session = require("ado.core.session")

local function new()
  local fake = Fake.new(seed)
  local s = session.new({ gateway = fake, org = "test-org", project = "P" })
  return s:people(), fake, s
end

local function emails(list)
  local out = {}
  for i, p in ipairs(list) do out[i] = p.unique_name end
  return out
end

local function calls(fake)
  return fake.counts.resolve_identity or 0
end

test("UX6.2 matching ignores case and accepts the start of the name, of any word in it, or of the email", function()
  local janet = { display_name = "Janet Doe", unique_name = "janet.doe@example.com" }
  ok(people.matches(janet, "jan"))
  ok(people.matches(janet, "DOE"), "a later word")
  ok(people.matches(janet, "janet.d"), "the email")
  ok(people.matches(janet, "janet d"), "the name across a space")
  ok(people.matches(janet, ""), "an empty text matches everyone")
  ok(not people.matches(janet, "et"), "not the middle of a word")
  ok(not people.matches(janet, "example"), "not the middle of the email")
end)

test("Session:people() is one search per session, so its cache lasts the session", function()
  local p, _, s = new()
  eq(s:people() == p, true)
end)

test("UX6.4 a cached prefix makes 0 calls", function()
  local p, fake = new()
  p:search("Alex", {}, function() end)
  eq(calls(fake), 1)
  local info
  p:search("alex", {}, function(err, found, i)
    eq(err, nil)
    eq(emails(found), { "alex.smith@example.com", "alex.jones@example.com" })
    info = i
  end)
  eq(calls(fake), 1, "the answer to Alex is cached for alex")
  eq(info.calls, 0)
end)

test("UX6.4 a search already in flight for the same text is joined, not repeated", function()
  local p, fake = new()
  fake.mode = "deferred"
  local answers = 0
  p:search("al", {}, function() answers = answers + 1 end)
  p:search("al", {}, function(err, found, info)
    eq(err, nil)
    eq(#found, 2)
    eq(info.calls, 0)
    answers = answers + 1
  end)
  eq(calls(fake), 1)
  fake:flush()
  eq(answers, 2)
end)

test("UX6.4 a shorter cached prefix is filtered and offered while the longer search runs", function()
  local p, fake = new()
  p:search("al", {}, function() end)
  fake.mode = "deferred"
  local done = false
  p:search("alex s", {}, function() done = true end)
  eq(calls(fake), 2, "the longer search still runs")
  eq(emails(p:candidates("alex s", {})), { "alex.smith@example.com" })
  fake:flush()
  ok(done)
  eq(emails(p:candidates("alex s", {})), { "alex.smith@example.com" })
end)

test("UX6.3 a late answer to an older prefix is marked stale, and still cached", function()
  local p, fake = new()
  fake.mode = "deferred"
  local seen = {}
  p:search("al", {}, function(_, found, info) seen.al = { n = #found, stale = info.stale } end)
  p:search("alex j", {}, function(_, found, info) seen.alexj = { n = #found, stale = info.stale } end)
  fake:flush()
  eq(seen.al, { n = 2, stale = true })
  eq(seen.alexj, { n = 1, stale = false })
  eq(emails(p:candidates("al", {})), { "alex.smith@example.com", "alex.jones@example.com" })
end)

test("UX6.2 two people with the same name both appear, told apart by email", function()
  local p, fake = new()
  table.insert(fake.seed.identities, { display_name = "Alex Smith", unique_name = "alex.smith2@example.com", id = "u-2" })
  p:search("alex smith", {}, function() end)
  local list = p:candidates("alex smith", {})
  eq(emails(list), { "alex.smith@example.com", "alex.smith2@example.com" })
  eq({ list[1].display_name, list[2].display_name }, { "Alex Smith", "Alex Smith" })
end)

test("UX6.1 a person both on a loaded row and found by ADO appears once, as local", function()
  local p = new()
  p:search("alex", {}, function() end)
  local list = p:candidates("alex", { { display_name = "Alex Jones", unique_name = "Alex.Jones@example.com" } })
  eq(emails(list), { "Alex.Jones@example.com", "alex.smith@example.com" })
  eq({ list[1].source, list[2].source }, { "local", "ado" })
end)

test("UX6.1 ranking: picked earlier (most recent first), then loaded rows by name, then ADO", function()
  local p = new()
  p:search("a", {}, function() end)
  p:picked({ display_name = "Me Myself", unique_name = "me@example.com" })
  p:picked({ display_name = "Alex Smith", unique_name = "alex.smith@example.com" })
  local locals = {
    { display_name = "Zed Local", unique_name = "zed@example.com" },
    { display_name = "Ann Local", unique_name = "ann@example.com" },
  }
  eq(emails(p:candidates("", locals)), { "alex.smith@example.com", "me@example.com", "ann@example.com",
    "zed@example.com" })
  eq(emails(p:candidates("a", locals)), { "alex.smith@example.com", "ann@example.com", "alex.jones@example.com" })
  p:picked({ display_name = "Me Myself", unique_name = "ME@example.com" })
  eq(emails(p:candidates("", {})), { "ME@example.com", "alex.smith@example.com" }, "one entry per email")
end)

test("UX6.5 each of the seed's two identities matching Alex, inserted as its email, resolves to one identity", function()
  local p, _, s = new()
  local list
  p:search("Alex", {}, function(_, found) list = found end)
  eq(#list, 2)
  for _, person in ipairs(list) do
    s:resolve_identity(person.unique_name, function(err, found)
      eq(err, nil)
      local who, problem = plan.choose_identity(found, person.unique_name)
      eq(problem, nil)
      eq(who.unique_name, person.unique_name)
    end)
  end
end)

test("UX6.7 a quiet search passes quiet to the gateway; a failure is not cached", function()
  local p, fake = new()
  fake:fail_on("resolve_identity", 1)
  local got
  p:search("al", { quiet = true }, function(err) got = err end)
  eq(got.kind, "failed")
  eq(fake.calls[1].params, { text = "al", quiet = true })
  p:search("al", {}, function(err, found)
    eq(err, nil)
    eq(#found, 2)
  end)
  eq(calls(fake), 2, "the failure was not cached")
  eq(fake.calls[2].params, { text = "al" })
end)
