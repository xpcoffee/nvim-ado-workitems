# nvim-ado-workitems

Navigate, search, and edit Azure DevOps work items without leaving Neovim.

Backend is the `az` CLI (azure-devops extension); `az` owns auth/token refresh.
Requires Neovim 0.10+, `az`, and `pandoc` (for the description markdown round-trip).

## Setup

```lua
require("ado").setup({
  org = "your-org",       -- defaults to $ADO_ORG, else "example-org"
  -- The projects lists cover, each with the types its rows may be created as
  -- or changed to. Without it, lists cover the one project below.
  projects = {
    { name = "Example", types = { "Task", "User Story", "Feature", "Milestone", "Bug", "Issue" } },
  },
  project = nil,          -- without projects: $AZURE_DEVOPS_EXT_DEFAULT_PROJECT, else a first-use picker
  default_query_top = 200,
  description_format = "markdown",
  -- State categories that count as open in "my work items" and search.
  open_categories = { "Proposed", "InProgress" },
  -- Optional: refuse any write outside this area path (and its sub-areas), and
  -- any write to an item of a denied type. Off unless set. See
  -- docs/architecture.md for the defaults.
  -- write_guard = { area = "Project\\Area", deny_types = { "Issue" } },
})
```

## Area view

`require("ado").area_view()` picks an area from `area_paths` and lists its
sub-areas, then its work items; `area_view("Project/Team")` opens one
directly. Each item row shows type, state, assignee, tags and title. In an
area view:

| Key | Action |
| --- | --- |
| `<CR>` | enter a sub-area (filters carried), or open the item in the detail split and the item view panel |
| `-` | parent area |
| `[h` / `]h` | back / forward |
| `<leader>wf` | set a filter: state (`open`, `all` or names), assignee (`@Me` or a name), types, tag |
| `<leader>wu` | include items of every sub-area, and back |
| `<leader>wb` | open the same query in the browser |
| `<leader>wr` | reload |

The window bar shows the filters and the counts. Views are read-only for
now: `:w` saves nothing.

```lua
require("ado").setup({
  area_paths = { "Example\\Software\\Platform\\Team A" },  -- "/" also works
  area_filters = { state = "open" },  -- default; also assignee, types, tag
})
```

## Toggling the views

`require("ado").toggle_area_view()` closes the area view, or reopens the
last area shown, or asks for an area when none has been shown.
`require("ado").toggle_item_view()` closes the item view, or opens it for
the work item in the current detail buffer, or reopens the last item shown,
or asks for an ID. `<leader>wi` in a detail buffer toggles the item view the
same way.

## Item view

`require("ado").item_view(id)` opens a panel for one work item: its title and
fields, its parent, its area path, its children, then its Related links.
Selecting an item in an area view opens it in the detail split and in this
panel. `item_view()` with no ID asks for one; `<leader>wi` in a detail
buffer opens the panel for that item. In an item view:

| Key | Action |
| --- | --- |
| `<CR>` | go to the parent, child or linked item, or to the area view of the area row |
| `<Tab>` | show a child's own children beneath it, and hide them again |
| `K` | show the item under the cursor in the detail split, keeping the cursor |
| `gd` | open the item under the cursor in the detail split and move there |
| `<leader>wt` | show children and links in every state, and back to open only |
| `[h` / `]h` | back / forward, shared with the area view |
| `<leader>wb` | open the item under the cursor in the browser |
| `<leader>wr` | reload |

Children and links show only open items by default; the headings say how
many are hidden. The parent always shows.

```lua
require("ado").setup({
  link_types = { "System.LinkTypes.Hierarchy", "System.LinkTypes.Related" },  -- default
})
```

## Editing

The detail buffer is read-only. Put the cursor on a field and press `<CR>` (or
an insert key: `i`/`a`/`o`…) to open a focused floating editor for just that
field: text fields get a one-line input, State a select, Description a markdown
pane. Confirm with `<CR>` (`<C-s>` in the multi-line description), cancel with
`q`/`<Esc>`. The float closes itself and the change saves on confirm (with a
`rev` check); nothing to clean up.

## Keymaps

Global (wired by the dotfiles spec): `require("ado").my_items()` / `.search()` /
`.open_prompt()`.

In a work-item buffer: `<CR>`/`i` edit field under cursor · `,wc` comment ·
`,wS` state · `,we` description · `,wb` browser · `,wr` reload · `,wi` item view.

In a picker: `<CR>` open · `<C-s>` change state · `<C-y>` yank id+url · `<C-o>` browser.
In the search picker, `<C-a>` re-runs the search in every state, and back.

## Notes

- "My work items" and search cover only the configured projects, and show
  only items in an open state: a state whose category is in
  `open_categories`. Categories come from each project's work item types,
  loaded the first time a list needs them (one `az` call per project,
  reported in `:messages`), so custom states such as `Discarded` need no
  list. Each item is judged by its own project's categories.
  `require("ado").search({ all_states = true })` starts in every state.

- `az boards query` only hydrates the fields named in the WIQL `SELECT`; the
  query builders list them explicitly.
- Text search uses WIQL `CONTAINS WORDS` (word/prefix over the index), not true
  full-text. Recent edits may lag the index.
- Field edits use a client-side `rev` check against clobbering concurrent edits.

## Development

`make test` runs every spec headless (`make test NVIM=/path/to/nvim` to pick a
binary); `make test-core` runs only the core suite. No test starts a process:
specs run against the fake transport in `tests/support/fake_transport.lua`.

Modules under `lua/ado/core/` hold behaviour and never touch `vim`; the
runner loads their specs in a sandbox that raises on `vim` and scans the
files for `vim.` as a backstop. Modules under `lua/ado/nvim/` own buffers,
windows, keymaps and the `az` transport. `docs/architecture.md` shows how the
layers, the transport wrappers and the test sandbox fit together.
