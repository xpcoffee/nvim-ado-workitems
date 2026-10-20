-- Invented data for the README's demo recordings, in the seed shape the fake
-- transport reads (tests/support/fake_transport.lua). Every organisation,
-- area, person and item here is made up.
local function html(...)
  return "<p>" .. table.concat({ ... }, "</p><p>") .. "</p>"
end

local A = "Example\\Platform\\Team A"
local B = "Example\\Platform\\Team B"

local seed = {
  org = "example-org",
  projects = { "Example" },
  me = "jane.doe@example.com",
  identities = {
    { display_name = "Jane Doe", unique_name = "jane.doe@example.com", id = "u-jane" },
    { display_name = "Alex Smith", unique_name = "alex.smith@example.com", id = "u-alex-s" },
    { display_name = "Alex Jones", unique_name = "alex.jones@example.com", id = "u-alex-j" },
    { display_name = "Priya Patel", unique_name = "priya.patel@example.com", id = "u-priya" },
    { display_name = "Sam Lee", unique_name = "sam.lee@example.com", id = "u-sam" },
    { display_name = "Maria Garcia", unique_name = "maria.garcia@example.com", id = "u-maria" },
    -- Assigned to nothing, so only the people search finds her.
    { display_name = "Priyanka Rao", unique_name = "priyanka.rao@example.com", id = "u-priyanka" },
  },
  areas = { "Example\\Platform", A, B },
  types = {
    { name = "Feature", color = "773B93", states = {
      { name = "New", category = "Proposed", color = "b2b2b2" },
      { name = "Active", category = "InProgress", color = "007acc" },
      { name = "Closed", category = "Completed", color = "339933" },
    } },
    { name = "User Story", color = "009CCC", states = {
      { name = "New", category = "Proposed", color = "b2b2b2" },
      { name = "Active", category = "InProgress", color = "007acc" },
      { name = "Resolved", category = "Resolved", color = "ff9d00" },
      { name = "Closed", category = "Completed", color = "339933" },
    } },
    { name = "Task", color = "A4880A", states = {
      { name = "To Do", category = "Proposed", color = "b2b2b2" },
      { name = "Doing", category = "InProgress", color = "007acc" },
      { name = "Done", category = "Completed", color = "339933" },
    } },
    { name = "Bug", color = "CC293D", states = {
      { name = "New", category = "Proposed", color = "b2b2b2" },
      { name = "Active", category = "InProgress", color = "007acc" },
      { name = "Resolved", category = "InProgress", color = "ff9d00" },
      { name = "Closed", category = "Completed", color = "339933" },
    } },
  },
  items = {
    { id = 1001, type = "Feature", title = "Self-service account recovery", state = "Active", area = A,
      assignee = "priya.patel@example.com", tags = "security; q4", changed = "2026-10-01T09:12:00Z",
      description = html("Let people recover their account without contacting support.",
        "Covers password reset by email and recovery codes.") },
    { id = 1002, type = "User Story", title = "Reset a forgotten password by email", state = "Active", area = A,
      parent = 1001, assignee = "jane.doe@example.com", tags = "auth", changed = "2026-10-14T15:40:00Z",
      related = { 1010 },
      description = html("As a signed-out user, I want to reset my password from a link sent to my email address, "
        .. "so that I can get back into my account on my own.",
        "<b>Acceptance criteria</b>",
        "The link expires after 30 minutes and works once.",
        "The reset page rejects passwords found in the breached-password list.",
        "A used or expired link shows a page that offers to send a new one.",
        "The email names the device and the approximate location of the request.",
        "<b>Out of scope</b>",
        "Recovery codes, which 1006 covers.",
        "Resetting a password from the mobile app.",
        "<b>Notes</b>",
        "The mail templates of the invite flow already render links, so the email reuses them.",
        "Support asked for the reset count per day on the operations dashboard.") },
    { id = 1003, type = "Task", title = "Send the reset email through the mail queue", state = "Doing", area = A,
      parent = 1002, assignee = "jane.doe@example.com", tags = "backend", changed = "2026-10-15T10:05:00Z" },
    { id = 1004, type = "Task", title = "Expire reset links after 30 minutes", state = "To Do", area = A,
      parent = 1002, assignee = "alex.smith@example.com", tags = "backend", changed = "2026-10-15T11:20:00Z" },
    { id = 1005, type = "Task", title = "Design the reset page", state = "To Do", area = A, parent = 1002,
      assignee = "maria.garcia@example.com", tags = "ui", changed = "2026-10-13T08:30:00Z" },
    { id = 1006, type = "User Story", title = "Sign in with a recovery code", state = "New", area = A, parent = 1001,
      assignee = "sam.lee@example.com", changed = "2026-10-09T14:00:00Z" },
    { id = 1007, type = "Bug", title = "Wrong subject on reset email", state = "Active",
      area = A, assignee = "jane.doe@example.com", tags = "email", changed = "2026-10-16T09:45:00Z" },
    { id = 1008, type = "Task", title = "Add rate limiting to the reset endpoint", state = "To Do", area = A,
      assignee = "alex.jones@example.com", tags = "security", changed = "2026-10-12T16:10:00Z" },
    { id = 1009, type = "Bug", title = "Session cookie survives sign-out on Safari", state = "New", area = A,
      tags = "browser", changed = "2026-10-11T13:25:00Z" },

    { id = 1010, type = "Feature", title = "Audit trail for account changes", state = "New", area = B,
      assignee = "sam.lee@example.com", tags = "compliance", changed = "2026-10-08T10:00:00Z" },
    { id = 1011, type = "User Story", title = "Export the audit trail as CSV", state = "Active", area = B,
      parent = 1010, assignee = "jane.doe@example.com", changed = "2026-10-15T12:00:00Z" },
    { id = 1012, type = "Task", title = "Store an event for each password change", state = "To Do", area = B,
      parent = 1010, assignee = "priya.patel@example.com", tags = "backend", changed = "2026-10-10T09:00:00Z" },
    { id = 1013, type = "Bug", title = "CSV export drops the last row", state = "Active", area = B,
      assignee = "alex.smith@example.com", tags = "export", changed = "2026-10-16T08:15:00Z" },
    { id = 1014, type = "Task", title = "Write the runbook for audit storage", state = "To Do", area = B,
      assignee = "jane.doe@example.com", tags = "docs", changed = "2026-10-07T15:30:00Z" },
  },
  -- Comments on 1002, oldest first; the item buffer pages them newest first.
  comments = {
    [1002] = {
      { "sam.lee@example.com", "2026-09-28T10:00:00Z", "Opened from the support backlog: 40 reset requests a week." },
      { "priya.patel@example.com", "2026-09-29T15:30:00Z", "Added the acceptance criteria from the security checklist." },
      { "maria.garcia@example.com", "2026-09-30T09:45:00Z", "Will the reset page follow the new sign-in layout?" },
      { "priya.patel@example.com", "2026-10-01T11:00:00Z", "Yes, same layout as sign-in." },
      { "priya.patel@example.com", "2026-10-02T09:00:00Z", "Scoped this to email only; recovery codes are 1006." },
      { "alex.smith@example.com", "2026-10-03T11:30:00Z", "Do we reuse the mail queue from the invite flow?" },
      { "jane.doe@example.com", "2026-10-03T14:05:00Z", "Yes, the invite templates already support links." },
      { "maria.garcia@example.com", "2026-10-06T10:20:00Z", "First draft of the reset page is in the design file." },
      { "sam.lee@example.com", "2026-10-08T16:45:00Z", "Security review asked for single-use links." },
      { "alex.jones@example.com", "2026-10-10T09:10:00Z", "Rate limiting is tracked in 1008." },
      { "priya.patel@example.com", "2026-10-13T13:00:00Z", "Moved the 30-minute expiry into its own task." },
      { "jane.doe@example.com", "2026-10-14T15:40:00Z", "Mail queue change is in review." },
    },
  },
}

for _, item in ipairs(seed.items) do
  for i, c in ipairs(seed.comments[item.id] or {}) do
    item.comments = item.comments or {}
    table.insert(item.comments, { id = i, author = c[1], created = c[2], text = "<p>" .. c[3] .. "</p>" })
  end
end
seed.comments = nil

return seed
