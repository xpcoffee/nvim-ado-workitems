# RFC 0001: Work item navigator

- Status: Draft, for review before implementation planning
- Date: 2026-10-11
- Scope: `nvim-ado-workitems` (loaded by the dotfiles spec `lua/plugins/ado.lua`)

The key words MUST, SHOULD and MAY follow RFC 2119: MUST is required for the first release, SHOULD is expected unless planning finds a reason against it, MAY is optional.

## 1. Summary

Today the plugin lists work items in a Telescope picker and opens one at a time in a read-only detail buffer. This RFC adds two views:

1. An **area view** lists the sub-areas and work items under an Azure DevOps (ADO) area path, with filters.
2. An **item view** shows a work item's parent, children, linked items and area path, so the user can walk the hierarchy.

Both views are editable text buffers in the style of [oil.nvim](https://github.com/stevearc/oil.nvim), a Neovim file explorer where the directory listing is a normal buffer: renaming, deleting or moving a line and then saving (`:w`) performs that change on disk. Here, saving performs the change in ADO.

The behaviour and state live in a core that does not depend on Neovim, with Neovim as one presentation layer on top, so another client can reuse the core later.

## 2. Problem

- The plugin can only reach a work item by ID, by text search, or from the "assigned to me" list. There is no way to see what work exists in an area, or how items relate to each other as parents, children and linked items.
- Reorganising work (reparenting, moving between areas, creating a batch of children) needs the ADO web UI, one item at a time.

## 3. Goals and non-goals

### Goals

- G1. Browse an area path like a directory: sub-areas first, then the work items in it.
- G2. Browse a work item's hierarchy and links, and move between the area view and the item view freely.
- G3. Change work items in bulk by editing text and saving: create, delete, retitle, copy, reparent, and move between areas.
- G4. Keep behaviour and state in a core with no Neovim dependency, so the core can be tested without Neovim and reused by another client.

### Non-goals

- Filtering lists to open items. [RFC 0002](0002-open-state-filter.md) defines "open" and applies it to "my work items" and text search; this RFC reuses that definition.
- Replacing the detail buffer (defined in section 4) or its per-field editors. The item view complements them.
- Boards, sprints (iterations) and backlog ordering. Iteration path is a candidate filter later, not part of this RFC.
- Offline editing or a local cache that survives restarts.
- Metrics and analytics-warehouse feeds. This is a single-user editor plugin; the audit log in R7.4 covers the need to see what a save did.

## 4. Concepts

These terms are used throughout the requirements.

- **Detail buffer.** The existing read-only buffer that shows one work item's fields and description (`lua/ado/workitem.lua`, `M.open`). Pressing `<CR>` on a field opens a floating editor for that one field (`lua/ado/float.lua`).
- **Revision guard.** The existing check before an update: the plugin re-reads the item and compares its revision number (`rev`) with the one it loaded, and refuses to write if they differ (`lua/ado/workitem.lua`, `do_update`). It stops one edit from silently overwriting another made in the meantime.
- **Open state.** A state whose state category is `Proposed` or `InProgress`, as defined in [RFC 0002](0002-open-state-filter.md). ADO assigns every state of every work item type to one of five categories (`Proposed`, `InProgress`, `Resolved`, `Completed`, `Removed`).
- **Area path.** ADO's tree of areas within a project, such as `Project/Team/Sub`. Every work item belongs to one area path. ADO calls the tree's entries "classification nodes".
- **Parent and child.** ADO's hierarchy link type (`System.LinkTypes.Hierarchy`). A work item has at most one parent and any number of children. Other link types, such as Related, are not hierarchical.
- **Location.** A value naming what a view shows. An area location holds an area path, the filters (R2.4) and the sub-area toggle (R2.5). An item location holds a work item ID and the show-all toggle (R3.8). Inline expansion (R3.4) is view state, not part of the location, so going back to a location shows it collapsed.
- **Area view.** A list of one area's sub-areas and work items, for an area location (R2).
- **Item view.** A tree of one work item's parent, area, children and linked items, for an item location (R3).
- **Row.** One line of a view, carrying the ID of what it shows. A row is a sub-area, a work item, or a fixed entry such as the parent or area row of an item view.
- **Snapshot.** The rows a view displayed when it was last loaded from ADO.
- **Change plan.** The ordered list of ADO operations computed by comparing the current rows of every modified view against their snapshots. The user confirms the plan before anything is sent.

## 5. Requirements

### R2. Area view

- R2.1 The user MUST be able to open the area view on any area path listed in the new `area_paths` setting (R8.1). The plugin MUST offer a picker over those paths.
- R2.2 The view MUST list the area's direct sub-areas first, then its work items.
- R2.3 Selecting a sub-area MUST navigate to that sub-area's area view, carrying the current filters and sub-area toggle with it.
- R2.4 Work items MUST be filterable by state, assignee, work item type, and tag. The default state filter MUST be "open" as defined in RFC 0002.
- R2.5 The view MUST offer a toggle between items in this area only (the default) and items in this area and every sub-area beneath it. WIQL, the ADO query language, supports both directly: `[System.AreaPath] = '...'` and `[System.AreaPath] UNDER '...'`.
- R2.6 The active filters and the toggle MUST be visible in the view, for example in a header line or the window bar.
- R2.7 Selecting a work item MUST open it with the layout in R4.2, and keep the area view open.
- R2.8 The view MUST offer "open in browser", which opens the equivalent ADO query, with the same area path and filters, in the web UI.
- R2.9 The view SHOULD offer navigation to the parent area.

### R3. Item view

- R3.1 The item view for work item N MUST show, in this order: N itself, its parent, its area path, its children, and its linked items grouped by link type. The link types shown are set by Q6.
- R3.2 Selecting the parent, a child or a linked item MUST navigate the item view to that item.
- R3.3 Selecting the area path MUST navigate to the area view for that path, with default filters.
- R3.4 A child row MUST be expandable inline to show its own children, and collapsible again. Each expansion MUST fetch one level only, when the user expands it, so a deep tree costs nothing until the user opens it.
- R3.5 The view MUST support previewing the item under the cursor without leaving the view, and opening it in the detail buffer.
- R3.6 The view MUST offer "open in browser" for the item under the cursor.
- R3.7 From any detail buffer, the user MUST be able to open the item view for that item.
- R3.8 Children and linked items MUST follow the open-state filter by default, with one toggle that shows them in every state. The parent row MUST always show, whatever its state.

### R4. Navigation and layout

- R4.1 The area view and item view MUST share one navigation history of locations, with back and forward, in the way a browser does.
- R4.2 Selecting a work item in the area view MUST produce this layout: the area view stays in its window, the selected item's detail buffer opens in a split beside it, and the item view for that item opens as a side panel next to the detail buffer. Navigating within the item view updates that same side panel.
- R4.3 Moving the cursor in the item view SHOULD NOT change the detail buffer until the user selects or previews, so browsing the tree stays cheap.
- R4.4 Every view MUST have a reload action that discards the snapshot and fetches from ADO again. A reload with unsaved edits MUST ask first.
- R4.5 Each view's buffer needs a unique name. The plugin MAY name buffers by a URI built from the location, for example `ado://area/Project/Team/Sub?state=open&subareas=0` or `ado://item/1234`. These examples are illustrative; planning sets the format.

### R5. Editable buffers

A row's position in a view stands for a relationship. In an area view, the relationship is the item's area path. In an item view, it is a parent, child or other link to the item the view is about. Deleting a row removes that relationship, pasting a row adds one, and deleting and pasting the same item in one save moves it. Saving never deletes a work item and never changes its state unless the state column on its row was edited.

"Original kept" below means the item's existing relationship was not removed in the same save: its row was not deleted from the source view, or the source view was not open.

| Edit | Area view | Item view, child list | Item view, parent row | Item view, other links |
| --- | --- | --- | --- | --- |
| Delete only | No change; the summary says so (R5.4) | Remove the item's link to this parent | Remove the link to the parent | Remove the link |
| Paste, original kept | Create a copy in this area (R5.6) | If the item has a parent: create a copy under this parent. If it has none: add it as a child | Reject if the item already has a parent; otherwise set it | Add the link |
| Delete and paste (move) | Change the area path | Change the parent | Change the parent | Move the link |
| Add a line with no ID | Create an item in this area | Create an item with this parent, in the parent's area | Not allowed | Not allowed |
| Edit a column (R5.17) | Update that field | Same | Same | Same |

- R5.1 Every row MUST carry the ID of what it represents, so that edits are identified by ID and not by matching text. The ID MAY be concealed in the display, as oil.nvim does with its `/NNN` prefix.
- R5.2 Saving MUST compute one change plan across every modified view, so that a move between two buffers is recognised as a move rather than a delete plus a paste.
- R5.3 Saving MUST show the change plan as a summary and require the user to accept it or cancel, as oil.nvim does, before any ADO call. Cancelling MUST leave the buffers as edited.
- R5.4 Deleting a row from an area view without pasting it into another area view in the same save MUST make no change, because every work item needs an area path. The summary MUST list the row as "no change" with that reason.
- R5.5 Rows hidden by a filter, or collapsed in the tree, MUST NOT be treated as deleted. Only rows that the snapshot displayed can be deleted.
- R5.6 A copy MUST be a new work item with the original's title, type and tags, plus the original's area path and parent. The relationship the destination view stands for replaces the original's: a copy pasted in area B is in area B with the original's parent; a copy pasted under parent Q has parent Q and the original's area path. A copy MUST NOT carry the assignee, the children, the description or any other links.
- R5.7 State edits (R5.17) MUST be checked against the valid states of the item's type, using the lookup in RFC 0002; an invalid state rejects the save and names the row.
- R5.8 An expanded row and the descendant rows shown beneath it MUST act as one block. Deleting, moving or copying the block changes only the top row's relationship; the descendants stay attached to it. Deleting a descendant row on its own removes only that descendant's link to its parent row. Because a copy has no children (R5.6), the descendant rows of a pasted copy are dropped on reload, and the summary MUST say so.
- R5.9 Pasting rows into an item view that would give an item two parents MUST be rejected, because ADO allows one parent per item.
- R5.10 The same work item can appear in several open views at once, for example in an area view and in an item view. The plan MUST combine edits to one ID across views. The plan MUST reject the save and name the item and the views when edits to one ID conflict: two different titles or states, or one cut pasted into two places, since which paste is the move and which the copy would be arbitrary.
- R5.11 A paste never changes the area path unless it is in an area view. An item moved under a new parent keeps its area path; only a new line with no ID takes the parent's area.
- R5.12 A move MUST NOT make an item its own ancestor; the plan MUST reject it before sending anything.
- R5.13 A change can result in an item that the destination view's filter would hide, for example an item set to `Resolved` in an open-only view. The plan MUST still perform the change, and the summary MUST say the item will not appear in that view after reload.
- R5.14 Each update MUST pass the revision guard: if the item changed in ADO since the snapshot, that operation fails rather than overwriting.
- R5.15 If an operation fails part way through a plan, the plan MUST stop, report which operations completed, which failed, and which were not attempted, and reload the affected views so the buffers match ADO.
- R5.16 Sub-area rows MUST be read-only in the first release. Creating, renaming and deleting area paths changes the project's structure for every team and is out of scope.
- R5.17 Each work item row MUST show these fields as columns, and each MUST be editable in place: title, state, assignee and tags. Type MUST show as a column and be editable, limited to the configured types (R5.21).
- R5.18 A new line MUST be able to set its type in the type column. When the type is left blank, the plan MUST use a configured default per view: one for area views and one for child lists. A type not in the configured set (R5.21) rejects the save and names the row, because a new item cannot be created without a valid type.
- R5.19 An assignee edit MUST resolve to exactly one ADO identity before the plan is shown; an unknown or ambiguous name rejects the save and names the row. Clearing the column unassigns the item.
- R5.20 A tags edit MUST replace the item's tags with the edited list. The summary MUST show the tags added and removed, not just the new list.
- R5.21 Type values MUST come from the configured set of types of the item's project (R8.6), matched without regard to case. On an existing item, a type edit that matches no configured type MUST make no change to the type, and the summary MUST list it as "no change" with the reason, so a typo cannot change an item's type.
- R5.22 A type change MUST be rejected, naming the row, when the item's current state is not valid for the new type and the row does not also set a state that is valid for it. The valid states come from the lookup in RFC 0002. Type changes MUST stand out in the summary, because ADO drops field values the new type does not have.

### R6. Architecture

- R6.1 The core MUST NOT reference `vim.*` or any Neovim API. It covers: the domain model of work items, areas and links; WIQL query building; locations and navigation history; view models (the rows of each view); the change plan computation; and plan execution.
- R6.2 The input to the change plan computation MUST be structured rows with IDs (snapshot rows and current rows per view), not buffer text. The presentation layer turns buffer lines into rows; the core never parses text.
- R6.3 The core MUST reach ADO through an injected transport interface. The Neovim layer supplies the `az` CLI transport that exists today in `lua/ado/client.lua`.
- R6.4 The core MUST be asynchronous, through callbacks or an equivalent the transport defines, because each `az` call takes seconds.
- R6.5 The presentation layer owns buffers, windows, keymaps, highlighting, and the conversion between rows and text lines.
- R6.6 The core MUST be testable with a plain Lua test runner and a fake transport. Each behaviour in section 8 MUST have a core test, which starts from rows rather than buffer text.
- R6.7 The existing modules SHOULD move onto this split. Today `wiql.lua` has no Neovim dependency; `client.lua`, `workitem.lua`, `picker.lua` and `float.lua` call the Neovim API directly, and `workitem.lua` mixes normalisation (core) with rendering (presentation).
- R6.8 The presentation layer MUST implement its own buffer handling, without oil.nvim (Q4). It MUST own `:w` for its buffers through `BufWriteCmd`, and MUST NOT let a save in another buffer, or a tree expansion, discard unsaved edits in a view.

### R7. Safety and observability

- R7.1 The plugin MUST NOT write to ADO without the confirmation in R5.3.
- R7.2 The summary MUST group the plan by kind: link removals, link additions, parent and area changes, state and title changes, copies created, rows with no change and why, and rejections. Link removals, copies and type changes MUST stand out, because they are the changes most likely to be accidental or to lose data.
- R7.3 Loading and saving MUST show progress, because a view load may take several `az` calls.
- R7.4 Every applied operation SHOULD be written to a local log file with time, operation, work item ID, and result, so the user can see afterwards what a save did and reverse it by hand.

### R8. Configuration

- R8.1 `setup()` MUST accept a new `area_paths` setting: the list of area paths offered by the area view picker.
- R8.2 `setup()` SHOULD accept default filters for the area view.
- R8.4 `setup()` MUST accept the default types for new lines (R5.18).
- R8.5 `setup()` SHOULD accept the list of link types the item view shows (Q6).
- R8.6 `setup()` MUST accept the work item types that rows may be created as or changed to (R5.21). Decision 2026-10-12 (owner): these are set per project, as the `types` of each entry in the `projects` setting ([RFC 0002](0002-open-state-filter.md) R1.8), rather than as one global `types` list.
- R8.3 The plugin MUST expose functions for the dotfiles spec to bind (`area_view()`, `item_view(id)`), matching how `my_items()` and `search()` are bound today.

## 6. Assumptions to review

Each assumption carries a risk if it is wrong.

- A1. **The core stays in Lua.** Confirmed. Another Lua host can reuse the core directly; a client in another language replicates the core module by module, which the separation in R6 keeps practical because the core has no editor dependency.
- A2. **The `az` CLI stays the transport.** It has commands for area paths, WIQL queries and work item links, and `az devops invoke` calls any ADO REST endpoint that lacks a dedicated command, such as the work item types endpoint that RFC 0002 uses. Risk if wrong: low, because R6.3 isolates the transport.
- A3. **Views fetch on demand.** No background sync; a view shows its snapshot until reload or save. Risk if wrong: a long-open view goes stale, which R5.14 makes safe but possibly annoying.

## 7. Open questions

These are decisions for the plugin owner before or during planning. Each lists a recommendation and the risk on each side. Resolved questions keep their number and record the decision.

- **Q1. What does deleting a line do?** Resolved: deleting a line removes the relationship the row stands for, and never deletes the work item or changes its state. R5 sets the rule for each view.
- **Q2. What does copying a line copy?** Resolved: the original's title, type, tags, area path and parent, with the destination view's relationship replacing the matching one; no assignee, children, description or other links (R5.6).
- **Q3. Which fields are editable inline in a row?** Resolved: title, state, assignee and tags, as columns (R5.17). Type is set on new lines (R5.18). Area path and parent are edited by moving rows, not by columns.
- **Q4. Build on oil.nvim or alongside it?** Resolved by spike: the plugin implements its own buffer handling and does not depend on oil.nvim. The spike (branch `spike/oil-adapter`, `docs/spikes/0001-oil-adapter.md`) built an oil adapter over fake data. The core computed the right change plan in all 14 edit scenarios, but only by ignoring oil's diff, which contradicted R5 in 8 of them: for example, oil sends a retitle as a move and a delete-only as a delete. Three problems sit in oil internals that an adapter cannot change. Saving any other oil buffer silently discarded an unsaved work item edit. oil keys rows by name, so two items with the same title showed as one row. Expanding a tree row discarded unsaved edits. The plugin reuses three of oil's ideas instead: a concealed ID prefix on each row (R5.1), one ID registry across buffers so pasted lines keep their identity (R5.2), and a snapshot of rows per buffer.
- **Q5. Does indentation in the item view's tree carry meaning?** Resolved: no, for the first release. Indentation only displays the tree; reparenting is done by moving rows. Revisit once the editing rules in R5 have been used in practice.
- **Q6. Which link types does the item view show?** Resolved: parent, child and Related by default, with the list configurable through `setup()` (R8.5).
- **Q7. Can the type column change an existing item's type?** Resolved: yes, limited to a configured set of types (R5.21, R8.6). A value outside the set is ignored, not applied. The dotfiles configuration will pass `Task`, `User Story`, `Feature`, `Milestone`, `Bug` and `Issue`; `Epic` is deliberately left out.

## 8. Acceptance behaviours

Each behaviour is written so it can become a core test against a fake transport, starting from rows (R6.6).

1. Given area `P/Team` with sub-areas `A` and `B` and three open items, the area view rows are `A`, `B`, then the three items.
2. With the sub-area toggle on, the area view of `P/Team` also lists items in `P/Team/A`.
3. Navigating from `P/Team` into `A` keeps the assignee filter set on `P/Team`.
4. Selecting an item in an area view produces an item location for that item; back returns to the area location with its filters.
5. In the item view of N, selecting the area row produces the area location for N's area path.
6. Adding a titled row with no ID under N's children produces a plan of one create, with parent N and N's area.
7. Moving child C from P's view to Q's view in the same save produces a plan of one parent change, from P to Q, and no create.
8. Moving item X from area A's view to area B's view produces a plan of one area path update.
9. Deleting item X from area A's view with no paste elsewhere produces an empty plan, and the summary lists X as "no change".
10. Pasting item X into area B's view while X stays in area A's view produces one create in area B, with X's title, type, tags and parent, and no assignee or description.
11. Pasting child C, whose parent is P, under Q while C stays in P's view produces one create with parent Q and C's area path.
12. Pasting item X, which has no parent, under Q produces one parent link from X to Q and no create.
13. Deleting child C from P's view with no paste elsewhere produces one link removal and no state change.
14. Pasting item M into N's parent row while N's existing parent row stays produces a rejection.
15. Deleting expanded row C together with its displayed children produces one link removal, for C only.
16. Cutting item X once and pasting it into two views produces a rejection that names X.
17. Moving child C under Q leaves C's area path unchanged.
18. Changing the state text of a row to a state its type does not have produces a rejection that names the row.
19. Retitling item X differently in two views in the same save produces a rejection that names X.
20. Setting an item to `Resolved` in an open-only view produces the state change and a warning that the item will not appear.
21. Deleting a row that a filter hid produces an empty plan.
22. Moving N under one of its own descendants is rejected before any transport call.
23. When the second of three operations fails, the plan reports one completed, one failed, one not attempted, and the affected views reload.
24. An update to an item whose revision changed since the snapshot fails without writing.
25. Changing the assignee column to a name matching two identities produces a rejection that names the row.
26. Removing one tag and adding another on a row produces one update, and the summary lists the tag removed and the tag added.
27. A new line with a blank type in a child list produces one create with the configured child-list default type.
28. Changing the type column of an existing `Task` to `user story` produces one type change to `User Story`, shown as a type change in the summary.
29. Changing the type column of an existing item to a value outside the configured set, such as `Epic` or `Taks`, produces no change, and the summary lists the row as "no change".
30. Changing an item's type when its current state is not valid for the new type, without also setting a valid state, produces a rejection that names the row.
