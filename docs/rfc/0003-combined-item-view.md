# RFC 0003: One item buffer, with the description and comments

- Status: Accepted with changes. The owner answered the questions on 2026-10-16 (section 14): Q1 to Q3 and Q5 to Q9 accepted as recommended, Q4 rejected, so the header gains no `iteration:` line. Planned in [plan 0003](../plan/0003-combined-item-view-plan.md).
- Date: 2026-10-16
- Scope: `nvim-ado-workitems`; the dotfiles spec `lua/plugins/ado.lua` binds its keys
- Builds on: [RFC 0001](0001-workitem-navigator.md) (views, saving, layout), [plan 0001](../plan/0001-implementation-plan.md) section 8 (owner decisions), [plan 0002](../plan/0002-ux-plan.md) (alignment, fitting, pickers)

The key words MUST, SHOULD and MAY follow RFC 2119, as in RFC 0001. Requirement IDs in this RFC start with `C` (C1.1, C2.1, ...); `R5.14` and similar IDs refer to RFC 0001, and `UX5.4` and similar to plan 0002.

## 1. Summary

Today the plugin shows one Azure DevOps (ADO) work item in two buffers: the **item view** (`ado://item/<id>`, an editable panel) and the **detail buffer** (`ado://<id>`, a read-only split beneath it). They repeat most of the same fields, edit them through two different routes, and the work item's comments show in neither.

This RFC replaces the pair with one buffer per work item, `ado://item/<id>`, in three parts from top to bottom:

1. **Header**: the item view as it is today (title, field lines, parent, area, children, links), edited in place and saved with `:w` and the save summary.
2. **Details**: the description and the remaining detail-only fields.
3. **Comments**: newest first, 5 at a time, with the next 5 loading as the cursor or the window nears the end of the buffer.

The details and comments are read-only text in the buffer. No edit there can reach the save plan.

Section 14 holds 9 owner questions with the owner's answers of 2026-10-16. Eight were accepted as recommended; Q4 was rejected, so the header gains no `iteration:` line and C1.2's iteration clause, C1.3 and acceptance behaviour 16 are withdrawn. The accepted answers to Q1, Q3 and Q5 change today's behaviour: the description float no longer writes on confirm, the detail buffer goes, and adding a comment moves to a multi-line float.

## 2. Problem

The owner's words, 2026-10-16:

> There are 2 views for an item, the item nav and the item details, and the item nav copies many of the points in the item detail header. I would like us to combine the two. Essentially have the header be what the item nav is (including the ability to change parent/children) followed by the item details.

> I don't know how to view/navigate comments – it mainly just looks like the item header + the description field. Ideally I'd want comments to follow, newest at the top, and "infinite scrolling (loading new comments)" as you head towards the bottom, page of 5 comments at a time.

### 2.1 What each buffer shows and allows today

In the table, HTML is the markup ADO stores descriptions and most comments in, and pandoc is the document converter the plugin runs to turn HTML into markdown and back. The detail buffer lives in `lua/ado/nvim/detail.lua` (RFC 0001 named its predecessor, `lua/ado/workitem.lua`).

| Shown | Item view (`lua/ado/nvim/item_view.lua`, `core/item_view.lua`) | Detail buffer (`lua/ado/nvim/detail.lua`) |
| --- | --- | --- |
| ID, type, state heading | window bar: `#<id> <type>` | first line: `# <id>  <type>  <state>` |
| Title | the item's own row; edit, then `:w` | `Title:` line; `<CR>` opens a one-line float that writes on confirm |
| Type | `type:` field line; edit, then `:w` | in the first line only, not editable |
| State | `state:` field line; edit or `<leader>we` picker, then `:w` | `State:` line; `<CR>` or `<leader>wS` opens a select that writes on choice |
| Assignee | `assignee:` field line; people menu, then `:w` | `Assignee:` line, as `Name <email>`; float that writes on confirm |
| Tags | `tags:` field line; edit, then `:w` | `Tags:` line; float that writes on confirm |
| Iteration | not shown | `Iteration:` line; float that writes on confirm |
| Area | area row; `<CR>` opens the area view | `Area:` line, read-only |
| Changed, Rev, URL | not shown (`<leader>wb` opens the URL) | read-only lines |
| Parent, children, links | rows; move, paste, delete and add lines, then `:w` | not shown |
| Description | not shown | markdown converted from HTML with pandoc; `<CR>` or `<leader>we` opens a markdown float that writes on `<C-s>` |
| Comments | not shown | not shown; `<leader>wc` adds one through a one-line prompt |

Six things show in both: title, type, state, assignee, tags and area. Five of them can be edited in both, by different routes:

- The item view collects edits until `:w`, shows them in the save summary, and sends one JSON Patch (a list of field and link operations that ADO applies whole or not at all) per work item, led by a `test` on the revision number (`rev`) the view loaded (RFC 0001 R5.14, `core/requests.lua`).
- The detail buffer writes each field as soon as its float is confirmed, through `Session:update_if_unchanged`, with the same kind of `rev` test.

Because each write raises the item's `rev`, an edit in one buffer makes the other buffer's `rev` stale. A field written from the detail buffer while the item view has unsaved edits makes the item view's next `:w` fail as "changed remotely", and the only way forward is a reload that discards those edits.

### 2.2 How the layout stacks them

`lua/ado/nvim/layout.lua` keeps up to three windows in one column, one per role, sharing the height equally: the list (an area view or a query list) on top, the item view beneath it, the detail split at the bottom. Selecting an item in a list opens both lower windows. With all three open, each gets a third of the column, and the detail window spends its first 12 lines on the fields the item view above it already shows.

### 2.3 Comments

The plugin never reads comments. `add_comment` is the only comment operation in the transport (`core/transport.lua`), and it writes through `az boards work-item update --discussion`.

## 3. Goals and non-goals

### Goals

- G1. One buffer per work item: the header the item view has today, then the details, then the comments.
- G2. Read comments newest first, loading 5 at a time as the user moves towards the end, without a key press.
- G3. Keep every edit to a work item's fields on one route, the `:w` save with its summary and its one patch per item (plan 0001 section 8, "One write per work item").
- G4. Keep the core free of Neovim (RFC 0001 R6.1): comment paging, region bounds and planning live in `lua/ado/core/`, tested against the fake transport.

### Non-goals

- Editing or deleting comments (Q5 asks whether adding stays).
- Comment reactions, attachments and images; an image shows as its link text.
- Watching for new comments while the buffer is open. A reload shows them.
- Search across comments.

## 4. Concepts

Terms from RFC 0001 section 4 keep their meaning: row, snapshot, change plan. So do these, which `docs/architecture.md` ("Saving views") defines: the row ID prefix and the **registry** (each line starts with a concealed row ID that the registry maps to the row it showed), the **view record** (a view's loaded rows paired with the rows parsed from its buffer, which the plan reads), the save summary, and the **fixed lines** (the item's own lines, the area row and the headings, which mark where each relationship's rows go and cannot be deleted or moved). This RFC adds these:

- **Item buffer.** The one buffer this RFC defines for a work item, `ado://item/<id>`. It replaces both the item view and the detail buffer.
- **Header region.** The lines of the item buffer that the item view shows today, from the item's own row to the last row of the last link section. It is editable, and it is the only part of the buffer the save reads.
- **Read-only region.** Every line after the header region: the details and the comments. The plugin writes these lines; the user only reads, moves through and yanks them.
- **Boundary line.** The first line of the read-only region, `── Details`. It is a fixed line, like a heading: the save rejects a plan in which it was deleted or moved.
- **Comment page.** Up to 5 comments returned by one call to ADO's comments route (section 7).
- **Continuation token.** The value ADO returns with a page to ask for the next one. It is absent on the last page.
- **Footer line.** The last line of the buffer, which says whether more comments are loading, can be loaded, failed to load, or have all been shown.

## 5. The item buffer

An item buffer for an item with 8 comments, after the first page has loaded (row ID prefixes hidden, as today):

```text
Retitle the scan export                                      (this item)
    type:      Task
    state:     Active
    assignee:  <email>
    tags:      export; ui
Plan the export work                                         (parent)
▸ Example\Software\Platform\Team A/
── Children: 2 open of 3
Task  │ New    │ Add the CSV writer       │ <email> │
Task  │ Active │ Wire the export button   │         │
── Related: none
── Details
    changed:   2026-10-15 14:02 · rev 17
    description:
    The export should write one file per visit.

    -   CSV first, then JSON.
── Comments: 8
2026-09-15 13:58 · <author>
    Comment text, converted to plain text, indented.

2026-09-15 13:47 · <author> · edited
    ...
── 5 of 8 comments shown, loading more…
```

- C1.1 The item buffer MUST show, in this order: the header region (C1.2), the boundary line, the details (C3), the `── Comments` heading, the loaded comments (C5), and the footer line (C4.5).
- C1.2 The header region MUST show what the item view shows today (RFC 0001 R3.1). (Withdrawn by Q4: "plus an `iteration:` field line after `tags:`".) Every rule of RFC 0001 R5 and of plan 0002 that applies to the item view today MUST keep applying to the header region unchanged: editing in place, moving and pasting rows, new child lines, `<Tab>` expansion, the all-states toggle, the save summary, and fitting to the window.
- C1.3 Withdrawn by Q4: the header shows no iteration, and nothing in the item buffer edits it. The text was: `iteration:` MUST be editable and saved with `:w` like the other field lines. The plugin has no list of iteration paths, so it does not check the value before sending. ADO is expected to refuse a patch with an iteration path the project lacks (not checked for this RFC); the save report then names the item (RFC 0001 R5.15).
- C1.4 The window bar MUST show the item's ID, type, `rev` and changed date, so the header needs no read-only lines for them.
- C1.5 `changed`, `rev` and `URL` MUST NOT be editable anywhere. `<leader>wb` keeps opening the URL.

## 6. Read-only regions and the save

Neovim cannot make some lines of a buffer read-only and others editable. The item buffer therefore holds the details and comments as ordinary text, and the plugin makes sure no change to them is ever planned or sent. Q2 asks whether to show them as virtual lines instead.

- C2.1 The view record for an item buffer (`view_buffer.record`) MUST contain only the lines above the boundary line. The core MUST receive the boundary as a line number with the record and MUST NOT parse any line at or after it (RFC 0001 R6.2).
- C2.2 The presentation layer MUST keep the text it last wrote into the read-only region. When `:w` finds that text changed (a line typed, deleted, pasted or moved there), the save MUST reject the plan with the message "the details and comments are read-only; `u` undoes the change, `<leader>wr` reloads", and MUST NOT send anything for any view in the save.
- C2.3 A deleted or moved boundary line MUST reject the save as a fixed line does today, so a deleted boundary can never move comment text into the header region.
- C2.4 Entering Insert mode on a line of the read-only region SHOULD leave Insert mode at once and say why, so most accidental edits never happen. Normal-mode changes (`dd`, `p`, `x`) are caught by C2.2.
- C2.5 Re-padding (`nvim/realign.lua`), fitting (`nvim/fit.lua`), change markers and colours (`nvim/decorations.lua`), row ID concealing (`view_buffer` `conceal`), cell text objects (`nvim/cells.lua`) and the Insert-mode menus (`nvim/complete.lua`) MUST act only on the header region. Without this, a comment line that happens to contain the column separator would be re-padded as a row, a comment starting with `/123 ` would have its start concealed, and every comment line would carry the `+` sign of a new line.
- C2.6 The plugin's own writes to the read-only region (a load, a page of comments, a re-render after a description edit) MUST stay out of the undo history and MUST keep the buffer's modified flag, as loads and expansions do today (`view_buffer` `edit`). One `u` therefore never removes a page of comments, and loading a page never marks the buffer as edited.
- C2.7 Loading a comment page MUST NOT change any line of the header region, so the header's unsaved edits and their undo history survive it. Pages are only ever written after the last comment shown, replacing the footer line.
- C2.8 While the user's change to the read-only region is unsaved (C2.2), the plugin MUST NOT load further comment pages, because it could no longer tell where the footer line is. The footer line says "undo the change to load more".
- C2.9 Yanking from the read-only region MUST work as in any buffer. A yanked comment line has no row ID, so pasting it into the header region is a new line, which the save treats as today (a new child under Children, rejected elsewhere).

## 7. ADO's comments route

Checked 2026-10-16 with `az rest` (the Azure command-line tool's command for calling an ADO REST route directly, which the plugin's `az` transport already uses for writes and people search) against the `example-org` organisation, `Example` project, on two items: one with 8 comments and one with 1,005. Every call was a read.

```text
GET https://dev.azure.com/{org}/{project}/_apis/wit/workItems/{id}/comments
    ?api-version=7.1-preview.4&$top=5&order=desc[&continuationToken=<token>]
```

| Question | Finding |
| --- | --- |
| API version | `7.1-preview.4` works, and so do `7.1-preview.3`, `7.0-preview.3` and `7.2-preview.4`. `7.1` without `-preview` fails. |
| Project in the URL | Required: the same route without `{project}` fails. Work items carry their project, so the plugin has it. |
| `order=desc` | Works: newest first. Across 10 pages (50 comments) of the large item, the IDs strictly decrease and no ID repeats. Without `order`, the default is also newest first; `order=asc` gives oldest first. |
| `$top=5` | Works: 5 per page; the last page of the 8-comment item held 3. |
| Paging token | `continuationToken` in the body is the `createdDate` of the first comment of the next page, at 100 ns precision, for example `2026-09-11T14:55:26.0930000Z`. It must be URL-encoded once. The response's `nextPage` URL carries the token and `$top` but drops `order`; following it still returned newest first, but the plugin should build its own URL. On the last page, `continuationToken` is `null` and `nextPage` is absent. |
| Totals | `totalCount` (all comments on the item) and `count` (this page) come with every page. `get_work_item` already returns `System.CommentCount` (8 for the first item), so the count is known before the first page loads. |
| Latency, small item | First page, 3 samples: 0.45, 0.49, 0.49 s. Second (last) page, 3 samples: 0.28, 0.31, 0.31 s. |
| Latency, large item | Pages 1 to 10, one sample each: 0.28 to 0.33 s, except page 5 at 1.31 s. These are wall times of the `az rest` process, so they include its start-up. |
| Text format | Each comment has `format`, `"html"` or `"markdown"`; of the 58 comments read, 1 was markdown. `text` holds the comment in that format. `renderedText` is present but empty unless `$expand=renderedText` is set, which returns HTML for both formats (the markdown comment's 248 characters rendered to 260); `$expand=renderedTextOnly` empties `text`. |
| Fields per comment | `id`, `workItemId`, `version`, `text`, `renderedText`, `format`, `createdBy`, `createdDate`, `modifiedBy`, `modifiedDate`, `mentions`, `url`. `createdBy` and `modifiedBy` hold `displayName`, `uniqueName`, `id`, `descriptor`, `imageUrl`, `url`, `_links`. |
| Edited | 2 of the 58 comments had `modifiedDate` later than `createdDate`; both had `version` 2, and every other comment had `version` 1. |
| Deleted | `isDeleted` was absent on every comment read, including with `includeDeleted=true`; none of the 58 was deleted, so how a deleted comment appears is not verified. |
| Mentions | 5 `mentions` entries across the 50 comments of the large item, each with `artifactId`, `artifactType`, `commentId`, `targetId`. In HTML, a mention is an `<a>` with a `data-vss-mention` attribute whose text is `@` and the person's name. |

Converting a comment's HTML with the pandoc the plugin already uses took 12 ms per call once warm and 2.7 s for the first call after start-up (one synthetic sample of each). `pandoc -t plain` renders a mention as `@Name` and a list as an indented `-` list.

## 8. Details

- C3.1 The details MUST show, under the boundary line: a `changed:` line (date, time and `rev`), then `description:` and the description converted from HTML to markdown with pandoc, as the detail buffer does today (`detail.to_editable`). An empty description shows `description: (none)`.
- C3.2 `<CR>` on any line of the description, and `<leader>wd` anywhere in the buffer, MUST open the description in the markdown float the detail buffer uses today. Q1 asks whether the description should instead be edited in the buffer itself.
- C3.3 Confirming the float (`<C-s>`) MUST NOT write to ADO. It MUST stage the edited description as an unsaved change of the item buffer: the buffer is marked modified, the description lines show the new text with the `~` change sign, and the next `:w` sends it, converted from markdown to HTML with pandoc, in the same patch as the item's other changes (G3). The save summary MUST list it as "description changed" with the number of lines added and removed.
- C3.4 A confirmed float whose text equals the loaded description MUST stage nothing, so an unchanged description is never round-tripped through pandoc.
- C3.5 A reload with a staged description MUST ask first, as for any unsaved edit (RFC 0001 R4.4).

Staging (C3.3) differs from today, where the float writes on confirm. It is what makes one route for edits possible: with an immediate write, a description edit would raise the item's `rev` under the header's unsaved edits, and their `:w` would then fail as "changed remotely" (section 2.1).

## 9. Comments

### 9.1 Loading and paging

- C4.1 The comment count MUST come from `System.CommentCount` in the item load, so the `── Comments: N` heading is right before any comment loads, and an item with no comments makes no comments call and shows `── Comments: none`.
- C4.2 Each page MUST be one call for 5 comments, newest first, passing the continuation token of the previous page (section 7).
- C4.3 A page MUST load when the footer line is shown in the window or is within half a window's height below the last line shown. Precisely, with `w$` the last buffer line drawn in the window and `h` the window's height: load when `footer_line - w$ <= floor(h / 2)`. The check MUST run after cursor moves, scrolling and window resizes (`CursorMoved`, `WinScrolled`, `WinResized`) in a window showing the buffer, and after each page is written, so a tall window fills with as many pages as it needs. The first page loads by the same rule, so an item whose comments are off-screen, such as one with many children, costs no comments call until the user moves towards them.
- C4.4 At most one page request MUST be in flight per item buffer. Each request MUST carry the buffer's load generation (a counter that every reload increases) and the token it was made with. A response whose generation or token no longer matches the buffer's MUST be dropped without writing anything. Comments MUST be de-duplicated by `id` when a page is merged, because the token is a timestamp and two comments created in the same 100 ns would sit on both sides of it.
- C4.5 The footer line MUST say one of:
  - `── 8 comments; move down to load them` before the first page;
  - `── 5 of 8 comments shown, loading more…` while a page is in flight;
  - `── 5 of 8 comments shown; move down to load more` when idle with more to load;
  - `── all 8 comments shown` after the last page;
  - `── comments did not load: <reason>; <CR> retries` after a failure (C4.7);
  - `── comments are read-only; undo the change to load more` in the case of C2.8.
- C4.6 A comment that arrives in a later page and is already shown (C4.4) MUST NOT show twice. A comment added in ADO after the first page loaded is not shown until a reload, because pages only go back in time.
- C4.7 A failed page MUST leave the shown comments in place, MUST set the footer line to the failure (C4.5), and MUST NOT retry by itself, so cursor movement over the footer does not repeat a failing call. `<CR>` on the footer line, or a reload, retries. The page call MUST pass `quiet = true` so the error notifier (`nvim/session.lua`) does not also report it; the footer line and one line in `:messages` report it once. (`quiet = true` is the existing per-call flag that the error notifier honours, `docs/architecture.md`, "Layers".)

### 9.2 Reload, save and navigation

- C4.8 An explicit reload (`<leader>wr`) MUST drop every loaded comment and start again from the first page, which then loads by C4.3.
- C4.9 The reload that follows a save (`nvim/save.lua`) MUST keep the loaded comments and the paging position, because a field or link save does not change comments, and re-render the header region and the details from the new load. The comment count MUST update from the new `System.CommentCount`; when it grew, the heading MUST say how many are new, for example `── Comments: 9 (1 new; <leader>wr shows it)`.
- C4.10 Going back to an item buffer in the history (`[h`) MUST show it with the comments it had loaded, as unsaved header edits are kept today.

### 9.3 Rendering

Q6 asks the owner to confirm each of these.

- C5.1 Each comment MUST show as a heading line, `<local date and time to the minute> · <author display name>`, followed by its text indented 4 spaces, then one blank line. A comment whose `version` is above 1 MUST add ` · edited` to its heading line.
- C5.2 HTML comments MUST be converted with `pandoc -f html -t plain --wrap=none`, one pandoc call per page rather than per comment. Markdown comments MUST show their `text` as it is. Without pandoc, the HTML MUST show with its tags removed.
- C5.3 A mention MUST show as `@` and the name, which `-t plain` gives (section 7).
- C5.4 Comment lines MUST use their own highlight groups (`AdoCommentHeading`, `AdoCommentText`), linked by default to `Title` and `Normal`, so the read-only region looks different from the header.

## 10. Layout, keys and commands

### 10.1 Layout

- C6.1 The layout MUST keep two roles, stacked in one column: the list (an area view or a query list) on top, and the item buffer beneath it. The detail role and its window go (Q3 asks whether to keep them as an option).
- C6.2 When both windows are open, the item buffer's window SHOULD get two thirds of the column's height, since it now holds the details and comments too. When the item window is alone it MUST take the whole column. Today the roles share the height equally.
- C6.3 Selecting an item in a list (RFC 0001 R2.7, R9.2) MUST open its item buffer in the item window and move the cursor there, as it moves to the item view today.
- C6.4 Every entry point that opens the detail buffer today MUST open the item buffer in the item window instead: `open_prompt()`, `open(id)`, `<CR>` in the search picker, and `K` and `gd` in an item buffer (section 10.2, C6.7).

### 10.2 Keys in the item buffer

| Key | Today | After this RFC |
| --- | --- | --- |
| `<CR>` | item view: go to the row's item or area; detail: edit the field | header: as the item view today. Description: open the float (C3.2). Footer: load or retry (C4.7). Comments: nothing. |
| `i`, `a`, `o` and other insert keys | detail: open the field's float | Insert mode, as in any buffer; refused in the read-only region (C2.4) |
| `K` | item view: show the row's item in the detail split, keeping the cursor | show the row's item in a float: its fields and the start of its description, one `get_work_item` call |
| `gd` | item view: open the row's item in the detail split | same as `<CR>` on an item row |
| `<leader>we` | item view: type, state or assignee picker; detail: description float | the picker, as in the item view. The description moves to `<leader>wd`. |
| `<leader>wd` | unused | open the description float (C3.2) |
| `<leader>wS` | detail: state select that writes at once | removed: the `state:` line and `<leader>we` edit the state, saved with `:w` |
| `<leader>wc` | detail: add a comment | kept or removed by Q5 |
| `<leader>wi` (buffer-local) | detail: toggle the item view | removed: the item buffer is the item view |
| `<leader>wb`, `<leader>wr`, `<leader>wt`, `<Tab>`, `[h`, `]h`, `<leader>wx` | item view | unchanged |

### 10.3 Commands and the owner's dotfiles keys

| Dotfiles key | Function | After this RFC |
| --- | --- | --- |
| `<leader>wa` | `toggle_area_view()` | unchanged: toggles the list window |
| `<leader>wA` | `area_view()` | unchanged: picks an area and opens its view in the list window |
| `<leader>wi` | `toggle_item_view()` | closes the item window, or reopens the last item shown, or asks for an ID. It no longer reads the ID from a detail buffer, since there is none. |
| `<leader>wI` | `item_view()` | unchanged: opens the item buffer for an ID typed at a prompt |
| `<leader>wo` | `open_prompt()` | opens the item buffer, not the detail buffer (C6.4) |
| `<leader>wm`, `<leader>ws` | `my_items()`, `search()` | unchanged; the search picker's `<CR>` opens the item buffer |

- C6.5 The public functions MUST keep their names, so the dotfiles spec needs no change.
- C6.6 The search picker's preview MUST keep converting descriptions with pandoc; the conversion moves out of `nvim/detail.lua` into a module of its own, since `nvim/detail.lua` goes (C6.1).
- C6.7 `K` on an item row MUST show that item's fields and the start of its description in a float, with one `get_work_item` call, keeping the cursor in place. It replaces the preview in the detail split (RFC 0001 R3.5), which goes with that split. `gd` MUST do what `<CR>` does on an item row.
- C6.8 `<leader>wS` MUST be removed, because it writes a state at once, outside the save (G3); the `state:` line and `<leader>we` set the state instead. The description float MUST move from `<leader>we` to `<leader>wd`, because `<leader>we` is the picker in the item view and one key cannot do both in one buffer.

## 11. Architecture

- C7.1 A new transport operation, `list_comments` (`{ id, project, top, token }` to `{ comments, total, token }`), MUST be a read: the write guard passes it unchanged, and the fake transport implements it with paging so core tests cover C4.
- C7.2 A new core module, `core/comments.lua`, MUST hold the paging state of one item buffer (loaded comments by ID, the next token, the load generation, and whether a page is in flight, done or failed), the merge and de-duplication (C4.4), and the trigger rule of C4.3 as a pure function of the footer line, `w$` and the window height. It MUST NOT reference `vim`.
- C7.3 Comment normalisation (author, dates, edited, format) MUST be core. Converting HTML to text needs a process (pandoc), so the presentation layer MUST do it and pass the converted text back, as it does for descriptions today.
- C7.4 The core item view rows (`core/item_view.rows`) MUST end with the boundary row, a fixed row the plan treats like a heading. The details and comments MUST NOT be rows: the presentation layer renders them below the rows, so the plan never receives them (C2.1).
- C7.5 The plan MUST accept a staged description as a field change of the viewed item (C3.3), carried in the item buffer's view record, and `core/requests.lua` MUST put it in the item's one patch. The write guard already checks a description field in a patch, because the detail buffer sends one today.
- C7.6 `ux_stats()` (the public function that reports how often the views' editing helpers ran and how long they took, plan 0002 UX1.8) SHOULD report comment pages loaded, their last and largest durations, failures, and responses dropped by C4.4, so the paging can be checked without a debugger.

## 12. Acceptance behaviours

Each can become a test: core behaviours against the fake transport starting from rows, presentation behaviours in headless Neovim against the fake transport, as in RFC 0001 section 8.

1. The item buffer of an item with 2 children and 8 comments shows the header, the boundary line, the details, `── Comments: 8`, and once the footer is in view, 5 comments newest first and the footer `5 of 8 comments shown`.
2. Moving the cursor to within half a window's height of the footer loads the remaining 3 comments with one call, and the footer becomes `all 8 comments shown`.
3. Two cursor moves made while a page is in flight produce one call, not two.
4. A page response that arrives after a reload is dropped and writes nothing.
5. A page that repeats a comment already shown adds only the comments not shown.
6. An item with no comments makes no comments call and shows `── Comments: none`.
7. An item with 60 children and 8 comments, opened with the comments off-screen, makes no comments call until the user moves towards them.
8. Deleting a comment line and saving rejects the save with the read-only message and sends nothing for any view.
9. Pasting an item row below the boundary line and saving rejects the save; the item gains no link.
10. Deleting the boundary line and saving rejects the save as a deleted fixed line.
11. Editing a title in the header, then loading a page of comments, then `u`, undoes the title edit and leaves the comments shown.
12. Loading a page of comments leaves the buffer's modified flag as it was.
13. Comment lines get no change sign, no re-pad and no concealing, also when a comment line contains the column separator or starts with `/123 `.
14. Confirming the description float with changed text writes nothing to ADO, marks the buffer modified, and the next `:w` sends one patch holding the description and the header's other edits, led by one `test` on `/rev`.
15. Confirming the description float with unchanged text stages nothing.
16. Withdrawn by Q4. Was: editing `iteration:` and saving sends the new path in the item's one patch; when the transport refuses it, the report names the item as failed.
17. A failed page leaves the shown comments, sets the footer to the failure with `<CR> retries`, reports it once, and makes no further call until `<CR>` on the footer.
18. After a save of a title change, the reload keeps the 5 loaded comments and their footer.
19. `<leader>wr` drops the loaded comments, and the first page loads again by the trigger rule.
20. Selecting an item in an area view opens two windows, the list and the item buffer, and the cursor is in the item buffer.
21. `open_prompt()` with an ID opens the item buffer in the item window.
22. A comment with `version` 2 shows ` · edited` on its heading line; an HTML comment with a mention shows `@` and the name.
23. Entering Insert mode on a comment line leaves Insert mode at once with a message.
24. Deleting a comment line pauses paging: moving towards the footer makes no call, and the footer shows the undo message; `u` resumes paging.
25. `<leader>wr` with a staged description asks before discarding it.
26. Going to another item and back with `[h` shows the comments the buffer had loaded, with no comments call.
27. The window bar shows the item's ID, type, `rev` and changed date.
28. With the list window open, the item window is two thirds of the column's height; alone, it takes the whole column.

## 13. Risks and assumptions

| ID | Risk or assumption | If wrong | Mitigation |
| --- | --- | --- | --- |
| A1 | The comments route keeps working as checked in section 7 under a preview API version. | A future ADO change breaks comment loading. | The version is one constant in `nvim/az.lua`, beside the others; a failed page leaves the rest of the buffer working (C4.7). |
| A2 | Comments are read in the item's own project, which the item load already returns. | An item whose project the plugin does not know cannot load comments. | Every item the core normalises carries a `project` from `System.TeamProject`; planning should confirm the item load always fills it. |
| R1 | Read-only text in an editable buffer (section 6) is guarded at save time, not at edit time. An edit there is possible and only rejected by `:w`. | The user sees a rejection after an accidental edit and must undo it. | C2.4 stops most accidental edits on entry to Insert mode; the rejection names the fix. Q2 offers virtual lines, which make the edit impossible but the comments unreachable by the cursor. |
| R2 | The region bounds (C2.5) must reach every module that reads buffer lines. A module that misses them treats comment lines as rows. | Comment lines get re-padded, concealed or marked as new; the save is still safe, because C2.1 and C2.2 do not depend on those modules. | Acceptance behaviour 13 covers each module by name. |
| R3 | Staging the description (C3.3) changes today's behaviour: confirming the float no longer writes. | The owner expects a write, closes Neovim, and loses the edit. | The buffer is marked modified, so Neovim warns on quit; the change sign marks the description. Q1 can choose immediate writes instead. |
| R4 | pandoc's first call after start-up took 2.7 s in one sample, and conversion is synchronous today. | The first page of comments, or the description, freezes the editor for seconds. | One pandoc call per page (C5.2). Planning SHOULD measure the cold start again and, if it repeats, run the conversion asynchronously. |
| R5 | Two comments created in the same 100 ns could straddle a token. | A comment shows twice or not at all. | De-duplication by ID (C4.4) covers the "twice" case. The "not at all" case cannot be detected from the token; none of the 50 consecutive comments read had equal timestamps. |
| R6 | Deleted comments do not appear in pages (section 7, not verified). | A deleted comment shows, or `totalCount` counts it and the footer never reaches "all shown". | The footer's "all shown" follows the absent token, not the count. |
| R7 | One taller window for the item replaces two shorter ones. | Less of the header is visible while reading comments. | C6.2 gives the item window two thirds of the column; the window bar keeps the ID and state in view. |

## 14. Questions for the owner

Each question lists the recommended default. The owner answered all nine on 2026-10-16:

| Question | Answer |
| --- | --- |
| Q1 description | Accepted. The description is edited in the markdown float; confirming no longer writes. The change waits for `:w`, goes in the same one revision-checked patch per item as the header edits, and appears in the save summary. |
| Q2 buffer text | Accepted, to try the recommendation (the owner was unsure). The details and comments are ordinary buffer text below a fixed `── Details` line; any change below it, or to that line, makes `:w` reject the save, and nothing below it reaches the save plan. |
| Q3 detail buffer | Accepted. The separate detail buffer is removed; the layout is the list or area view on top and the item buffer below. |
| Q4 iteration | Rejected. No editable `iteration:` line: the owner does not use iterations. The header does not show the iteration. |
| Q5 comment writes | Accepted. Adding a comment stays on `<leader>wc`, in a multi-line float, sent at once through the existing route and the write guard. Editing and deleting comments are out of scope. |
| Q6 rendering | Accepted: a heading line with the local date and time to the minute, the author's display name, and "edited" when `version` is above 1; plain text, mentions as `@Name`, the text indented 4 spaces; newest first. |
| Q7 first page | Accepted: the first page loads only when the comments come into view. |
| Q8 heights | Accepted: the item window gets two thirds of the column with the list open, and the whole column alone. |
| Q9 keys | Accepted: `<leader>wS` removed, the description float on `<leader>wd`, `K` shows the item under the cursor in a float, `gd` does what `<CR>` does. The owner's dotfiles keys `<leader>wa`, `<leader>wA`, `<leader>wi` and `<leader>wI` must keep working unchanged. |

The questions as asked:

- **Q1. Is the description edited in a float, as today, or inline in the buffer?**
  - Recommended: the float, staged into `:w` (C3.2, C3.3). The float keeps markdown text out of the header region, where it could be mistaken for rows, and staging keeps one write per item.
  - Option: the float, writing on confirm as today. Simpler, but a description edit then makes the header's unsaved edits fail on `:w` (section 2.1).
  - Option: inline. The description region becomes editable markdown, converted to HTML with pandoc on `:w`. Every edit is visible in place, but the region needs its own parsing and change detection, and pandoc's round trip from HTML to markdown and back may rewrite parts the user did not touch, such as tables, mentions and links with attributes (not tested for this RFC; expected from how pandoc normalises HTML).
  - Either way, HTML becomes markdown with `pandoc -f html -t markdown --wrap=none` for display and markdown becomes HTML with `pandoc -f markdown -t html` for the write, as today.
- **Q2. Are the details and comments buffer text or virtual lines?**
  - Recommended: buffer text, guarded as in section 6. The cursor can move through comments, yank from them, search them with `/`, and drive the paging trigger.
  - Option: virtual lines (extmarks drawn below the last line). No edit can reach them, but the cursor cannot enter them: reading means scrolling with `<C-e>`, `/` does not find comment text, and nothing can be yanked.
- **Q3. Is the separate detail buffer removed, or kept as an option?**
  - Recommended: removed (C6.1). Keeping it keeps two edit routes for the same fields and the stale-revision problem of section 2.1.
  - Option: kept behind a setting, `item_layout = "split"`, for one release.
- **Q4. Does the header gain the `iteration:` field line (C1.2, C1.3)?**
  - Recommended: yes. Apart from the description (C3), it is the only editable field the detail buffer has that the item view lacks, so without it removing the detail buffer would lose a feature.
- **Q5. Are comment writes in scope: adding, editing, deleting?**
  - Recommended: keep adding a comment with `<leader>wc`, through a multi-line markdown float instead of the one-line prompt, still sent at once through the existing `add_comment` route, then reload the first page and merge it. Editing and deleting stay out of scope.
  - Why: a comment notifies the people it mentions and the item's followers, so it cannot be staged and reviewed in the save summary like a field, and a mistaken one cannot be taken back quietly. The write guard already limits `add_comment` to the Team A area path and refuses it on `Issue` items; editing and deleting would each need a new transport operation and a new guard rule.
  - Option: remove `<leader>wc` too and read comments only.
- **Q6. How do comments render (C5)?**
  - Recommended, each part to confirm or change: HTML converted to plain text with pandoc; a mention as `@Name`; the heading line as local date and time to the minute, then the author's display name; ` · edited` when `version` is above 1; the text indented 4 spaces; newest first.
  - Options: markdown instead of plain text (keeps bold and links as markdown syntax); relative times ("3 days ago"); the author's email instead of their name.
- **Q7. Does the first page load on open, or only when the comments come into view (C4.3)?**
  - Recommended: only when they come into view. Walking the hierarchy with `<CR>` opens an item buffer per step, and loading the first page on open would add a call of about 0.3 to 0.5 s (section 7) to each step whether or not the user reads the comments.
  - Option: on open, so the comments are there by the time the user scrolls.
- **Q8. Does the item window get two thirds of the column (C6.2)?**
  - Recommended: yes, when the list window is open; the item window takes the whole column when it is alone.
  - Option: equal heights, as today.
- **Q9. Are the key changes of section 10.2 right?**
  - Recommended: yes: `<leader>wS` removed (C6.8), the description float on `<leader>wd` (C6.8), `K` showing a float instead of the detail split (C6.7), and `gd` the same as `<CR>`.
