-- tests/fixtures/seed.lua with titles, tags and an assignee long enough to
-- be cut in a 60 or 78 column window (plan 0002 phase 5).
local seed = vim.deepcopy(require("tests.fixtures.seed"))

local LONG = {
  [101] = { title = "Write the public API for the checkout service and document every endpoint",
    tags = "api; backend; checkout; documentation" },
  [102] = { title = "Add integration tests for the payment provider callbacks and retries" },
  [103] = { title = "Fix login redirect loop after the session token refresh on mobile" },
  [106] = { title = "Test fixtures for the payment provider sandbox and its error codes" },
}

for _, item in ipairs(seed.items) do
  for k, v in pairs(LONG[item.id] or {}) do item[k] = v end
end

return seed
