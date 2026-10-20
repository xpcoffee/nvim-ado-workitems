-- Applies a change plan (core/plan.lua) as one write request per work item
-- (core/requests.lua), in order (RFC 0001 R5.14, R5.15, R7.4).
--
-- Revision guard: before an item's request, apply reads the item, with its
-- links, and refuses the request when ADO holds a different rev than the
-- plan was made from. The request itself starts with a test op on that
-- rev, and tests each relation it removes, so ADO refuses it too if the
-- item changes between the read and the write. Each other item the request links to, when the plan holds a rev
-- for it, is read and checked first as well, so a link to P cannot be
-- written before a remote change to P is found. Links leave revs as they
-- were, so a link one request writes does not trip a later check. The
-- first failure stops the run.
local requests = require("ado.core.requests")
local gateway = require("ado.core.gateway")

local M = {}

local function conflict(id, expected, actual)
  return gateway.error("conflict", string.format("#%s changed remotely (rev %s -> %s)", id, tostring(expected),
    tostring(actual)), { expected_rev = expected, actual_rev = actual })
end

-- opts.on_event(event) is told, per request:
--   { kind = "start", index, total, request }
--   { kind = "request", index, total, request, result = "ok" | "failed",
--     rev | error, created = new item id | nil }
-- cb(result), result = { requests = { request... }, completed = { request... },
--   failed = { request, error } | nil, not_attempted = { request... },
--   touched = { id... }, created = { [op] = id } }; touched lists the items
--   that completed and failed requests wrote, both ends of each link, whose
--   views need a reload.
function M.run(session, plan, opts, cb)
  opts = opts or {}
  local emit = opts.on_event or function() end
  local reqs = requests.group(plan.ops)
  local result = { requests = reqs, completed = {}, not_attempted = {}, touched = {}, created = {} }
  local touched = {}

  local expected = {}
  for _, req in ipairs(reqs) do
    if req.id and req.expect_rev ~= nil then expected[req.id] = req.expect_rev end
  end
  local checked = {}

  local function touch(id)
    if id and not touched[id] then
      touched[id] = true
      table.insert(result.touched, id)
    end
  end

  -- Reads each of ids that has an expected rev and is not checked yet.
  -- cb2(err, id) on the first conflict.
  local function guard(ids, i, cb2)
    local id = ids[i]
    if i > #ids then return cb2(nil) end
    if checked[id] or expected[id] == nil then return guard(ids, i + 1, cb2) end
    checked[id] = true
    session:check_rev({ id = id, rev = expected[id] }, function(err)
      if err then return cb2(err, id) end
      guard(ids, i + 1, cb2)
    end)
  end

  -- Writes one request. cb2(err, rev, created).
  local function write(req, cb2)
    if req.create then
      return session:create(req.create, function(err, item)
        if err then return cb2(err) end
        cb2(nil, item.rev, item.id)
      end)
    end
    checked[req.id] = true
    session:get_with_relations(req.id, function(err, item)
      if err then return cb2(err) end
      local rev = expected[req.id]
      if rev ~= nil and item.rev ~= rev then return cb2(conflict(req.id, rev, item.rev)) end
      local patch, perr = requests.patch(req, item.raw, session.org, rev or item.rev)
      if not patch then return cb2(perr) end
      session:patch(req.id, patch, function(werr, written)
        if werr and werr.kind == "conflict" then
          return cb2(gateway.error("conflict", string.format(
            "#%d changed remotely after it was read at rev %s, so ADO wrote nothing to it (%s)",
            req.id, tostring(rev or item.rev), tostring(werr.message))))
        end
        if werr then return cb2(werr) end
        cb2(nil, written.rev)
      end)
    end)
  end

  local function step(i)
    if i > #reqs then return cb(result) end
    local req = reqs[i]
    emit({ kind = "start", index = i, total = #reqs, request = req })
    local others = requests.targets(req)
    local function fail(err, conflicted)
      touch(conflicted)
      result.failed = { request = req, error = err }
      emit({ kind = "request", index = i, total = #reqs, request = req, result = "failed", error = err })
      for j = i + 1, #reqs do table.insert(result.not_attempted, reqs[j]) end
      cb(result)
    end
    guard(others, 1, function(gerr, conflicted)
      if gerr then return fail(gerr, conflicted) end
      write(req, function(err, rev, created)
        touch(req.id)
        for _, id in ipairs(others) do touch(id) end
        if err then return fail(err) end
        if created then
          result.created[req.create] = created
          touch(created)
        end
        table.insert(result.completed, req)
        emit({ kind = "request", index = i, total = #reqs, request = req, result = "ok", rev = rev,
          created = created })
        step(i + 1)
      end)
    end)
  end
  step(1)
end

return M
