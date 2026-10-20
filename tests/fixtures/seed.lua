-- Fake ADO data for the fake gateway. Starts from the oil spike's items
-- (areas P\Team and A to D, duplicate titles, a slash in a title) and adds what
-- later phases test: types with state categories, a state that is open for one
-- type and finished for another (Resolved), Related links, two identities
-- matching "Alex", and an Issue for the write guard. Types and states carry
-- ADO's colours, except Issue, which stands for a type listed without them. Items 112 to 114 are
-- assigned to "me" in a Resolved (open for Bug, finished for User Story) or
-- Discarded (Removed category) state, for the open-state filter.
return {
  org = "test-org",
  projects = { "P" },
  me = "me@example.com",
  identities = {
    { display_name = "Me Myself", unique_name = "me@example.com", id = "u-me" },
    { display_name = "Alex Smith", unique_name = "alex.smith@example.com", id = "u-alex-s" },
    { display_name = "Alex Jones", unique_name = "alex.jones@example.com", id = "u-alex-j" },
  },
  areas = { "P\\Team", "P\\Team\\A", "P\\Team\\B", "P\\Team\\C", "P\\Team\\D" },
  types = {
    { name = "Task", color = "A4880A", states = {
      { name = "To Do", category = "Proposed", color = "b2b2b2" },
      { name = "Doing", category = "InProgress", color = "007acc" },
      { name = "Done", category = "Completed", color = "339933" },
      { name = "Discarded", category = "Removed", color = "666666" },
    } },
    { name = "User Story", color = "009CCC", states = {
      { name = "New", category = "Proposed", color = "b2b2b2" },
      { name = "Active", category = "InProgress", color = "007acc" },
      { name = "Resolved", category = "Resolved", color = "ff9d00" },
      { name = "Closed", category = "Completed", color = "339933" },
    } },
    { name = "Bug", color = "CC293D", states = {
      { name = "New", category = "Proposed", color = "b2b2b2" },
      { name = "Active", category = "InProgress", color = "007acc" },
      { name = "Resolved", category = "InProgress", color = "ff9d00" },
      { name = "Closed", category = "Completed", color = "339933" },
    } },
    { name = "Issue", states = {
      { name = "To Do", category = "Proposed" },
      { name = "Done", category = "Completed" },
    } },
  },
  items = {
    { id = 100, type = "User Story", title = "Checkout story", state = "Active", area = "P\\Team\\A",
      assignee = "me@example.com", changed = "2026-10-01T09:00:00Z",
      description = "<p>Let customers pay at checkout.</p>", related = { 105 } },
    { id = 101, type = "Task", title = "Write API", state = "To Do", area = "P\\Team\\A", parent = 100,
      assignee = "me@example.com", tags = "api; backend", changed = "2026-10-02T09:00:00Z" },
    { id = 102, type = "Task", title = "Add tests", state = "Doing", area = "P\\Team\\A", parent = 100,
      assignee = "alex.smith@example.com", changed = "2026-10-03T09:00:00Z" },
    { id = 103, type = "Task", title = "Fix login", state = "To Do", area = "P\\Team\\A",
      assignee = "me@example.com", changed = "2026-10-04T09:00:00Z",
      description = "<p>Login fails after the <b>token</b> refresh.</p>" },
    { id = 104, type = "Task", title = "Update docs", state = "To Do", area = "P\\Team\\B",
      changed = "2026-10-05T09:00:00Z" },
    { id = 105, type = "User Story", title = "Payments story", state = "New", area = "P\\Team\\B",
      changed = "2026-10-06T09:00:00Z", related = { 100 } },
    { id = 106, type = "Task", title = "Test fixtures", state = "To Do", area = "P\\Team\\A", parent = 102,
      changed = "2026-10-07T09:00:00Z" },
    { id = 107, type = "Task", title = "Refund flow", state = "Done", area = "P\\Team\\B", parent = 105,
      assignee = "me@example.com", changed = "2026-10-08T09:00:00Z" },
    { id = 108, type = "Task", title = "Same title", state = "To Do", area = "P\\Team\\D",
      changed = "2026-10-09T09:00:00Z" },
    { id = 109, type = "Task", title = "Same title", state = "Doing", area = "P\\Team\\D",
      changed = "2026-10-10T09:00:00Z" },
    { id = 110, type = "Task", title = "A/B test rollout", state = "To Do", area = "P\\Team\\D",
      changed = "2026-10-11T09:00:00Z" },
    { id = 111, type = "Issue", title = "Support issue", state = "To Do", area = "P\\Team\\A",
      changed = "2026-10-11T10:00:00Z" },
    { id = 112, type = "Bug", title = "Resolved bug", state = "Resolved", area = "P\\Team\\C",
      assignee = "me@example.com", changed = "2026-10-11T11:00:00Z" },
    { id = 113, type = "User Story", title = "Resolved story", state = "Resolved", area = "P\\Team\\C",
      assignee = "me@example.com", changed = "2026-09-20T09:00:00Z" },
    { id = 114, type = "Task", title = "Discarded task", state = "Discarded", area = "P\\Team\\C",
      assignee = "me@example.com", changed = "2026-09-21T09:00:00Z" },
  },
}
