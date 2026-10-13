# nvim-ado-workitems

Navigate, search, and edit Azure DevOps work items without leaving Neovim.

Backend is the `az` CLI (azure-devops extension); `az` owns auth/token refresh.
Requires Neovim 0.10+, `az`, and `pandoc` (for the description markdown round-trip).

## Setup

```lua
require("ado").setup({
  org = "your-org",       -- defaults to $ADO_ORG, else "example-org"
  -- The projects lists cover, each with the types its rows may be created as
  -- or changed to. Without it, lists cover the one project below, which has
  -- no types, so its rows cannot be created, copied or change type.
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

The window bar shows the filters and the counts. Edit titles and states in
place and save with `:w` (see "Editing the views" below).

```lua
require("ado").setup({
  area_paths = { "Example\\Software\\Platform\\Team A" },  -- "/" also works
  area_filters = { state = "open" },  -- default; also assignee, types, tag
})
```

## My work items

`require("ado").my_items()` lists the open work items assigned to you, in
the configured projects, as rows of type, state, title, assignee and tags.
It is an editable list like the area view, in the same window above the
item view, named `ado://query/mine?state=open&type=&tag=`. It has the area
view's keys except the two that need an area (`-` for the parent area,
`<leader>wu` for sub-area items): `<CR>` opens the item in the
detail split and the item view, `[h` / `]h` walk the shared history,
`<leader>wf` sets the state, type or tag filter (the assignee is always
you), `<leader>wb` opens the query in the browser and `<leader>wr`
reloads.

Edit its columns and save with `:w`, as in the other views. Its rows stand
for no relationship, so:

- deleting a row, and pasting it nowhere, changes nothing;
- pasting a row or typing a new line in it is rejected;
- a row deleted from it and put into an area view moves the item to that
  area, and put under an item's Children heading moves the item under that
  parent;
- a row yanked from it and put elsewhere is a copy, as from any view.

## Toggling the views

`require("ado").toggle_area_view()` closes the top window, which holds the
area view or the "my work items" list, or reopens the list it showed last,
or asks for an area when none has been shown. The top window shows one
list at a time: opening "my work items" or an area view replaces the other.
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

## Editing the views

Change a row's title or state column in an area view, or the title line or
`state:` line of the item view's own item, then `:w`. The save covers every
view with unsaved edits and shows a summary first: `y` applies, `n` or `q`
cancels and keeps the edits. All the changes to one work item go to ADO
as one write, which ADO applies whole or not at all, so ADO rules and
alerts never see an item half changed. Each write is refused if the item
changed in ADO since the view loaded; the save then stops and the views
reload. A save that completes ends in one line, such as `[ado] saved 3
changes to 3 work items: 2 field updates, 1 created (#1000)`. A save that
stops opens a report (`q` closes it) of the work items saved, failed and
not attempted. Each work item's write is logged as one JSON line, listing
its changes, in `stdpath("state")/ado-workitems/audit.log` (set
`audit_log` in `setup()` to move it).

Rows can also be deleted, pasted, moved or added, and their type, assignee
and tags changed; `docs/architecture.md` describes what each edit does.
Every type a row sets must be one of its project's `types` in `setup()`:
a new line, a copy or a type change in a project with no `types` makes the
save refuse, with the `setup()` entry to add and the project's types. A
`types` entry the project does not have is warned about once in
`:messages` when the project's types load. Sub-area rows, headings and the
area row are read-only. While an
item view has unsaved edits, `<Tab>` and `<leader>wt` are refused; save or
reload (`<leader>wr`, which asks before discarding) first.

## Editing in the detail buffer

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

In the search picker: `<CR>` open · `<C-s>` change state · `<C-y>` yank id+url ·
`<C-o>` browser · `<C-a>` re-runs the search in every state, and back.

## Notes

- "My work items" and search cover only the configured projects, and by
  default show only items in an open state: a state whose category is in
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
