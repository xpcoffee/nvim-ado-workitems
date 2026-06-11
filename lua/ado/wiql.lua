-- WIQL string builders. Pure: no I/O, no nvim API. Result-set capping happens
-- client-side after the query (az boards query has no --top), so these omit TOP.
local M = {}

-- az boards query only hydrates the fields named in SELECT, so list these
-- explicitly; description is included so the picker preview needs no extra fetch.
local SELECT = table.concat({
  "SELECT [System.Id], [System.Title], [System.State], [System.WorkItemType],",
  "[System.AssignedTo], [System.Tags], [System.IterationPath], [System.AreaPath],",
  "[System.ChangedDate], [System.Description] FROM WorkItems",
}, " ")

function M.my_items()
  return table.concat({
    SELECT,
    "WHERE [System.AssignedTo] = @Me AND [System.State] <> 'Closed'",
    "ORDER BY [System.ChangedDate] DESC",
  }, " ")
end

function M.text_search(text)
  -- CONTAINS WORDS is word/prefix match over the indexed long-text fields, not
  -- substring/fuzzy; recent edits may lag the index. Single quotes are doubled
  -- to escape them inside the WIQL string literal.
  local escaped = text:gsub("'", "''")
  return table.concat({
    SELECT,
    string.format(
      "WHERE ([System.Title] CONTAINS WORDS '%s' OR [System.Description] CONTAINS WORDS '%s')",
      escaped, escaped),
    "AND [System.State] <> 'Closed'",
    "ORDER BY [System.ChangedDate] DESC",
  }, " ")
end

return M
