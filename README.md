# nvim-ado-workitems

Navigate, search, and edit Azure DevOps work items without leaving Neovim.

Backend is the `az` CLI (azure-devops extension); `az` owns auth/token refresh.
Requires Neovim 0.10+, `az`, and `pandoc` (for the description markdown round-trip).

## Setup

Every value that names your organisation lives in your own configuration;
the plugin ships with no organisation, project or area of its own. A
minimal setup names the organisation, the projects with the types their
rows may take, the areas to browse, and the one area the plugin may write
to:

```lua
require("ado").setup({
  org = "example-org",
  projects = {
    { name = "Example", types = { "Task", "User Story", "Bug" } },
  },
  area_paths = { "Example\\Platform\\Team A" },
  write_guard = { area = "Example\\Platform\\Team A" },
})
```

Until `write_guard.area` is set, every write is refused with a message
that names it (see "The write guard" below). Reads work without it.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `org` | `$ADO_ORG` | The ADO organisation, as in `https://dev.azure.com/<org>`. Required: without it the first call fails with a message naming this option. |
| `projects` | `nil` | The projects that "my work items", search and the views cover, each with the types its rows may be created as or changed to: `{ { name = "Example", types = { "Task", "Bug" } } }`. A project with no `types` can be read, but its rows cannot be created, copied or change type. |
| `project` | `$AZURE_DEVOPS_EXT_DEFAULT_PROJECT` | Used only when `projects` is unset: the one project lists cover. When neither is set, a picker asks for a project on first use. |
| `area_paths` | `{}` | The area paths `area_view()` offers, with `\` or `/` between segments: `{ "Example/Platform/Team A" }`. |
| `area_filters` | `{ state = "open" }` | The filters a new area view starts with: `state` (`"open"`, `"all"` or a list of state names), `assignee` (`"@Me"` or a name), `types` (a list) and `tag`. |
| `open_categories` | `{ "Proposed", "InProgress" }` | The state categories that count as open in every list. |
| `default_query_top` | `200` | The most items one list or search loads. |
| `description_format` | `"markdown"` | How descriptions are edited: `"markdown"`, `"html"` or `"text"`. Markdown needs `pandoc`. |
| `link_types` | `{ "System.LinkTypes.Hierarchy", "System.LinkTypes.Related" }` | The link types the item buffer shows. The parent and children always show; each other type gets its own section. |
| `default_types` | `{ area = "Task", children = "Task" }` | The type a typed line gets when its type column is empty: in an area view, and under an item's Children heading. |
| `write_guard` | `{}` (no area: every write refused) | Limits writes; see "The write guard" below. `false` turns it off. |
| `audit_log` | `stdpath("state")/ado-workitems/audit.log` | The file each saved work item's write is logged to, one JSON line each. |
| `ui` | see "Colours" and "Fitting the window" | `icons` (the state dot and the sign column's markers) and `type_letters` (the letter a type shows as in a narrow window). |
| `transport` | the `az` transport | Replaces the transport; the test suite passes its fake transport here. |

`setup()` merges each key you pass over the defaults, so a table value
such as `write_guard` or `ui` replaces the default table whole.

### The write guard

The write guard refuses, before anything reaches ADO, any write to a work
item outside one area path and its sub-areas. It is on by default and
fails closed: with no `area` set, every write is refused with a message
saying to set `write_guard = { area = "Project\\Area" }` in `setup()`.

```lua
require("ado").setup({
  write_guard = {
    -- Writes only to items in this area and its sub-areas (required for any write).
    area = "Example\\Platform\\Team A",
    -- Optional: types no write may touch, nor change an item to.
    deny_types = { "Incident" },
    -- Optional: writes only to items whose title starts with this text,
    -- for test runs that must not touch items they did not create.
    title_prefix = "[test] ",
  },
})
```

Area paths compare case-insensitively, and `/` works in place of `\`.
`deny_types` defaults to none. To write anywhere the signed-in user may,
set `area` to a project's name, which covers the whole project, or set
`write_guard = false`. `docs/architecture.md` describes every rule the
guard applies.

## Area view

`require("ado").area_view()` picks an area from `area_paths` and lists its
sub-areas, then its work items; `area_view("Project/Team")` opens one
directly. Each item row shows the work item's ID, then its type, state,
title, assignee and tags. In an area view:

| Key | Action |
| --- | --- |
| `<CR>` | enter a sub-area (filters carried), or open the item in the item buffer beneath the list |
| `-` | parent area |
| `[h` / `]h` | back / forward |
| `<leader>wf` | set a filter: state (`open`, `all` or names), assignee (`@Me` or a name), types, tag |
| `<leader>wu` | include items of every sub-area, and back |
| `<leader>we` | pick a type, state or assignee for the cell under the cursor; in Visual mode, for that column of every selected row |
| `<leader>wx` | show a cell cut to fit the window in full; in Visual mode, that column of every selected row |
| `<leader>wb` | open the same query in the browser |
| `<leader>wr` | reload |

The window bar shows the filters and the counts. Edit titles and states in
place and save with `:w` (see "Editing the views" below).

`area_paths` and `area_filters` in `setup()` set the areas offered and the
filters a view starts with (see "Options").

## My work items

`require("ado").my_items()` lists the open work items assigned to you, in
the configured projects, as rows of ID, type, state, title, assignee and
tags.
It is an editable list like the area view, in the same window above the
item buffer, named `ado://query/mine?state=open&type=&tag=`. It has the area
view's keys except the two that need an area (`-` for the parent area,
`<leader>wu` for sub-area items): `<CR>` opens the item in the item
buffer, `[h` / `]h` walk the shared history,
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
`require("ado").toggle_item_view()` closes the item window, or reopens the
last item shown, or asks for an ID.

The views stack in one column: the list (an area view or "my work items")
on top, and the item buffer beneath it, which gets two thirds of the
column's height while the list is open and all of it alone.

## Item buffer

`require("ado").item_view(id)` opens one buffer for a work item,
`ado://item/<id>`. Selecting an item in an area view or "my work items",
`require("ado").open(id)`, `open_prompt()` and `<CR>` in the search picker
open it too, in the item window. `item_view()` with no ID asks for one.

The buffer has three parts:

1. The **header**: the item's title and its `id:`, `type:`, `state:`,
   `assignee:` and `tags:` lines, its parent, its area path, its children,
   then its Related links. The parent, child and link rows have the same
   columns as an area view's rows, ID first. You edit the header in place
   and save with `:w` (see "Editing the views").
2. Below a `── Details` line, the **details**: a `changed:` line with the
   date, time and revision, and the description as markdown. The details
   are read-only text: you can move through them, search and yank, but an
   edit there makes `:w` refuse the whole save with "the details and
   comments are read-only; u undoes the change, <leader>wr reloads".
   Entering Insert mode there leaves it at once and says so.
3. The **comments**, newest first, under `── Comments: N`, also
   read-only. They load 5 at a time as you move towards the end of the
   buffer: a page loads when the last line, the footer, is shown or is
   within half a window's height below it, so an item whose comments are
   off-screen costs no call until you move towards them. The footer says
   what is happening: `8 comments; move down to load them`, `5 of 8
   comments shown, loading more…`, `all 8 comments shown`, or `comments
   did not load: <reason>; <CR> retries`. Loading a page adds no undo
   step, so `u` still undoes your header edits. While you have changed
   the comments' text, paging stops and the last line says to undo the
   change. Each comment shows as its local date and time, its author,
   and `edited` when it was edited, then its text as plain text, indented.
   `<leader>wr` loads the comments again from the newest; the reload
   after a save keeps them, and the heading says when the save found new
   ones (`Comments: 9 (1 new; <leader>wr shows it)`). Going back to an
   item with `[h` shows the comments it had loaded.

The window bar shows the item's ID, type, revision and changed time.

| Key | Action |
| --- | --- |
| `<CR>` | go to the parent, child or linked item, or to the area view of the area row; on the description, edit it; on the comments' footer, load the next page or retry a failed one |
| `gd` | the same as `<CR>` on a row |
| `<Tab>` | show a child's own children beneath it, and hide them again |
| `K` | show the item under the cursor in a float: its fields and the start of its description; `K` again enters the float |
| `<leader>wd` | edit the description in a markdown float |
| `<leader>wc` | write a comment in a markdown float; `<C-s>` sends it at once |
| `<leader>wt` | show children and links in every state, and back to open only |
| `<leader>we` | pick a type, state or assignee for the cell or `type:`/`state:`/`assignee:` line under the cursor; in Visual mode, for that column of every selected row |
| `<leader>wx` | show a cell, title or field value cut to fit the window in full |
| `[h` / `]h` | back / forward, shared with the area view |
| `<leader>wb` | open the item under the cursor in the browser |
| `<leader>wr` | reload |

Children and links show only open items by default; the headings say how
many are hidden. The parent always shows.

**The description** is edited in a markdown float (`<leader>wd`, or `<CR>`
on it). `<C-s>` in the float does not write to ADO: it keeps the new text
for the next `:w`, marks the buffer modified, shows the new text in the
details with `~` signs, and the save sends it in the same one write as the
item's other edits, listed in the summary as `#N description changed: 3
lines added, 1 line removed`. Confirming the text as loaded keeps nothing.
`u` does not undo a kept description; open the float again and restore
the text, or reload (`<leader>wr` asks first).

**A comment** (`<leader>wc`) is sent as soon as you confirm the float,
because a comment notifies people and cannot be reviewed in the save
summary like a field. It is refused while the buffer has unsaved edits:
a comment raises the item's revision, so those edits could no longer be
saved. After the comment the header reloads and the new comment shows
first.

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

Rows stay aligned while you edit. The spaces between cells are real text,
so `<C-v>` over a column changes every selected row. After each change in
Normal mode, and when Insert mode ends, the view rewrites the spaces that
no longer line up; one `u` undoes your change and that rewrite together.
While you type in Insert mode only the line you are editing drifts. `ic`
selects the text of the cell under the cursor and `ac` adds its padding and
separator, so `cic` on an assignee replaces the whole name, where `cw`
would leave the surname. `require("ado").ux_stats()` prints how many
rewrites, decorations and people searches ran and how long they took.

Type and state cells have lists of values. In Insert mode, `<C-Space>`
(or `<C-x><C-u>`) in a type or state cell, or on the item view's `type:`
or `state:` line, opens a menu of the values the save accepts there: the
project's configured `types` for a type, and the states of the row's type
for a state, each with its state category. Typing narrows the menu, and the
value picked replaces the cell's text. A state cell follows a type typed on
the same line once that type is one the save would change the row to. A
new line offers no states, since a new item starts in its type's initial
state. In Normal mode, `<leader>we` opens the same values in
`vim.ui.select` (your picker, if a plugin replaces it) and writes the
choice into the cell; in Visual mode it writes into that column of every
selected row, offering only the states every selected row's type has. One
`u` undoes the whole write. The views turn nvim-cmp off in their own
buffers and set `vim.b.completion = false`, which blink.cmp reads, so the
plugin's menu is the only one there.

Assignee cells search people by name. In Insert mode, `<C-Space>` (or
`<C-x><C-u>`) in an assignee cell, or on the item view's `assignee:` line,
opens a menu at once with the people assigned to rows in your open views
and the people you picked earlier in the session, the most recent first.
Each entry shows the display name with the email beside it. Picking one
inserts the person's email rather than the name, because an email names
exactly one person, so the save never finds it ambiguous. The cell holds
the email, cut to the assignee column's width when it is wider (see
"Fitting the window" below), until the next reload shows the display name
again.

Typing narrows the menu from the first character to people whose name,
any word of the name, or email starts with what you typed, so `doe` finds
`Janet Doe`. Once the cell holds 2 or more characters and you pause for
200 ms, the plugin also searches ADO and adds the people it finds; the
command line shows the search and its time, for example
`[ado] people 'jan': 3 found in 0.31 s`. ADO returns at most 10 people per
search, so type more of the name if the person is missing. Each prefix is
searched once per session. A failed search shows one message per Insert
session. In Normal mode, `<leader>we` on an assignee cell asks for a name,
searches, and offers the matches and "unassign" in `vim.ui.select`; in
Visual mode it writes the choice into every selected row.

If the menu replaces the name you are typing with the first email, add
`noselect` to your `'completeopt'`. The views do this themselves where
Neovim lets `'completeopt'` be set per buffer (0.11 does), adding
`menuone` and `noselect` to your value unless it has `noinsert`.

The sign column shows `~` on a row whose columns differ from what was
loaded and `+` on a typed line or a row pasted from another view, by the
same comparison the save uses, so a marked row is a row the save summary
lists. The window bar shows the view's counts on the right, with the rows
edited, new and removed since the last load: `0 sub-areas · 6 items ·
1 edited · 1 removed`.

Work item IDs are there to copy. Every row starts with an ID column, and
the item buffer's first field line is `id: <number>`; `yic` or `yiw` on
either yanks just the number. IDs are read-only: a changed ID cell or
`id:` line makes `:w` refuse that row, naming it ("the ID is read-only;
put 101 back, or reload"), and nothing is sent. Leave the ID column of a
line you type empty (` │ Task │ │ My new task │ │`, or a title alone);
its ID shows once the save has created it and the view reloads. A row you
paste keeps the ID it was copied with, so a copy (`yyp`) shows the
original's ID until the save gives it its own. What a pasted row does is
decided by the hidden row ID at the start of each line, never by the ID
column. The cursor never rests on that hidden row ID in Normal mode, so
`0` or `G` then `yiw` yanks the ID.

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

## Fitting the window

Rows fit the window they are shown in, so moving the cursor along a row
never scrolls the view sideways. The ID column is never cut and takes its
width first. Columns whose cells are short keep their width and the title
takes the rest. When the window is too narrow for every cell, the columns
give way in this order: the tags collapse to `…` (the row still has tags),
the type shows as one letter (`T` for Task, `S` for User Story: the first
letter of the name's last word), then the assignee shortens to 8 columns.
The title never gets fewer than 20 columns, so in a window narrower than
about 65 columns (with 6-digit IDs) a row with long cells runs past it.

A cell longer than its column is cut in the buffer and ends in `…`. The
plugin keeps the full value, and the save sends full values only:

- Editing the visible part of a cut cell (`x`, `cw`, typing in Insert
  mode) keeps the hidden part. When the edit ends, the cell gets its full
  value back with your change in it and is cut again, in the same undo
  step, so `u` and `<C-r>` work as usual.
- `cic`, a value picked from a menu, and `<leader>we` replace the whole
  cell, so what you write becomes its full value.
- Deleting the `…` or typing after it leaves the plugin unable to tell
  what the full value should be. The save then refuses, naming the row:
  undo the edit, or press `<leader>wx` on the cell and edit the full text.
- `<leader>wx` shows the cell under the cursor in full, as a change `u`
  undoes; in Visual mode it does so for that column on every selected
  row. The cell stays in full until the view reloads.
- The save summary shows every changed title in full before `y`.

When the cursor rests for 300 ms on a cut cell, a one-letter type or a
row with collapsed tags, a float beside it shows the whole row: ID, type,
state, title, assignee with email, tags and area. It closes as soon as the
cursor moves. In the item view, the item's own title line and its field
values are cut the same way.

Resizing a window, or opening and closing the list, lays an unedited
view out again for its new width. A view with unsaved edits
keeps its layout, because rewriting it would add an undo step between
your edits; its window bar says `fits the window after :w or <leader>wr`.
A view shown in two windows fits the narrower one. A new line you type is
never cut, so a long title on it runs past its column.

The letter a type shows as can be set per type. `ui` is one table, so
put `type_letters` and `icons` (see "Colours") in the same one:

```lua
require("ado").setup({
  ui = { type_letters = { ["Test Case"] = "C" } },
})
```

## Colours

Each type cell shows in its type's ADO colour, and a dot `●` in the
state's ADO colour sits before each state, as ADO's boards show them. The
colours come with the work item types the plugin loads once per project.
ADO colours need `termguicolors`; without it, and for a type or state with
no colour, the cells use `AdoType` and `AdoState`. Separators are dimmed,
and sub-area rows and headings are marked. Every group links to a standard
group, so a colour scheme colours the views; override any of them with
`:highlight`:

| Group | Links to | Draws |
| --- | --- | --- |
| `AdoType` | `Type` | a type without an ADO colour |
| `AdoState` | `Constant` | the dot of a state without an ADO colour |
| `AdoSeparator` | `NonText` | the `│` between cells |
| `AdoAreaMark` | `Directory` | sub-area rows and the item view's area row |
| `AdoHeading` | `Title` | the item view's section headings |
| `AdoChanged` | `Changed` | the `~` sign |
| `AdoNew` | `Added` | the `+` sign |
| `AdoCount` | `Comment` | the counts in the window bar |
| `AdoCommentHeading` | `Title` | a comment's date and author line |
| `AdoCommentText` | `Normal` | a comment's text |

The views set `signcolumn=yes:1` on their windows. The dot and the signs
can be other characters, such as Nerd Font glyphs, each one column wide:

```lua
require("ado").setup({
  ui = { icons = { state = "●", changed = "~", new = "+" } },  -- the defaults
})
```

## Keymaps

The plugin maps no global keys; bind these functions in your own
configuration: `require("ado").my_items()` / `.search()` /
`.open_prompt()` / `.toggle_area_view()` / `.area_view()` /
`.toggle_item_view()` / `.item_view()`.

In the area view, query lists and item buffer, besides the keys in their
tables: `ic`/`ac` select a cell, `<C-Space>` (Insert mode) and
`<leader>we` (Normal and Visual mode) list the values of a type or state
cell, and search people for an assignee cell, and `<leader>wx` shows a
cut cell in full.

In the search picker: `<CR>` opens the item buffer · `<C-s>` changes the
state at once · `<C-y>` yanks id+url · `<C-o>` browser · `<C-a>` re-runs
the search in every state, and back.

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
- Every write is checked against the revision the view loaded, so a
  concurrent edit in ADO is never overwritten.

## Development

`make test` runs every spec headless (`make test NVIM=/path/to/nvim` to pick a
binary); `make test-core` runs only the core suite. No test starts a process:
specs run against the fake transport in `tests/support/fake_transport.lua`.
`make test ORDER=reverse` and `make test ORDER=shuffle` run the spec files in
another order, which catches a spec that leaves state behind for the next;
shuffle prints its seed, and `SEED=<n>` repeats that order. `make test
ONLY=fit_spec` runs only the spec files whose path holds `fit_spec`.
`make bench` times the re-pad, the decoration and the full layout of 200
and 1,000 rows, and the item buffer's read-only region, against the plans'
targets.

Modules under `lua/ado/core/` hold behaviour and never touch `vim`; the
runner loads their specs in a sandbox that raises on `vim` and scans the
files for `vim.` as a backstop. Modules under `lua/ado/nvim/` own buffers,
windows, keymaps and the `az` transport. `docs/architecture.md` shows how the
layers, the transport wrappers and the test sandbox fit together.
