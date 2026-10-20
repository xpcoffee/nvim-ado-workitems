# Plan 0003: One item buffer, with the description and comments

- Status: Phases 1 and 2 built on branch `feat/navigator`, awaiting the owner's manual checks and a live read of the comments route (see "Phase 1 as built" and "Phase 2 as built").
- Date: 2026-10-16
- Implements: [RFC 0003](../rfc/0003-combined-item-view.md), with the owner's answers of 2026-10-16 (RFC section 14): Q1 to Q3 and Q5 to Q9 accepted as recommended, Q4 rejected.
- Format: as [plan 0001](0001-implementation-plan.md) and [plan 0002](0002-ux-plan.md), phases as vertical slices, each usable on its own.

Requirement IDs `C1.1`, `C2.1`, ... and the numbered acceptance behaviours refer to RFC 0003. Terms from `docs/architecture.md` and RFC 0003 section 4 keep their meaning: row, row ID prefix, registry, view record, save summary, fixed line, item buffer, header region, read-only region, boundary line, comment page, continuation token, footer line. This plan adds two:

- **Header end**: the number of lines above the boundary line. Every module that reads buffer lines as rows reads lines 1 to the header end and no further.
- **Quiet write**: a change the plugin makes to the read-only region that adds no undo step and keeps the user's undo history and the modified flag (C2.6, C2.7).

## Status in one paragraph

Q4 removes the only new header field, so the header is today's item view unchanged. The one finding that shapes the build is about undo. Today the plugin keeps its own writes out of the undo history by setting `'undolevels'` to -1 for the change (`view_buffer` `edit`), and Neovim then clears the whole history at that change (`:help 'undolevels'`). That is harmless for a load, which replaces the buffer, but C2.7 needs a page of comments written under unsaved header edits that `u` can still undo. A probe on Neovim 0.11.6 (`nvim --headless -u NONE -l`) found a way that keeps them: write the history to a file with `:wundo`, make the change with `'undolevels'` at -1, write a second undo file for the new text, copy the second file's text hash and line count into the first, and read it back with `:rundo`. After that, `u` undid the header edit and left the appended lines, and `<C-r>` redid it. Phase 1 builds this as the quiet write and uses it for the staged description; phase 2 uses it for pages.

## 1. Why this order

1. **The combined buffer first (phase 1).** It removes the stale-revision problem of RFC section 2.1 and the duplicate fields, and every later behaviour needs the header end and the read-only guard. It is usable alone: the owner reads and edits one buffer per item, and the description is saved with `:w`.
2. **Comments second (phase 2).** Paging needs a new transport operation and the quiet write, and it writes into the read-only region that phase 1 guards. Without phase 2 the item buffer ends at the details, which is today's information minus nothing.

## 2. Phases at a glance

| Phase | Delivers to the owner | RFC items | Waits for |
| --- | --- | --- | --- |
| 1. The combined item buffer | One buffer per item: header, `── Details`, the description; description edits saved with `:w`; one item window under the list; `K`, `gd`, `<leader>wd`, `<leader>wc` | C1, C2, C3, C6, C7.4, C7.5 | nothing |
| 2. Comments | Comments newest first, 5 at a time, loading as they come into view | C4, C5, C7.1 to C7.3, C7.6 | phase 1 |

## 3. Module layout

```text
lua/ado/
  core/
    item_view.lua      CHG  rows end with the boundary row (P1)
    item_details.lua   NEW  the details lines: changed, description; text wrapping (P1)
    timestamp.lua      NEW  ISO 8601 to epoch seconds, without vim (P1)
    plan.lua           CHG  rejects a changed read-only region (C2.2); description op (C7.5) (P1)
    summary.lua        CHG  "description changed" line (P1)
    workitem.lua       CHG  changed_at, comment_count (P1, P2)
    comments.lua       NEW  paging state, merge, de-duplication, trigger rule, footer, render (P2)
    transport.lua      CHG  list_comments (P2)
    write_guard.lua    CHG  list_comments is a read (P2)
    session.lua        CHG  Session:list_comments (P2)
  nvim/
    region.lua         NEW  header end per buffer, the read-only text, insert refusal (P1)
    quiet_edit.lua     NEW  changes that keep the undo history (P1)
    markup.lua         NEW  pandoc conversions, moved from detail.lua (P1); html to plain (P2)
    browser.lua        NEW  browser_open, moved from detail.lua (P1)
    item_view.lua      CHG  renders the details, stages the description, K, gd, <leader>wd, <leader>wc (P1);
                            comments paging and its triggers (P2)
    view_buffer.lua    CHG  record, conceal and refit stop at the header end (P1)
    realign.lua, fit.lua, decorations.lua, cells.lua, complete.lua, pick.lua, reveal.lua, hover.lua
                       CHG  stop at the header end (P1)
    layout.lua         CHG  two roles; item window two thirds (P1)
    keymaps.lua        CHG  item keys (P1)
    picker.lua         CHG  opens the item buffer; state pick moved in (P1)
    detail.lua         DEL  (P1)
    az.lua             CHG  list_comments (P2)
  init.lua             CHG  open, open_prompt, toggle_item_view without the detail buffer (P1)
tests/support/fake_transport.lua   CHG  list_comments with paging, CommentCount (P2)
tests/bench/views_bench.lua        CHG  header edit with comments below; quiet write of a page (P1, P2)
```

## 4. Test approach

As plans 0001 and 0002: core specs in the sandbox, presentation specs in headless Neovim against the fake transport, each named after the requirement or acceptance behaviour it checks. Two additions:

- **Mutation checks.** For the read-only guard (C2.1 to C2.3) and the header end in each module (C2.5), a scratch run disables the guard in a uniquely named copy of the file, confirms the change is in place, runs the spec and expects it to fail, then restores the file from the copy. These runs are not committed.
- **Real UI.** Paging and the layout are checked in a terminal Neovim under `tmux`, with the fake transport, by reading the pane.

## 5. Phases

### Phase 1: The combined item buffer

**Delivers.**

- P1.1 The item buffer shows the header as the item view does today, then a fixed `── Details` boundary row, then `changed:` and the description (C1.1, C1.2, C3.1). The window bar shows ID, type, rev and changed time (C1.4).
- P1.2 Every module that reads buffer lines as rows stops at the header end (C2.5); the view record holds only header lines, plus the boundary row when it is where it was rendered (C2.1).
- P1.3 `:w` rejects the save when the read-only region changed (C2.2) or the boundary line was deleted or moved (C2.3), and sends nothing for any view. Entering Insert mode on the boundary or below leaves Insert mode with a message (C2.4).
- P1.4 `<CR>` on the description and `<leader>wd` open the markdown float; `<C-s>` stages the description (C3.2 to C3.5): no write, the buffer is modified, the description shows the new text with `~` signs, `:w` sends it in the item's one patch and the summary says "description changed". Staging is a quiet write.
- P1.5 The detail buffer is gone (C6.1, Q3). Two roles in the layout, the item window two thirds of the column with the list open (C6.2, Q8). Every entry point opens the item buffer (C6.3, C6.4). `K` shows the row's item in a float; `gd` is `<CR>`; `<leader>wS` is gone (C6.7, C6.8, Q9). `<leader>wc` adds a comment through a multi-line float, sent at once through the write guard (Q5).

**Core stays with:** the boundary row, the details lines, wrapping, timestamps, the plan's read-only and description rules. **Presentation keeps:** the header end, the read-only text, the quiet write, pandoc, floats, keys, layout.

**Exit criteria.** `make test` passes in name, reverse and shuffle order; `make bench` meets every target, including a new one: a header edit's whole `TextChanged` with 1,000 read-only lines below it within 1 ms of the same edit without them. The mutation checks fail as expected. Acceptance behaviours 8 to 10, 13 to 15, 20, 21, 23, 25, 27 and 28 have tests.

**Manual checks.** Open an item from the area view: two windows, the item window larger, the cursor in it. Edit a title, then the description, `:w`: one summary with both. `dd` on the description, `:w`: rejected; `u`, `:w`: saved. `K` on a child shows a float; `gd` opens the child. `<leader>wi`, `<leader>wa`, `<leader>wA`, `<leader>wI` behave as before.

**Risks.**

- The quiet write depends on the undo file's layout (the hash and line count after the 11-byte header). A Neovim release that changes it would make `:rundo` refuse the file. The quiet write then falls back to the plain write, which clears the history, counts `quiet_write_failed` in `ux_stats` and warns once. A spec checks the undo history survives, so an upgrade that breaks it fails the tests.
- A module that misses the header end treats details lines as rows (RFC R2). Each module has a test with a details line that looks like a row (behaviour 13), and a mutation check.

#### Phase 1 as built (2026-10-16)

Built on branch `feat/navigator` as specified, with the deviations below. `make test` passes 605 tests (589 before the phase) in name, reverse and shuffle order. The phase adds `tests/core/item_buffer_plan_spec.lua` (10) and `tests/nvim/item_buffer_spec.lua` (19), one `item_view_spec` core case, and replaces the 12 cases of `tests/nvim/detail_spec.lua`, which tested the detail buffer's per-field floats, with item buffer and layout cases.

`make bench` (WSL2, Neovim 0.11.6, 40 runs per case); the earlier rows are unchanged from plan 0002 within noise:

| Case | Median | Largest | Target |
| --- | --- | --- | --- |
| header edit's whole `TextChanged`, 1,000 read-only lines below | 0.48 ms | | within 1 ms of the same edit with none: -0.02 ms |
| quiet write of 4 lines with 100 undo steps | 3.93 ms | 8.29 ms | under 25 ms, history kept |

Mutation checks (section 4), each on a uniquely named copy restored after the run: dropping the plan's read-only rejection, the record's `readonly_changed`, the description op, the Insert-mode guard, the quiet write's history, or the header end in the record, re-pad, decorations, conceal, refit, cell text objects, `<leader>wx` or the Insert-mode menu target each made at least one spec fail. One survived: `fit.snapshot` reading every line. The snapshot only records lines that start with a row ID, so a read-only line could only reach it by starting with the ID of a row shown above; the cell rule then fails closed (two different texts for one row give no value). No spec covers it.

Deviations from the plan and the RFC, each low risk. Those marked **changes behaviour** change what the owner does today.

1. **`<CR>` on the item's own title and field lines does nothing** (**changes behaviour**). It opened the detail buffer, which is gone; the title and fields are edited in place.
2. **`<leader>wc` is refused while the item buffer has unsaved edits** (**changes behaviour**: the detail buffer allowed it at any time). A comment raises the item's rev (the detail buffer's code replaced its item with the updated one), so the header's next `:w` would fail as changed remotely. After a comment the header reloads quietly. Risk PA2 records this.
3. **Insert mode ends by an `<Esc>` put before the typed keys**, not `:stopinsert`: in the real UI, `:stopinsert` in `InsertEnter` was undone when Insert mode started, and the typed text went into the details. The `tmux` check confirmed the `<Esc>`. Headless specs cannot hold Insert mode, so they check the guard's message.
4. **The quiet write's second undo file comes from adding and removing a space at the end of the last line.** Replacing line 1 with itself, as the probe did, moved the item's `this item` label to the next line in the real UI; a spec now checks the labels stay.
5. **A staged description is not undone by `u`**, which follows from C2.6. `u` back to the loaded header leaves the buffer modified, because Neovim clears the flag when undo reaches the loaded text; `TextChanged` sets it again, and the save also treats a staged description as an edit.
6. **The description's lines are wrapped to the window** when the details are written (`core/item_details.wrap`), with list items' continuation lines under their text; a resize does not wrap them again until the next render. The markdown in the float is not wrapped.
7. **The header end follows a boundary row pasted higher up**, so the rows below it count as read-only text and the save rejects; a boundary moved lower leaves the header end where the boundary was.
8. **`K` uses Neovim's floating preview** (`vim.lsp.util.open_floating_preview`), so `K` twice enters the float to scroll it, as `K` does for LSP hover.
9. **`layout.toggle_item()` takes no ID**, since no detail buffer names one; `toggle_item_view()` keeps its name and behaviour for the key bound to it.
10. **The search picker's `<C-s>` still writes a state at once** through `update_if_unchanged`. RFC 0003 does not cover the picker; G3 applies to the item buffer.
11. **A test-harness leak fixed**: headless Neovim kept the first window 80 columns wide until a split, so `realign_spec` failed when run first (`ORDER=shuffle` or `ONLY=`). `views.fresh()` now rebuilds the layout.

Manual checks still to run in the owner's editor: the list above under "Manual checks", in nightfox with `:syntax on`.

### Phase 2: Comments

**Delivers.**

- P2.1 `list_comments` in the transport contract, the `az` transport (`az rest` on the comments route, `7.1-preview.4`), the fake (paging by `createdDate`) and the write guard's reads (C7.1).
- P2.2 `core/comments.lua`: the paging state, merge with de-duplication by ID, the trigger rule `footer - w$ <= floor(h / 2)`, stale-response rules by generation and token, the heading and footer texts, and the comment lines (C4, C5.1, C7.2, C7.3).
- P2.3 The item buffer shows `── Comments: N` from `System.CommentCount`, loads pages by the trigger on `CursorMoved`, `WinScrolled` and `WinResized` and after each page, one in flight, as quiet writes that replace the footer line (C2.6 to C2.8, C4.1 to C4.7). HTML comments convert with one pandoc call per page, off the main loop (C5.2, risk R4).
- P2.4 Reload rules: `<leader>wr` starts again; the reload after a save keeps the comments and says how many are new; history shows the loaded comments with no call (C4.8 to C4.10). `<leader>wc` merges the new comment from the first page.
- P2.5 `ux_stats()` reports pages, durations, failures and dropped responses (C7.6).

**Exit criteria.** As phase 1, plus a bench target: a quiet write of one page with 100 undo steps and 500 comment lines shown, under 25 ms. Acceptance behaviours 1 to 7, 11, 12, 17 to 19, 22, 24 and 26 have tests. A live read on an item with many comments reports counts and timings only.

**Manual checks.** In a real terminal: an item with more than 5 comments loads the first page when scrolled into view, then the rest while moving down; the footer reads "all N comments shown". Edit a title, scroll to load a page, `u`: the title reverts and the comments stay.

**Risks.**

- The comments route is a preview API (RFC A1). One constant in `nvim/az.lua`; a failed page leaves the buffer working (C4.7).
- pandoc's cold start (RFC R4). The page conversion runs asynchronously, so it never blocks the editor.

#### Phase 2 as built (2026-10-16)

Built on branch `feat/navigator` as specified, with the deviations below. `make test` passes 638 tests (605 after phase 1) in name, reverse and shuffle order. The phase adds `tests/core/comments_spec.lua` (12), `tests/nvim/comments_spec.lua` (17), and cases in `fake_transport_spec` (3), `write_guard_spec` (1) and `az_spec` (2).

`make bench` (WSL2, Neovim 0.11.6, 40 runs per case): the quiet write the pages use, replacing the footer line with 4 lines under 100 undo steps and 1,000 read-only lines, took 3.80 ms at the median and 7.52 ms at most, against the 25 ms target, and kept the history. A header edit's `TextChanged` with 1,000 read-only lines below cost -0.03 ms more than with none. In the `tmux` check with pandoc, a page took 18 ms from the call to the write (`ux_stats`, fake transport, warm pandoc).

Mutation checks, as in phase 1: merging stale responses, dropping the de-duplication, allowing two pages in flight, retrying a failed page by itself, not pausing on an edit, clearing the history on a page write, dropping the comments on a save's reload, a page call that is not quiet, loading the first page on open, and keeping the comments on an explicit reload each made at least one spec fail.

Real UI (`tmux`, fake transport, pandoc 3.1.3): 23 comments loaded in 5 pages as `G` moved to each new footer; the footer ended `all 23 comments shown`; a mention showed as `@Alex Smith` and a list as `-   one`; an edited comment said `edited`; editing a title, loading a page and `u` reverted the title and kept the comments; `dd` on a comment line paused paging with the message at the end of the last line, and `u` resumed it; in a 70-column window the comment text wrapped under its indent.

Live read: not done. `az rest` failed with `AADSTS50135: Password change is required due to account risk` before reaching ADO, so neither the comments route nor `System.CommentCount` from `get_work_item` was checked against the real organisation in this phase. The owner needs to sign in again (`az login`), then open an item with more than 5 comments and check the footer and `require("ado").ux_stats()`.

Deviations, each low risk:

1. **The paused message is end-of-line text on the last line**, not the footer line's text: while the user's change stands, the plugin cannot know which line is the footer, so it writes nothing. A virtual line below the last line was hidden when the cursor sat on the last line.
2. **The footer while the first page is in flight says `loading comments…`**, since "0 of 8 comments shown, loading more" reads oddly. An item with no comments has no footer: the heading says `── Comments: none`.
3. **A count the item load does not report** shows `── Comments` and a footer `move down to load the comments`; the first page then gives the count (risk PA1).
4. **Comment text is wrapped to the window** like the description (phase 1, deviation 6), at the width when the page was written.
5. **Pages merged while paging is paused** are kept and written once the change is undone, so a response that arrives during the user's edit is not lost.
6. **The page conversion runs asynchronously** (risk R4 of the RFC): pandoc runs off the main loop, with a separator line between comments so one call converts the page. The RFC's 2.7 s cold start did not repeat on 2026-10-16: three runs of pandoc 3.1.3 took 0.03, 0.01 and 0.01 s, but the first after a reboot was not measured. The description's conversion stays synchronous, as before.
7. **After `<leader>wc`, the first page is read again and its new comments go first**, only when the buffer still has no unsaved edits; otherwise the heading's count says a comment is new.

## 6. Risks and assumptions

| ID | Risk or assumption | If wrong | Mitigation |
| --- | --- | --- | --- |
| PA1 | `get_work_item` returns `System.CommentCount` (RFC section 7; not rechecked live in phase 2, see "Phase 2 as built"). | The heading shows no count. | A missing count is treated as unknown: the heading shows `── Comments` and the first page loads by the trigger. |
| PA2 | Adding a comment raises the item's rev, as the detail buffer's code assumed (it replaced the item with the updated one). | Nothing: the guard below only costs a save first. | `<leader>wc` is refused while the buffer has unsaved edits, so a comment never makes the header's next `:w` fail as changed remotely; after a comment the header reloads quietly. |
| PR1 | The quiet write (section "Status") depends on the undo file layout. | Header undo history is lost on a page write. | Fallback, warning and test, phase 1 risks. |
