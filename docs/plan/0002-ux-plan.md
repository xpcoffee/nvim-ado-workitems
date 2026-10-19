# Plan 0002: Making the views look and behave better

- Status: Phases 1 to 5 built, awaiting the owner's manual checks (see "Phase 1 as built" to "Phase 5 as built"). The owner answered PQ1 on 2026-10-15: option T, with both guards required (section 8).
- Date: 2026-10-13
- Implements: the recommendations R1 to R6 of [spike 0002](../spikes/0002-vim-ux.md), with the owner's answers to its questions Q1 to Q5 (2026-10-13, all defaults accepted).
- Format: as [plan 0001](0001-implementation-plan.md), phases as vertical slices, each usable on its own.

Requirement IDs UX1.1, UX2.1, ... belong to this plan; group UX*n* takes its number from spike recommendation R*n*. UX5 replaces the spike's R5 mechanism (phase 5 says why). "R5.19" and similar IDs refer to RFC 0001, as in plan 0001. Terms from `docs/architecture.md` keep their meaning: row, row ID prefix, registry, snapshot, view record, type catalog, save summary, core, presentation layer, sandbox. This plan adds three:

- **Re-pad**: rewriting the spaces between cells so that every row's separators line up again (spike section 3.1, approach A).
- **Text width**: the columns of a window that show buffer text, which is the window width minus the sign column, number column and fold column (`getwininfo(win)[1].textoff`).
- **Cut cell**: a cell whose text is longer than its column's width, shown shortened and ending in `…`.

The owner's answers to the spike's questions, 2026-10-13, which this plan builds on:

| Question | Answer |
| --- | --- |
| Q1 alignment | Real padding rewritten after each edit (the owner uses `<C-v>`), joined with `:undojoin`; only the edited line may drift until `<Esc>`. |
| Q2 narrow widths | Drop tags first, then show type as one letter, then shorten the assignee; the title never below 20 columns. |
| Q3 assignee | Picking a person inserts their email; the search still works by name. |
| Q4 full-text float | Opens by itself when the cursor rests on a cut cell, cut cells only. |
| Q5 old value | No old-value marker on edited lines. |

## Status in one paragraph

A check made for this plan found that the spike's way of fitting columns to the window cannot work. The spike proposed hiding the tail of a long cell with a conceal extmark. Neovim 0.11.6 still counts concealed text when it decides whether to scroll a window sideways, so moving the cursor into any cell to the right of a hidden tail (the assignee of a row with a long title, for example) scrolls the whole window, and every other row is then drawn from the wrong column. `spike/ux/scroll_probe.lua` reproduces it: a 60-character cell cut to 10, in a 40-column window, scrolls the window 43 columns as soon as the cursor reaches the next cell. Phases 1 to 4 do not depend on fitting and can start. For phase 5, PQ1 asks the owner to choose between two options. Option T (recommended) cuts the text in the buffer itself and keeps the full value in the plugin; rows always fit, but a save must restore full values, and a bug in that rule could save a shortened title to ADO. Two guards stand against that: the save rejects any cell it cannot restore, and the save summary shows every changed title in full before `y`. Option C keeps the spike's conceal design; the save is untouched, but moving the cursor to the assignee or tags of a row with a cut title scrolls the window and misaligns every row. The owner chose T on 2026-10-15, and phase 5 is built ("Phase 5 as built").

## 1. Why this order

1. **Alignment first (phase 1).** Every later phase finds cells by their separators and writes into them: the colour markers (phase 2), the pickers (phases 3 and 4) and the fitting (phase 5). Phase 1 builds the cell model they share (where each cell starts and ends, the `ic`/`ac` text objects) and the re-pad that keeps rows aligned after those writes.
2. **Colour and change markers next (phase 2).** It is the largest visible change for the least risk: no new keys, no change to the save, and one extra field in a call the session already makes.
3. **Type and state pickers (phase 3)** build the completion module and the "write a value into this cell on every selected row" action that phase 4 reuses.
4. **People search before fitting (phase 4).** The spike's suggested order put fitting before people search. This plan swaps them: people search needs only phase 3, it removes a daily chore (typing assignee names the save then rejects as ambiguous), and fitting now needs an owner decision and a prototype. Doing people search first means a failed prototype holds nothing else back. Phase 4 writes whole cells, which is the one kind of edit that every fitting option in phase 5 handles without special rules.
5. **Fitting last (phase 5).** It has the most editing edge cases and, after the finding above, touches the save. Its prototype (5a) needs no answer and can run any time after phase 1, for example alongside phase 2.

Each phase ends with a plugin the owner can use every day: no phase leaves a feature half-wired behind a flag.

## 2. Phases at a glance

| Phase | Delivers to the owner | Spike item | Waits for |
| --- | --- | --- | --- |
| 1. Aligned columns and cell text objects | Separators line up again on `<Esc>`; `cic` replaces a whole cell | R1 | nothing |
| 2. Colour, change markers and counts | Type and state in ADO's colours, dimmed separators, `~`/`+` in the sign column, counts in the window bar | R2 (P5-a to P5-e) | nothing |
| 3. Pickers for type and state | `<C-Space>` in Insert mode lists valid values; `<leader>we` sets a column on every selected row | R3 | phase 1 |
| 4. People search for the assignee | `<C-Space>` in the assignee cell searches people by name and inserts the email | R6 | phase 3 |
| 5. Fit to the window | Rows fit the window, long cells end in `…`, a float shows the full row | R4, R5 | phase 1; 5b waits for PQ1 |

The spike labels its problems P1 to P5; P5 is "the views look plain", and P5-a to P5-h are its polish items. Optional polish from the spike (P5-f save-summary verbs, P5-g empty-state line, P5-h `?` help) is not in these phases. Each is small and independent and can follow in any order.

## 3. Module layout

New and changed modules, with the phase that creates or changes each. Everything under `core/` stays free of `vim` (the sandbox enforces it); string width is passed in as a `measure` function, which is `vim.fn.strdisplaywidth` in Neovim and a UTF-8 code point count in the core tests.

```text
lua/ado/
  core/
    table_layout.lua   NEW  column widths, padding, cell ranges (P1); width budgets,
                            drop order, cut text, letters (P5)
    row_changes.lua    NEW  changed fields of one row against its snapshot (P2)
    choices.lua        NEW  valid values for a type or state cell (P3)
    people.lua         NEW  people candidates: local, cached, searched, ranked (P4)
    row_info.lua       NEW  a row as labelled values for the hover float (P5)
    types.lua          CHG  colour per type and state (P2); states with category (P3)
    plan.lua           CHG  uses row_changes (P2); rejects an ambiguous cut cell (P5)
    session.lua        CHG  Session:people() (P4)
  nvim/
    lines.lua          CHG  render and parse through table_layout; cell_at (P1)
    realign.lua        NEW  re-pad after edits, joined with :undojoin (P1)
    cells.lua          NEW  cell under the cursor, ic/ac, write a value into cells (P1, P3)
    ux_stats.lua       NEW  counts and durations of re-pad, decorate, search, layout (P1)
    highlights.lua     NEW  Ado* groups, groups per ADO colour, ColorScheme (P2)
    decorations.lua    NEW  colour extmarks, state dots, signs (P2); cut and hover marks (P5)
    complete.lua       NEW  Insert-mode menus: enums (P3), people (P4)
    hover.lua          NEW  full-row float on a cut cell (P5)
    view_buffer.lua    CHG  attaches realign and decorations; winbar with %= (P1, P2);
                            re-layout on resize (P5)
    keymaps.lua        CHG  ic/ac (P1), <C-Space>, <leader>we (P3), <leader>wx (P5)
    area_view.lua      CHG  winbar counts (P2)
    item_view.lua      CHG  winbar counts (P2); expansion through table_layout (P1)
    az.lua             CHG  TYPES_PROJECTION gains color (P2)
    session.lua        CHG  a quiet flag so a failed people search is reported once (P4)
    registry.lua       CHG  full values of cut cells (P5)
  init.lua             CHG  ux_stats() (P1)
  config.lua           CHG  ui.icons (P2), ui.type_letters (P5)
syntax/adoarea.lua, syntax/adoitem.lua   NEW  separators, area and heading marks (P2)
tests/support/screen.lua                 NEW  read drawn cells of a window (P1)
tests/bench/views_bench.lua              NEW  timings at 200 and 1,000 rows, `make bench` (P1)
```

## 4. Test approach

The runner, sandbox and fake transport from plan 0001 section 5 stay as they are. Core specs test every pure function above in the sandbox. Presentation specs run in headless Neovim against the fake transport. Three facts about headless Neovim shape those specs; each was checked on 0.11.6 with `nvim --headless -u NONE -l` while writing this plan:

- **`TextChanged` does not fire** after `nvim_feedkeys(keys, "xt", false)`, nor after `nvim_input` followed by `vim.wait`. `InsertLeave` does fire. Specs therefore make a change with `nvim_feedkeys`, then run `nvim_exec_autocmds("TextChanged", { buffer = buf })` themselves. With that, `:undojoin` behaves as in a real editor: one `u` restored an edit and its re-pad together, `<C-r>` redid both, and `:undojoin` straight after `u` raised `E790: undojoin is not allowed after undo`.
- **The screen stays 80 columns wide.** Setting `vim.o.columns = 120` left the window at 80. A vertical split resized with `nvim_win_set_width` works, so screen specs use splits of 40, 60 and 78 columns. Behaviour at 100 columns is covered by core layout specs and the manual checks.
- **The drawn screen can be read.** `vim.fn.screenstring(row, col)` after `redraw!` returns what is drawn, with conceal applied and sideways scrolling included. `tests/support/screen.lua` wraps this as `screen.rows(win)`, so a spec can assert that separators sit in the same screen column on every row.

`make bench` runs `tests/bench/views_bench.lua`, which times re-pad, decoration and layout on 200 and 1,000 rows and prints the numbers. It is not part of `make test`, because timings vary by machine. The size that matters day to day is 200 items, the `default_query_top` cap in `config.lua`; 1,000 is the most a view can hold if the owner raises the cap, since `az boards query` stops near 1,000 (1,179 seen, plan 0001 section 4.1). The only measured baseline is the spike's: rendering every row with inline virtual text took 5.0 ms for 200 rows and 22.0 to 23.0 ms for 1,000. The spike did not time approach A.

Each requirement gets one test named after it, for example `test("UX1.2 one u undoes an edit and its re-pad", ...)`, as in plan 0001.

## 5. Phases

### Phase 1: Aligned columns and cell text objects

**Delivers.**

- UX1.1 After a change in Normal mode, and when Insert mode ends, every item row of the view is re-padded so its separators line up. Only the lines whose padding is wrong are rewritten.
- UX1.2 The re-pad joins the user's change in the undo history: one `u` undoes both, `<C-r>` redoes both.
- UX1.3 During Insert mode only the edited line may drift (Q1). Blockwise visual changes (`<C-v>` over a column, then `c`) work on every row, because the padding is real text.
- UX1.4 A re-pad never changes what a save plans, and never sets the modified flag of an unmodified view. Loads, expansions and the reload after a save are not re-padded by the autocommand: they render already aligned.
- UX1.5 The cursor stays in the same cell, at the same offset in it, across a re-pad.
- UX1.6 The end-of-line labels ("this item", "parent") and the concealed row ID prefixes survive a re-pad.
- UX1.7 `ic` and `ac`, in operator-pending and Visual mode, select the cell under the cursor: `ic` its trimmed text, `ac` the text with its padding and the separator after it (before it, for the last cell, as `aw` does). On an item row the cells follow the parse rule of `lines.parse` (type and state from the first two separators, assignee and tags from the last two), so a title holding `│` is one cell. On a field line (`state:`) the cell is the value; on the item view's own title line it is the whole title. On an empty cell `ic` selects its padding, so `cic` still inserts at the cell start. On a sub-area or heading row the object selects nothing. `.` repeats `cic`.
- UX1.8 Each re-pad records its duration in `ux_stats`; `require("ado").ux_stats()` prints counts, last and largest durations. A re-pad over 50 ms writes one warning to `:messages` per session.

**Modules.**

- Create `core/table_layout.lua` with `widths(rows, measure)` (the widest cell per column, as `lines.render` computes today), `pad(cells, widths, measure)` and `ranges(text, layout)` (byte range of each cell, by the parse rule for that layout). In phase 1 the only layout is `full`, 4 separators; phase 5 adds `no_tags`, 3 separators, so the signature carries the layout from the start. `nvim/lines.lua` calls them; its line format does not change.
- Create `nvim/realign.lua`. It listens to `TextChanged` and `InsertLeave` on each view buffer and skips when: the buffer is in Insert mode; `changedtick` has not moved since its last pass; the change came from the plugin's own `edit()` in `view_buffer.lua` (a load, an expansion, a save's reload); or the undo tree is not at its newest state (`undotree().seq_cur < seq_last`), which is the state after `u`, where `:undojoin` raises `E790`. After `u` every state is already aligned, because each change was joined to its re-pad, so skipping costs nothing. It runs inside `nvim_buf_call`, because `:undojoin` acts on the current buffer.
- The re-pad rewrites only the runs of spaces that are wrong, with `nvim_buf_set_text`. The prototype `spike/ux/realign_proto.lua` rewrote the whole buffer with `nvim_buf_set_lines`, which would move or drop the label and conceal extmarks `view_buffer.lua` places (reasoned, not run).
- Create `nvim/cells.lua` (cell under the cursor, `ic`/`ac`) and map the objects in `nvim/keymaps.lua`.
- `nvim/item_view.lua`: expansion keeps passing `entry.widths` to `lines.render` and now goes through `table_layout`, so inserted rows line up without a re-pad.
- Create `nvim/ux_stats.lua`, `tests/support/screen.lua`, `tests/bench/views_bench.lua` and a `bench` target in the `Makefile`.

**Core stays with:** column widths, padding and cell ranges, as pure functions of text and `measure`. **Presentation keeps:** the autocommands, `:undojoin`, cursor restore and extmark care.

**Core tests.** `table_layout_spec`: widths with wide characters (a CJK title, `…`) and indented child rows; `pad` round-trips through `ranges`; a title holding `│` and `/` stays one cell (plan 0001's scenario S13); a line with fewer separators than its layout needs has no cell ranges and is left alone.

**Presentation tests.** `realign_spec`: UX1.1 to UX1.6, including `ce` over a state then `<Esc>`; `<C-v>` change over the state column of 3 rows; `u` then `<C-r>`; `dd` then `p`; a row pasted from another view with different widths; `:s` over a range; a macro; `<C-c>` out of Insert mode (it skips `InsertLeave`, so the following `TextChanged` must do the re-pad); a load and an expansion leave the modified flag off; labels and prefixes still present; separators in the same screen column on every row, read with `screen.rows`. `cells_spec`: UX1.7 on each row kind, including an empty cell and `.` repeat.

**Manual checks**, in the owner's editor at 100 columns:

- Type `In Progress` over `Active`: only that line drifts, and `<Esc>` realigns every row.
- `u` once restores the old text and widths.
- `<C-v>` over three state cells, then `cClosed<Esc>`.
- `cic` on an assignee replaces the whole name (today `cw` on `Jane Doe` leaves `Doe`).
- `:w` after only realigning says there is nothing to save.
- `require("ado").ux_stats()` shows the re-pad times.

**Exit criteria.** `make test` passes. On a 200-row view, `make bench` reports a re-pad under 5 ms for an edit that changes no column width and under 25 ms for one that widens a column; at 1,000 rows, under 25 ms and 50 ms. The manual checks behave as described.

**Risks.**

- `:undojoin` edge cases. The detection is the spec list above, which covers every way the owner changes text in the views (Normal commands, Insert mode, blockwise, paste, `:s`, macros, `u`/`<C-r>`, `<C-c>`). A case that leaves the views misaligned without breaking undo is a low-risk follow-up; a case that breaks undo stops the phase.
- Re-pad slower than the targets at 1,000 rows. `make bench` runs from the first commit of the phase. If the target is missed, re-pad only the changed lines unless a column width changed, which is the common case.

#### Phase 1 as built (2026-10-13)

Built on branch `feat/navigator` as specified, with the deviations below. `make test` passes 447 tests (414 before the phase); the phase adds `table_layout_spec` (7), `realign_spec` (17) and `cells_spec` (9). The `spike/ux/` prototypes this plan links to stay on the spike branch.

`make bench` on the owner's machine (WSL2, Neovim 0.11.6, 40 runs per case; "rewrites" is the number of lines the re-pad rewrote):

| Rows | Edit | Rewrites | Median | Largest | Target |
| --- | --- | --- | --- | --- | --- |
| 200 | changes no column width | 1 | 0.59 ms | 1.33 ms | under 5 ms |
| 200 | widens a column | 200 | 0.80 ms | 1.18 ms | under 25 ms |
| 1,000 | changes no column width | 1 | 2.73 ms | 3.67 ms | under 25 ms |
| 1,000 | widens a column | 1,000 | 5.29 ms | 6.89 ms | under 50 ms |

The whole `TextChanged` of one change, which adds the existing conceal pass of `view_buffer.lua`, took 0.2 to 1.1 ms more than the re-pad alone at the median (1.1 ms at 1,000 rows). The fallback in the risks (re-pad only the changed lines) is not needed.

Deviations from the plan, each low risk:

1. **The `InsertLeave` re-pad waits one event loop turn** (`vim.schedule`). A blockwise insert (`<C-v>`, then `c` or `I`) copies the typed text to the other rows after `InsertLeave`, by reading back the first row; a scratch run showed a re-pad inside `InsertLeave` made it copy the padding too. Scheduled, the copy finishes first and `:undojoin` still joins the re-pad: one `u` restored all rows.
2. **A view with no unsaved edits is never re-padded by the autocommand.** This makes UX1.4's "never sets the modified flag" hold by construction. The undo-state check (`seq_cur < seq_last`) runs only when a row needs new padding, because `undotree()` builds the whole tree.
3. **When `:undojoin` fails, the re-pad is skipped** and counted as `repad_skipped` in `ux_stats`, instead of being made an undo step of its own, which would make `u` undo the padding without the edit.
4. **An expansion whose rows widen a column re-pads the rows already shown**, in the same plugin edit (outside the undo history, modified flag kept). The plan expected passing `entry.widths` to be enough, which holds only while the new rows are no wider.
5. **A macro is re-padded once, after it ends**, because Neovim fires `TextChanged` only when no keys are waiting. One `u` then undoes the macro's last change and the re-pad together and lands on the state after the earlier changes, which was never re-padded. It stays misaligned until the next edit; undo itself is correct (`realign_spec` checks that two `u` restore the view). This is the plan's "misaligned without breaking undo" case.
6. **`ic` selects nothing on an empty last cell** (empty tags, where the line ends at `│`) and on an empty field value, because there is no character to select; `cic` there does nothing, and `A` appends as before. On every other empty cell `ic` selects its padding, as specified.
7. **The text objects are Lua callback mappings** that cancel the operator with `normal! <Esc>` on a sub-area or heading row. A `<Cmd>` mapping that selects nothing leaves the operator to act on the character under the cursor; the cancel prevents that, and `.` still repeats `cic`.
8. **Two more headless facts**, for section 4. `tests/nvim` specs set `vim.o.columns = 200` (`tests/support/views.lua`), and headless Neovim lays windows out to 200 columns while it draws an 80-column screen, so `screenstring()` reads wrapped garbage; one scratch run crashed with `double free or corruption`. The screen spec sets 80 columns and rebuilds the layout (`vsplit`, `only`) first. And `screen.rows` runs `:mode` before reading, because after enough messages `redraw!` alone leaves the screen scrolled. The Insert-mode drift check (UX1.3) snapshots the buffer in an `InsertLeave` autocommand, since `nvim_feedkeys` with `!`, which stays in Insert mode, ended the test run.

The manual checks above are still to run in the owner's editor.

### Phase 2: Colour, change markers and counts

**Delivers.**

- UX2.1 Highlight groups `AdoType`, `AdoState`, `AdoSeparator`, `AdoAreaMark`, `AdoHeading`, `AdoChanged`, `AdoNew`, `AdoCount`, each defined with `default = true` and linked to a standard group (`Type`, `Constant`, `NonText`, `Directory`, `Title`, `Changed`, `Added`, `Comment`). `Added` and `Changed` exist from Neovim 0.10. Groups are re-applied on `ColorScheme`.
- UX2.2 The type cell shows in its ADO type colour, and a dot `●` in the state's ADO colour sits before the state cell, as inline virtual text, on item rows and on the item view's `state:` line. One group per colour, `AdoColor_<hex>`, is made on demand. Without `termguicolors` the cells use `AdoType` and `AdoState` instead of hex colours.
- UX2.3 Separators, the sub-area mark `▸` and the heading mark `──` are dimmed, by syntax rules rather than extmarks, so they need no work per edit.
- UX2.4 The sign column shows `~` on a row whose fields differ from its snapshot and `+` on a new line or a row pasted from another view. No old value is shown on the line (Q5). Markers update with each re-pad and on `InsertLeave`.
- UX2.5 The window bar keeps the location and filters on the left and shows counts on the right, after `%=`: `3 sub-areas · 42 items · 2 edited · 1 removed` in the area view, and `children: open only · 2 edited` in the item view. "Removed" counts snapshot rows no longer in the buffer, which have no line for a sign.
- UX2.6 The type catalog carries the colours. They come from the `workitemtypes` call the session already makes once per project, so loading costs no extra call.
- UX2.7 The icons (`●`, `~`, `+`) come from `setup({ ui = { icons = {...} } })`, so the owner can swap in Nerd Font glyphs; each icon must be one column wide.

**Modules.**

- `nvim/az.lua`: `TYPES_PROJECTION` gains `color: color` per type and per state. Route check first: run the call by hand on `Example`, confirm every type and state has `color` (the spike saw them for `Bug`), and re-record `tests/fixtures/az/work_item_types.json`. The response is 8.5 KB today; the check records the new size.
- `core/types.lua`: `Catalog:type_color(type)` and `Catalog:state_color(type, state)`, each a hex string or nil. Seed colours in `tests/fixtures/seed.lua`.
- Create `core/row_changes.lua` with `changed(snapshot_row, current_row)`, which returns the changed fields by the rules the plan uses (text trimmed; tags compared as a set without regard to case). `core/plan.lua` calls it instead of its own comparison, so a `~` and a line in the save summary can never disagree.
- Create `nvim/highlights.lua`, `nvim/decorations.lua`, `syntax/adoarea.lua`, `syntax/adoitem.lua`.
- `nvim/view_buffer.lua`: `set_winbar` takes left and right parts, escapes `%` in each and joins them with `%=`. The views set `signcolumn=yes:1` on their windows; the owner's config already sets `signcolumn=yes`, so the owner's views lose no columns.
- `nvim/area_view.lua`, `nvim/item_view.lua`: the counts.

**Core stays with:** the colours per type and state, and which fields of a row changed. **Presentation keeps:** groups, extmarks, syntax, signs, the window bar.

**Core tests.** `types_spec`: colours read from the fixture, nil for a type or state without one. `row_changes_spec`: each field; tags `a; B` against `b;a` unchanged; whitespace only unchanged; a new row. A spec runs every edit scenario in `plan_spec` through both `row_changes` and the plan and asserts they name the same fields.

**Presentation tests.** `decorations_spec`: the colour group on a type cell from the fake catalog; `AdoType` when `termguicolors` is off; a dot on every item row and on `state:`; `~` after editing a title and none after `u`; `+` after pasting a row from another view and on a typed new line; groups present again after `:colorscheme`; the window bar text with `%` in an area name. `realign_spec` gains: separators still line up with dots present, and a `<C-v>` change over the state column still works with the dots in place.

**Manual checks.** In the owner's colour scheme (nightfox): type and state colours readable on the background; after `:colorscheme default` they are still readable; edit, paste and `dd` a row and watch `~`, `+` and the removed count; the window bar counts match the rows.

**Exit criteria.** Tests pass; the route check found a colour on every type and state of `Example`, or the catalog falls back to `AdoType`/`AdoState` for the ones without; on 1,000 rows, decorating every row takes under 25 ms in `make bench`. The 25 ms is a first guess from the spike's 22 to 23 ms render of 1,000 rows, which drew no colours or signs; revise it after the first bench run.

**Risks.**

- The dot is inline virtual text, so it shifts screen columns. It is the same width on every row, so alignment and `<C-v>` should be unaffected; this is reasoned, not tested, and the `realign_spec` cases above test it before the phase ends.
- Decorating all rows on each change is too slow at 1,000 rows. `make bench` detects it. The fallback is the method of csvview.nvim (spike section 3.1): a decoration provider (`nvim_set_decoration_provider`), which draws extmarks only for the lines on screen at each redraw.
- An ADO colour is unreadable on the owner's background (`b2b2b2` on a light theme, for example). The manual check detects it. The fallback is a per-colour override in `ui`, added only if a real case shows up.

#### Phase 2 as built (2026-10-13)

Built on branch `feat/navigator` as specified, with the deviations below. `make test` passes 476 tests (447 before the phase) in name order and with `ORDER=reverse` and `ORDER=shuffle`; the phase adds `row_changes_spec` (8), `decorations_spec` (16), three `types_spec` cases and two `realign_spec` cases.

Route check, 2026-10-13, read only: `az devops invoke --area wit --resource workitemtypes --route-parameters project=Example --api-version 7.1` with the extended projection (`color` per type and per state) returned 23 types in 1.7 s, and every type and every state has a colour, so no type of `Example` falls back to `AdoType` or `AdoState`. The response is 11,413 bytes, against 8,507 without colours. Colours are six hex digits without `#`, in either case (`CC293D`, `b2b2b2`); the catalog stores them in lower case. `tests/fixtures/az/work_item_types.json` is re-recorded; since the phase 1 recording ADO enabled the Epic type again (`isDisabled` is now false).

`make bench` (WSL2, Neovim 0.11.6, 40 runs per case). "TextChanged" now includes the decoration pass:

| Rows | Case | Median | Largest | TextChanged | Target |
| --- | --- | --- | --- | --- | --- |
| 200 | decorate every row | 1.42 ms | 1.74 ms | | none set |
| 200 | re-pad, no column width change | 0.87 ms | 1.34 ms | 2.17 ms | under 5 ms |
| 200 | re-pad, widens a column | 0.85 ms | 1.25 ms | 2.67 ms | under 25 ms |
| 1,000 | decorate every row | 6.67 ms | 7.99 ms | | under 25 ms |
| 1,000 | re-pad, no column width change | 3.08 ms | 4.42 ms | 10.45 ms | under 25 ms |
| 1,000 | re-pad, widens a column | 5.11 ms | 6.49 ms | 13.08 ms | under 50 ms |

The decoration provider fallback in the risks is not needed. The risk that the inline dot breaks alignment or `<C-v>` did not happen: `realign_spec` reads the drawn screen and finds every separator and every dot in the same screen column on every row, and a blockwise change over the state column works with the dots drawn.

The phase also fixes a test-isolation leak found in phase 1: a `tests/nvim/session_spec.lua` case set `open_categories = { "Proposed" }`, and `config.setup()` merges into the previous configuration, so every spec after it loaded views without in-progress rows. `config.reset()` returns to the defaults and every spec's setup calls it. `make test ORDER=reverse` and `ORDER=shuffle` (with `SEED=<n>` to repeat one) now run the spec files in another order to catch the next leak of this kind.

Deviations from the plan, each low risk:

1. **A view in every state loads its project's catalog once.** UX2.6 says the colours cost no extra call, which holds for open-state views, whose load needs the catalog anyway. A view with the state filter `all` loads no catalog, so its first decoration asks for it (one call per project per session, which phase 3's UX3.4 also needs) and colours the rows when it arrives; until then they use `AdoType` and `AdoState`. A failed load is not retried in that session.
2. **The item view's right side** shows `2 children · 1 linked`, then the edit counts, and the left keeps `children and links: open only (<leader>wt for all)`, instead of the plan's `children: open only · 2 edited`. The filter stays with the location on the left, as in the other views.
3. **The window bar also counts new rows** (`1 new`), beside `edited` and `removed`, so a typed or pasted line shows in the counts as well as in the sign column.
4. **What a sign means, exactly.** `core/row_changes.lua` marks a row `~` when the save summary has a line about it, which includes a value restated in another case (`to do` for `To Do`) that the summary lists under "No change"; a spec runs every column-edit scenario of `plan_spec` and `columns_spec` through both and checks this. `+` also marks the second of two lines with the same row ID in one view (`yyp`, a copy). A row moved within an item view from one section to another (children to Related, for example) keeps its row ID and its text, so it gets no sign, although the summary lists the link change; signs follow column edits, not relationships.
5. **Empty state cells get a dot too**, in `AdoState`, so every row has the same 2 columns of virtual text and stays aligned.
6. **`AdoAreaMark` covers the whole sub-area row** (`▸ name/`) and **`AdoHeading` the whole heading line**, not only the marks. The plan asks for the marks to be dimmed but links the groups to `Directory` and `Title`, which colour rather than dim; colouring the row reads as a directory listing does. A `│` inside a title is dimmed like a separator, since a syntax rule cannot tell them apart.
7. **Syntax files load without `:syntax on`.** With syntax on, setting `'syntax'` loads `syntax/adoarea.lua` or `syntax/adoitem.lua`; without it (the specs run with `-u NONE`), `view_buffer.lua` runs the file itself. The specs cover only the second path.
8. **An icon that is not one column wide is replaced by its default**, with one warning in `:messages`, rather than rejected at `setup()`.
9. **Decorations also go into `ux_stats`** (`decorate`, with the same 50 ms warning as the re-pad), and `bench` has no decoration target at 200 rows, since the plan sets one at 1,000 only.

Manual checks still to run in the owner's editor, in addition to the phase's list above:

- In nightfox, then after `:colorscheme default`: type colours and dots readable on the background; separators dimmed; sub-area rows and headings marked.
- With `:syntax on` (the owner's config), the separators, sub-area rows and headings are coloured; the specs check this only without it.
- Edit a title, paste a row from another view, type a new line, `dd` a row: `~`, `+` and the window bar's `edited`, `new` and `removed` counts match; `u` back to the loaded text clears them.
- `<C-v>` over three state cells with the dots drawn, then `cClosed<Esc>`: every row changes and the dots stay before the states.
- An area view with the state filter `all`: rows show plain `AdoType` colours for a moment, then ADO's.
- `setup({ ui = { icons = { state = "<glyph>" } } })` with a one-column Nerd Font glyph: the dot changes and the columns stay aligned.

### Phase 3: Pickers for type and state

**Delivers.**

- UX3.1 In Insert mode, `<C-Space>` in a type or state cell opens a menu at the cell's start with the valid values, through `complete()`. Type cells offer the row's project's `types` from `setup()`. State cells offer the states of the type written on that line now, or of the snapshot type when that name is not in the catalog; each item shows its state category, and its colour when the Neovim version supports `abbr_hlgroup` (feature-detected). The menu filters as the owner types; `<C-y>` accepts.
- UX3.2 In Normal mode `<leader>we` opens `vim.ui.select` with the values for the column under the cursor and writes the choice into that cell. In Visual mode it writes into that column on every selected row. For state, the list holds only the states every selected row's type has; when there are none it says which types share no state. The write is one undo step and the re-pad joins it, so it shows in the save summary like a typed edit and one `u` removes it.
- UX3.3 When a project has no `types` in `setup()`, the type menu does not open, and the command line shows the `setup()` entry to add, matching the save's rejection message (`docs/architecture.md`, "Column edits").
- UX3.4 When the row's catalog is not loaded yet (an area view with the state filter `all` does not need it), the menu loads it (1 call per project per session) and opens if the cursor is still in the same cell.
- UX3.5 Inside the views the plugin's own menu is the only one. When nvim-cmp is loaded, the views run `require("cmp").setup.buffer({ enabled = false })`, and they set `vim.b.completion = false`, which blink.cmp reads (blink.cmp unverified). `<C-x><C-u>` also opens the menu, through the buffer's `completefunc`. `<C-Space>` is mapped as `<C-@>` and `<Nul>` too, because many terminals send NUL for it.

**Modules.** Create `core/choices.lua`: `choices.for_cell(column, row, catalog, project_types)` returns `{ word, menu, color }` items, or nil with a reason. `core/types.lua`: `Catalog:state_entries(type)` with category and colour. Create `nvim/complete.lua`. Extend `nvim/cells.lua` with `write(buf, rows, column, value)`. `nvim/keymaps.lua`: the keys.

**Core stays with:** which values are valid for which cell. **Presentation keeps:** the menus, the mapping, the cell writes.

**Core tests.** `choices_spec`: states of the current type; fallback to the snapshot type; the intersection for several rows and the empty-intersection reason; the configured types of the row's project; a project without `types`.

**Presentation tests.** `complete_spec`: `<C-Space>` in a state cell fills `complete_info().items` with the type's states, started at the cell's start; in a type cell, the project's types; nothing outside type and state cells. `vim.ui.select` is replaced by a stub that picks: a Normal-mode write, a Visual write over 3 rows, one `u` restores all 3. A spec checks that the mapping calls `complete()` from a `<Cmd>` mapping, not an `expr` mapping, which the spike found fails.

**Manual checks**, in the owner's config, which has nvim-cmp with `<C-Space>` mapped and its menu opening while typing, dressing.nvim for `vim.ui.select`, and noice.nvim drawing the popup menu:

- `<C-Space>` in a state cell shows the plugin's menu, not nvim-cmp's, and no nvim-cmp menu appears while typing in a view.
- `<leader>we` on a type cell opens the dressing picker.
- Visual `<leader>we` over 5 rows sets their state; `:w` lists 5 state changes.
- nvim-cmp still works in a normal file afterwards.

**Exit criteria.** Tests pass and the manual checks behave as described.

**Risks.**

- nvim-cmp's own `<C-Space>` mapping wins in the views. nvim-cmp installs its Insert-mode keys when Insert mode starts, and whether `setup.buffer({ enabled = false })` makes them fall through to the plugin's mapping is unverified. The first manual check detects it. The fallback is `<C-x><C-u>`, which nvim-cmp does not map.
- The writes for several rows end up as several undo steps. The `u` spec detects it.

#### Phase 3 as built (2026-10-13)

Built on branch `feat/navigator` as specified, with the deviations below. `make test` passes 514 tests (476 before the phase) in name order and with `ORDER=reverse` and `ORDER=shuffle`; the phase adds `choices_spec` (13), `complete_spec` (16) and `pick_spec` (9). `make bench` still meets every target (1,000 rows: decorate 6.64 ms, re-pad 2.97 and 5.26 ms at the median).

**nvim-cmp and `<C-Space>`, checked in the owner's config and nvim-cmp's source.** The owner's config (`lua/plugins/nvim-cmp.lua` in the dotfiles) loads nvim-cmp on `InsertEnter` and maps `["<C-Space>"] = cmp.mapping.complete()` through `cmp.mapping.preset.insert`. nvim-cmp does not map keys at setup: on each `InsertEnter`, if `config.enabled()` is true for the buffer, `core:prepare()` calls `keymap.listen` for every mapping (`lua/cmp/core.lua`, `lua/cmp/utils/keymap.lua`). `listen` makes a buffer-local mapping when the buffer already has one for that key, wrapping the existing one as a fallback, and a global mapping otherwise. `mapping.complete()` calls its fallback only when `cmp.complete()` returns false, so if nvim-cmp were enabled in a view its wrapper would win over the view's `<C-Space>`. With `setup.buffer({ enabled = false })`, `prepare()` never runs in the view, nvim-cmp's mapping stays global, and the view's buffer-local mapping wins, as buffer-local mappings do over global ones. A scratch run with the owner's installed nvim-cmp (commit `cf22c9e`) confirmed both: after Insert mode in a normal buffer, nvim-cmp's `<C-Space>` was global; in a view, `<C-Space>` ran the plugin's mapping and opened its 4 states, and nvim-cmp reported itself disabled there and enabled in the normal buffer. Forcing `prepare()` in a view with nvim-cmp enabled replaced the view's mapping with nvim-cmp's buffer-local wrapper. Because the owner's config loads nvim-cmp on `InsertEnter`, nvim-cmp is not loaded when a view opens, so the views turn it off again on `InsertEnter`; nvim-cmp's own `InsertEnter` handler waits one event loop turn, so it sees the buffer disabled. The plan's first risk (nvim-cmp's mapping wins) holds only if that order fails; the manual check below tests it.

Deviations from the plan, each low risk:

1. **`core/choices.lua` takes several cells.** `for_cells(cells, lookup)` covers the Visual case and rows of several projects (a query list); `for_cell(column, row, catalog, project_types)` is the one-cell form the plan names. The save's messages for a project without `types` (R8.6) and for a new line with a state (R5.18) moved into `choices.lua`, and `core/plan.lua` uses them, so the menu and the save cannot word a refusal differently.
2. **The state list follows a typed type only when the save would change the row to it**: the typed type must be one of the project's configured `types` and be in the catalog. Otherwise the save keeps the type ("no change") and checks the state against the loaded type, so the list does too. The plan said "or of the snapshot type when that name is not in the catalog", which would offer states the save refuses for a type that is in the catalog but not configured.
3. **The type list leaves out configured types the catalog lacks**, whose states the save cannot check (R5.22), and marks a type that lacks the row's state with `no state <state>`, because a type change keeps the state unless the same save sets one the new type has.
4. **A new line's state cell offers nothing** and shows the save's R5.18 message.
5. **One case where an offered value can still be refused:** a row pasted from another view. Whether it becomes a copy, which may not change its state or type (R5.6), or a move is decided at save time, by what happens to the original. The list offers the values for the original's type, and the save explains a refusal.
6. **`<C-Space>` replaces the whole cell.** It moves the cursor to the end of the cell's text before calling `complete()`. A check while building showed that `complete()` lists every item it is given, whatever text the cell holds, so the plugin filters: items starting with the cell's text, ignoring case, unless that text is already a whole value or matches none, when every value shows so another can be picked. `<C-x><C-u>` replaces from the cell's start to the cursor, as `completefunc` does.
7. **`<Nul>` is the same key as `<C-@>` in Neovim**, so the views map `<C-Space>` and `<C-@>`; the spec checks that `<Nul>` finds the mapping.
8. **Colours in the menu** use `abbr_hlgroup` when `has("nvim-0.11")`, and only with `termguicolors` (the `AdoColor_<hex>` groups of phase 2). `complete_info()` does not report `abbr_hlgroup`, so the spec checks the items passed to `complete()`.
9. **An empty `state:` or `type:` line** gets the spaces a loaded line has between label and value before the value, from both the menu and `<leader>we`.
10. **`<C-x><C-u>` cannot wait for a catalog**, so when the catalog is not loaded it cancels and opens the menu with `complete()` once the catalog arrives, under the same "still in the cell" check as `<C-Space>`. Only the `<C-Space>` path has a spec.
11. **Visual `<leader>we`** takes the column from the cell under the cursor, skips selected lines that are not item rows (headings, sub-area rows, the item view's title and field lines), and acts on one line when the cursor is on a field line. If the view changes while the list is open (a reload, for example), nothing is written and a warning says so. After a write the command line says what was set, for example `[ado] state Done on 3 rows`.
12. **Another headless fact, for section 4.** A popup menu drawn outside the 80 by 24 screen that headless Neovim draws crashed one run (segmentation fault, with the spec files in reverse order). `complete_spec` sets 80 columns and 24 lines and rebuilds the layout first, as the screen spec does.

Manual checks still to run in the owner's editor, in addition to the phase's list above:

- In a fresh Neovim, open a view and make the first Insert mode of the session there (so nvim-cmp loads inside the view): `<C-Space>` in a state cell shows the plugin's menu, and no nvim-cmp menu appears while typing.
- `<C-Space>` in Windows Terminal over WSL reaches the plugin; if it does not, `<C-x><C-u>` does, and the terminal's key setting for `<C-Space>` is the thing to report.
- The state menu shows ADO's colours with noice.nvim drawing it.
- Type `Bug` over a Task's type, then `<C-Space>` in its state cell: the Bug's states show.
- Visual `<leader>we` over rows of two types that share no state: the message names both types and no picker opens.
- `<leader>we` on a title cell: the message explains what the key does.

### Phase 4: People search for the assignee

The owner's answer to Q3: picking a person inserts their email, and the search still works by name.

**Delivers.**

- UX6.1 In Insert mode, `<C-Space>` in an assignee cell (item rows and the `assignee:` line) opens the menu at once with local candidates: the assignees on the loaded rows of every open view (their display name and email are in the registry rows) and the people picked earlier in the session, most recent first.
- UX6.2 Each item shows the display name, with the email beside it, and inserts the email. Matching ignores case and accepts the start of the display name, of any word in it, or of the email, so `doe` finds `Janet Doe`. Items carry `equal = 1`, which, by `:help complete-items`, stops Neovim from dropping an item whose inserted text (the email) does not start with what was typed (the name). This is read from the documentation and is the first thing the phase checks.
- UX6.3 While the menu is open, each key typed in the cell narrows the local candidates at once. 200 ms after the last key, with at least 2 characters typed, the plugin searches ADO through the existing `resolve_identity` operation and merges the answer into the menu with `complete()`. The answer is shown only if Neovim is still in Insert mode in the same cell of the same row and the typed text still starts with what was searched.
- UX6.4 Answers are cached per session by lower-case prefix. While a search runs, a cached answer for a shorter prefix is filtered and shown. ADO returns at most 10 people a call (`IDENTITY_MAX` in `nvim/az.lua`), so a filtered shorter prefix may miss people; the longer search still runs.
- UX6.5 The save needs no change: `plan.prepare` already resolves an email to exactly one identity (R5.19), with one `resolve_identity` call as today.
- UX6.6 In Normal and Visual mode, `<leader>we` on an assignee cell asks for a name with `vim.ui.input`, searches, offers the matches with `vim.ui.select` (`Name <email>`, plus "unassign"), and writes the email into the cell on every selected row.
- UX6.7 Each search reports its prefix, result count and duration on the progress line (`[ado] people 'jan': 3 found in 0.31 s`), and `ux_stats` records them. A failed search is written to `:messages` once per Insert session instead of once per key: the people search passes a `quiet` flag that the error notifier in `nvim/session.lua` honours for that call only.

**Modules.** Create `core/people.lua`: `People.new(session)`; `:matches(text, candidates)`; `:search(text, cb)` with the prefix cache and one call in flight per prefix; `:picked(identity)`; ranking (picked earlier, then loaded rows, then ADO answers; one entry per email). `core/session.lua`: `Session:people()`, one per session. `nvim/complete.lua`: the people source, the 200 ms timer, the guard. `nvim/session.lua`: the `quiet` flag.

**Core stays with:** candidates, matching, cache, ranking, and which identity the menu offers. **Presentation keeps:** the timer, the Insert-mode guard, the menu.

**Core tests.** `people_spec` against the fake transport in deferred mode: a cached prefix makes 0 calls; a shorter cached prefix is filtered while the longer call runs; two people with the same name both appear, told apart by email; a person who is both local and found by ADO appears once; the seed's two identities matching "Alex" (plan 0001 section 4.2); a late answer to an older prefix is ignored.

**Presentation tests.** `people_complete_spec`: local items appear at once; after the debounce (the spec sets it to 0 ms and waits with `vim.wait`) the ADO answer is merged; the menu keeps items whose email does not start with the typed name; an answer arriving after `<Esc>` or on another line changes nothing; accepting inserts the email and `:w` resolves it with no rejection; one failed search writes one message.

**Manual checks** on real ADO, with the write guard on (`setup({ write_guard = ... })`, which refuses writes outside the test area; `docs/architecture.md`, "Write guard"): type the first 3 letters of a colleague's first name, then of a surname; pick a person who shares a first name with another; `:w` shows `Name <email>` in the summary; the progress line shows search times (the spike measured 0.28 to 0.44 s per call, 4 samples).

**Exit criteria.** Tests pass; on real ADO a search by first name and one by surname each find the expected person; no save rejects an assignee picked from the menu.

**Risks.**

- `equal = 1` does not keep the items. The first spec detects it. The fallback starts the completion one column further left, with each item's `word` set to the display name, and rewrites the cell to the email on `CompleteDone`, joined with `:undojoin`.
- The email makes the assignee column wide until the next reload, when the row shows the display name again. Phase 5 cuts it to the column's width.
- noice.nvim draws the popup menu, and a menu refreshed from a callback may draw differently there. The manual check in the owner's config detects it.

#### Phase 4 as built (2026-10-15)

Built on branch `feat/navigator` as specified, with the deviations below. `make test` passes 542 tests (514 before the phase) in name order and with `ORDER=reverse` and `ORDER=shuffle`; the phase adds `people_spec` (11) and `people_complete_spec` (17). `make bench` still meets every target (1,000 rows: decorate 6.37 ms, re-pad 3.14 and 5.31 ms at the median).

**`equal = 1` works**, so the fallback in the risks is not needed. A headless check on 0.11.6 typed `J`, `a`, `n` after `complete()` offered two items whose emails start with `j`: without `equal` Neovim closed the menu at the first key, with `equal = 1` both items stayed. A run in tmux with the fake transport answering after 300 ms showed the whole flow drawn: typing `al` narrowed the menu to one local person, ADO's answer added a second about 0.5 s later, a space and `j` narrowed it again, and `<C-n><C-y>` inserted the email.

**Real latency, read only** (2026-10-15, organisation `example-org`): 12 searches through the plugin's `az` transport (`core/people.lua` over `nvim/az.lua`), in two runs of 6 prefixes of 2 to 4 characters, took 0.28 to 1.26 s, median 0.71 s. The first run took 0.69 to 1.26 s and the second 0.28 to 0.85 s. Three `az rest` calls made directly with the same request took 0.27 to 0.71 s, so the plugin adds no measurable time; the spike's 0.28 to 0.44 s (4 samples) was a fast moment. Every 2-character prefix returned 10 people, ADO's cap (`IDENTITY_MAX`); 3 and 4 characters returned 1 to 9. A repeated prefix answered from the cache with 0 calls. With the 200 ms debounce, ADO's people arrive 0.5 to 1.5 s after the last key.

Deviations from the plan, each low risk:

1. **The people menu has its own module**, `nvim/people.lua`; `nvim/complete.lua` sends an assignee cell to it. The plan put it in `complete.lua`.
2. **The views set a buffer-local `'completeopt'`**: the global value plus `menu`, `menuone` and `noselect` (unless it has `noinsert`). Neovim's default (`menu,popup`) inserts the first item when `complete()` is called, which replaced the name typed with an email in a check. This applies to the type and state menus too, which now insert nothing until a value is picked. `'completeopt'` is buffer-local on 0.11.6 (checked); where it is not (0.10 was not checked), the plugin leaves it alone and the README says to add `noselect`.
3. **The plugin narrows the menu itself.** `equal = 1` turns Neovim's own filter off, so each key refreshes the menu with `complete()` on `TextChangedI` and `TextChangedP`. A space closes Neovim's menu; the `TextChangedI` after it reopens it, so names with spaces work. While an item is selected with `<C-n>` (its email is then in the buffer), neither a key nor a late answer refreshes the menu, which would drop the selection.
4. **A late answer is marked, not dropped, in the core.** `People:search` calls back with `info.stale = true` when a later search started; the menu ignores such an answer, but its time and count still reach the progress line and `ux_stats`, as UX6.7 asks for every search.
5. **Which people must match the text typed.** People on loaded rows, people picked earlier and cached answers to shorter prefixes are filtered by the plugin's rule (start of the name, of a word in it, or of the email). ADO's answer to the text itself is shown as ADO matched it, in case its matching differs.
6. **On `<C-Space>`, a cell holding a whole name or email, or text that matches no one, offers everyone**, as the type and state menus do; a whole name or email is not searched. Text that matches no local person is still searched.
7. **`<C-x><C-u>` opens the people menu one event loop turn later**, because a `'completefunc'` cannot refresh its menu.
8. **`<leader>we` with an empty name** offers the local people and "unassign" without a search. After a write the command line says what was set, for example `[ado] assignee Alex Jones <alex.jones@example.com> on 1 row`.
9. **The `quiet` flag is part of the transport contract**: any params may carry `quiet = true`, which transports ignore (`core/transport.lua`); only the people menu sets it.
10. **"Open views" means the rows the registry holds**, which includes view buffers that are hidden but not wiped.
11. **Two more headless facts, for section 4.** `TextChangedI` and `TextChangedP` do not fire after `nvim_feedkeys` either, so the spec fires `TextChangedP` from a mapped key while Insert mode lasts, and lets the debounce timer run with `vim.wait` inside another mapped key. `<C-o>` fires `InsertLeave` and `InsertEnter`, which ends the people menu, and `<Down>` with the menu open moves the selection, so the spec moves the cursor to another line with `nvim_win_set_cursor` from a mapped key.

Manual checks still to run in the owner's editor, in addition to the phase's list above:

- With nvim-cmp and noice.nvim loaded: `<C-Space>` in an assignee cell shows the plugin's menu, typing narrows it with no flicker, and ADO's people are added while the menu is open.
- Type a first name with a space and a surname initial (`alex j`): the menu stays open across the space.
- `<C-n>` to a person, wait for a search to finish: the selection stays.
- Unplug the network (or log out of `az`), type in an assignee cell: one error in `:messages` per Insert session, not one per pause.
- `<leader>we` on an assignee cell: dressing.nvim asks for a name, then lists `Name <email>` and "unassign"; Visual `<leader>we` over 3 rows, then `:w` lists 3 assignee changes.
- `:lua require("ado").ux_stats()` shows `people_search` runs with their times.

### Phase 5: Fit to the window

**Why the spike's mechanism changes.** The spike proposed keeping long cells whole in the buffer and hiding their tail with a conceal extmark. Neovim scrolls a `nowrap` window sideways by the cursor's text column, counting concealed text, and wraps a `wrap` window by the same count. `spike/ux/scroll_probe.lua` shows both on 0.11.6 in a 40-column window:

| Case | Leftcol | Result |
| --- | --- | --- |
| 60-character cell cut to 10, cursor before the cut | 0 | `ttttttttt… │ x`, fits |
| Same cell, cursor on the next cell | 43 | the window scrolls; the next row is drawn from column 43 |
| 60 concealed spaces of padding, cursor after them | 52 | the window scrolls |
| Same line with `wrap` on | 0 | the 13 drawn characters take 2 screen rows |

Resetting `leftcol` to 0 with `winrestview` does not hold: Neovim scrolls back on the next redraw (checked). This matches the spike's own finding that at 60 columns "going to the end of a long row scrolled every row sideways". So any row whose buffer text is wider than the text width breaks the table as soon as the cursor goes right of its hidden part. Two options follow; PQ1 asks the owner to choose. Either way the spike's R5 (show the cursor's cell in full and hide the cells to its right) no longer fits: under T the text typed is real and always visible, so there is nothing to reveal, and UX5 becomes the rule that keeps a cut cell's hidden part through edits.

- **Option T (recommended): cut the text itself.** The buffer holds the cut text, ending in a real `…`; the registry keeps the full value. Rows are real text no wider than the text width, so nothing scrolls, `<C-v>` works on every row, and every Vim command sees what is shown. The cost is a new rule in the save path, described below.
- **Option C: the spike's design.** Conceal the tails and accept that moving to the assignee or tags of a row with a cut title scrolls the window and misaligns every row. The title's padding then depends on the window width, so a resize (opening the detail split, for example) would rewrite the buffer, which adds an undo step and sets the modified flag. No change to the save.

The rest of this section describes option T. If the owner picks C, 5b keeps UX4.1, UX4.2 (the `…` drawn by conceal instead of text), UX4.4 and UX4.5, implements the spike's R5 as written (reveal the cursor's cell, hide the cells to its right), drops UX5.1 to UX5.4 and the plan change, and re-pads on resize as an undo step of its own.

#### Phase 5a: Prototype (no answer needed)

A throwaway `spike/ux/fit_proto.lua`, built on `realign_proto.lua`, run in tmux at 100 and 60 columns as the spike did. It answers, with a screen capture for each:

1. Rows fit at 100 and 60 columns, and the cursor reaches every cell with no sideways scroll, with the real concealed row ID prefix and the inline state dots present (both count towards the scroll, by the finding above).
2. An edit in the visible part of a cut title (`x`, `cw`, `r`, Insert mode) keeps its hidden part, by the restore rule below.
3. Insert mode in a cut cell. The plan's rule (UX5.1) is that the owner types into the cut text and, on `<Esc>`, the restore rule keeps the tail and the cell is cut again, in one undo step. The prototype also tries expanding the cell to its full text when Insert mode starts (one extra undo step); if that reads better, the owner is told and UX5.1 changes before 5b starts.
4. `u` and `<C-r>` across an edit of a cut cell return the right full value each time.
5. The type cell as one letter with indented child rows: `  T` lines up under `B`.
6. Timing of a full layout at 200 and 1,000 rows.

If 5a shows option T cannot meet points 1, 2 or 4, phase 5b does not start, and the plan comes back to the owner with what was found.

#### Phase 5b: Build (after PQ1)

**Delivers.**

- UX4.1 Column widths come from the text width (Q2). Width budgets: type 10, state 10 plus the 2-column dot, assignee 14, tags 14; a column whose widest cell is narrower takes that width. The title gets the rest. The concealed row ID prefix (`/<row id> `, 4 to 8 columns for row IDs up to 6 digits) still counts towards scrolling, so the budget is the text width minus the widest prefix in the buffer. With the separators the cells take 62 columns besides the title, so, by text width minus prefix:

  | Text width | Layout | Title width |
  | --- | --- | --- |
  | 82 and wider | all columns | text width − 62, at least 20 |
  | 65 to 81 | tags hidden on rows (shown in the float) | text width − 45 |
  | 56 to 64 | as above, type shown as one letter | text width − 36 |
  | 50 to 55 | as above, assignee cut to 8 | text width − 30 |
  | under 50 | as above; the title stays at 20 and rows run past the window | 20 |

  A 100-column window with `signcolumn=yes:1`, `number` off and `foldcolumn=0` has a text width of 98; with a 6-column prefix (`/1234 `) the title gets 30 columns. The budgets are starting values from the spike's mockups, to tune in use.
- UX4.2 A cell longer than its column is cut to the column's width and ends in `…`, in the buffer text. The type letter is the first letter of the type name's last word (`User Story` is `S`), overridable with `setup({ ui = { type_letters = { ["Test Case"] = "C" } } })`; two types may share a letter, and the type colour tells them apart.
- UX4.3 The layout follows the window: on `WinResized`, `VimResized` and `BufWinEnter`, an unmodified view is rendered again for the new text width, without an undo step, as a load is. A view with unsaved edits keeps its layout, and its window bar says `fits the window after :w or <leader>wr`, because rewriting it would add an undo step between the owner's edits. A buffer in two windows is laid out for the narrower one.
- UX5.1 An edit inside the visible part of a cut cell keeps the hidden part, in Normal and Insert mode alike. When the edit ends (the next `TextChanged`, or `<Esc>`), the full value is restored by the rule below and the cell is cut again for display, in the same undo step as the edit. While Insert mode lasts, the edited line drifts as in UX1.3.
- UX5.2 `<leader>wx` shows the cell under the cursor in full (on every selected row in Visual mode), as an ordinary undoable change. A cell shown in full is not cut again until the next render, so edits to it are plain edits of the full value.
- UX5.3 `cic`, the pickers of phases 3 and 4, and `<leader>we` replace the whole cell. The written text becomes the cell's full value, stored with its cut form, and the cell is cut for display like any other; the float shows the full value.
- UX5.4 The save never writes a cut value. A cell whose full value cannot be restored rejects the save with its row and the fix: `row 7: the title was cut to fit the window and the … was edited; undo the edit, or press <leader>wx on the cell and edit the full title`.
- UX4.4 (Q4) When the cursor rests 300 ms in Normal mode on a cut cell, a letter-form type or a row with hidden tags, a float beside the cursor shows the full row: `#id`, type, state, title, `Name <email>`, tags, area. It does not take focus, and it closes on `CursorMoved`, `InsertEnter`, `BufLeave` and `WinScrolled`. The timer starts on `CursorMoved` in the view, not `CursorHold`, which waits `'updatetime'` (4,000 ms by default, and global). The float uses `'winborder'` when it is set (0.11) and `rounded` otherwise, like the save summary.
- UX4.5 In the item view, field values and the item's own title line are cut at the text width the same way.

**The restore rule.** A cut cell's text is a head of the full value followed by `…`. When the text changes and the `…` and everything after it are unchanged, the edit lies in the head, so the new full value is the new head followed by the hidden part of the old full value. Any other change to a cut cell (the `…` deleted, text typed after it) cannot be restored, and the cell is marked ambiguous. `table_layout.restore(full, shown_before, shown_now)` returns the new full value or nil. The registry stores, per row ID and column, each shown text it has seen with its full value. Lookups go by the text now in the buffer, so after `u` or `<C-r>` the text finds the full value it had at that point, with no state to rewind. A new line (no row ID) is never cut, because there is no stored full value to keep its hidden part.

**Modules.** `core/table_layout.lua` gains `budget(text_width, natural_widths, opts)` (layout and widths from the table above), `cut(text, width, measure)`, `letter(type, overrides)` and `restore(...)`. Create `core/row_info.lua`: a row as labelled values for the float. `core/plan.lua`: one new rejection for a row whose view record marks a cell ambiguous; otherwise the plan sees full values only, because `view_buffer.record` replaces each cut cell with its full value before planning. `nvim/registry.lua`: the shown-to-full map. `nvim/decorations.lua`, `nvim/realign.lua` (cut again after a restore), create `nvim/hover.lua`, `nvim/view_buffer.lua` (resize), `nvim/keymaps.lua` (`<leader>wx`), `config.lua` (`ui.type_letters`). `nvim/lines.lua`: render through `budget` and `cut`, and parse rows with tags hidden (one separator fewer), using the buffer's current layout.

**Core stays with:** the layout for a text width, cutting, letters, the restore rule, the hover content, the ambiguous-cell rejection. **Presentation keeps:** the window width, resize events, the shown-to-full map, the float and its timer.

**Core tests.** `table_layout_spec`: the layout at text widths 98, 82, 81, 65, 64, 56, 55, 50 and 49 (each boundary of the table); `cut` with wide characters, never splitting one; `restore` for a deletion, an insertion and a replacement in the head, for edits touching the `…` (nil), and for a sequence of random head edits whose restored value always equals the same edits applied to the full value; letters and overrides. `plan_spec`: a record with an ambiguous cell rejects with UX5.4's message and makes 0 writes; a cut title left unchanged plans nothing; a restored edit plans the full new title. `row_info_spec`: the float's lines for an item with and without an assignee and tags.

**Presentation tests.** `fit_spec` in splits of 40, 60 and 78 columns: rows fit (read with `screen.rows`); `$` on every row leaves `leftcol` at 0; `x` in a cut title then `:w` plans the full title with one letter removed; `u` and `<C-r>` across it; deleting the `…` then `:w` rejects; resizing an unmodified view re-renders it with the modified flag off and no undo step; resizing a modified view leaves the text alone; a row pasted from a view with another layout is rendered into this one. `hover_spec`: the float opens after the delay only on a cut cell, closes on `CursorMoved`, and never takes focus.

**Manual checks** at 100 and 60 columns, and while resizing a terminal pane: browse a real area with long titles; `cw` on the first word of a cut title, then `:w` shows the full new title in the summary; the float shows assignee emails; open the detail split and see the area view re-fit; with unsaved edits the window bar says why it did not.

**Exit criteria.** Tests pass. On a real area view at 100 and 60 columns no row runs past the window and the cursor reaches every cell without scrolling. In `make bench` a full layout of 1,000 rows takes under 50 ms. A week of the owner's use with no save writing a cut title.

**Risks.**

- A hole in the restore rule lets a cut value reach ADO, losing the end of a title or some tags. Detected early by the random-edit spec in the sandbox, and, as a second line, by the save summary, which shows every changed title in full before `y`. Because this can lose data, it is the reason PQ1 asks the owner.
- The restore map grows with every shown text. It holds only cells that were cut and then edited, and is cleared on reload; `ux_stats` reports its size.
- A row pasted from a view laid out for another width is parsed with the wrong column set. `fit_spec` covers it: the paste is parsed by its origin view's layout, found through its row ID, and rendered into the current layout on the next re-pad.

#### Phase 5 as built (2026-10-15)

Built on branch `feat/navigator` as option T, with the deviations below. `make test` passes 589 tests (542 before the phase) in name order and with `ORDER=reverse` and `ORDER=shuffle`; the phase adds `tests/core/fit_spec.lua` (8), `row_info_spec` (3), nine `table_layout_spec` cases, three `plan_spec` cases, `tests/nvim/fit_spec.lua` (20) and `hover_spec` (4). `make test ONLY=<text>` now runs only the spec files whose path holds the text.

**Phase 5a, what the prototype found.** The prototype was a headless probe (`nvim --headless -u NONE -l`), run in the session's scratch space and not committed, because this phase's work was limited to `feat/navigator`; the built plugin was then checked in tmux at 100 and 60 columns with the fake transport. Against the plan's six questions:

1. Rows fit, and the cursor reaches every cell with no sideways scroll, with the concealed row ID prefix and the inline dot present. A row whose prefix, dot and text take exactly the text width did not scroll on any cell or on `$`, but `A` at its end scrolled the window by 1 column, because the cursor in Insert mode sits after the last character. With one column left free, nothing scrolled (`leftcol` 0 in all cases). In tmux, `5G$` on the widest row at 100 and at 60 columns left the view unscrolled.
2. An edit in the visible part of a cut title keeps its hidden part: `x`, `iMust <Esc>` and a blockwise change in tmux and in `fit_spec`.
3. Insert mode in a cut cell works as UX5.1 says: the line drifts while typing and is cut again on `<Esc>`, in one undo step. Expanding the cell to its full text on `InsertEnter` was not tried: it would be a buffer change of its own at `InsertEnter`, an extra undo step that also breaks `.` repeat, and the plan's rule read well in tmux, so UX5.1 is unchanged.
4. `u` and `<C-r>` across edits of a cut title return the right full value each time (`fit_spec`, 4 states each way). The restore needs the cell's text before the edit, which led to deviation 5.
5. A one-letter type with indented child rows lines up: an expanded child shows `  T` under its parent's `T`, separators aligned.
6. A full layout takes 6.50 ms at 1,000 rows at the median (table below).

So option T met points 1, 2 and 4, and 5b went ahead.

`make bench` (WSL2, Neovim 0.11.6, 40 runs per case). The bench views are now laid out as a load does, in the 80-column headless window, so their titles are cut; "full layout" is the whole render of a load or a resize:

| Rows | Case | Rewrites | Median | Largest | TextChanged | Target |
| --- | --- | --- | --- | --- | --- | --- |
| 200 | full layout | | 1.36 ms | 1.98 ms | | none set |
| 200 | decorate every row | | 1.78 ms | 2.70 ms | | none set |
| 200 | re-pad, no column width change | 1 | 1.81 ms | 4.10 ms | 3.83 ms | under 5 ms |
| 200 | re-pad, widens a column | 200 | 2.30 ms | 4.95 ms | 4.54 ms | under 25 ms |
| 1,000 | full layout | | 6.50 ms | 17.51 ms | | under 50 ms |
| 1,000 | decorate every row | | 7.83 ms | 9.99 ms | | under 25 ms |
| 1,000 | re-pad, no column width change | 1 | 9.43 ms | 13.62 ms | 18.80 ms | under 25 ms |
| 1,000 | re-pad, widens a column | 1,000 | 13.29 ms | 15.87 ms | 21.79 ms | under 50 ms |

Every target is met. The re-pad at 1,000 rows is about 3 times phase 4's (3.14 ms at the median), because each pass now looks up every cell's value and works out the layout; the largest "no width change" case at 200 rows, 4.10 ms, is the closest to its target. A widened column now rewrites every row, because the title column gives up the width and each title is cut again.

**How the two guards are met.** Guard 1, fail closed: `core/fit.lua` gives a cell with a shown map no value for any text the map does not know, and gives none either to an edit that deleted the `…`, typed after it, or was made from an undo state the re-pad cannot trace (deviation 5). `view_buffer.record` names such cells in `ambiguous`, and `core/plan.lua` rejects the row (rule UX5.4) and drops the cell from the edits and the assignee lookups, so a rejected save makes no call. Three checks with a broken guard, each restored from a snapshot copy: the plan without the rejection failed 4 specs; a lookup that took an unknown text as its value failed 5; a snapshot always trusted failed the undo-state spec, which builds a case where the wrong "before" text would drop a letter from the hidden part of a title. Guard 2: the summary already printed title changes whole; `fit_spec` checks the old and new titles in full for an `x`, `cic`, `<leader>wx` and the item view's own title, and tmux showed the summary float wrap a full title at 60 columns.

Deviations from the plan, each low risk. Those marked **(changes earlier behaviour)** alter what phases 1 to 4 built:

1. **Collapsed tags keep their separator and show `…`** (an empty tags cell shows nothing), instead of being dropped with one separator fewer. Every row then parses by the one rule of phase 1 in every layout, so a row pasted between views of different widths needs no "origin layout", and a tag edit can never be dropped by a layout change. The cost is 4 columns, so the steps of UX4.1 start 4 columns wider: tags collapse below 82, letters below 69, the short assignee below 60, and below 54 the title stays at 20 (text width minus prefix and the free column of deviation 2). `table_layout_spec` checks each boundary.
2. **One column stays free** for the cursor after the last character in Insert mode (5a, point 1), so the title is 1 column narrower than the plan's table.
3. **The layout is chosen by the cells' widths, and room the title does not need goes back to the cut columns.** With room to spare nothing is cut: the plan's budgets cap a column only when the window is too narrow for every cell. In a wide window an assignee or tags column keeps its full width. **(changes earlier behaviour)** In a narrow window, columns are no longer as wide as their widest cell (phase 1); the email phase 4 inserts is cut to the assignee column, as phase 4's risks foresaw.
4. **The rules live in a new core module, `core/fit.lua`** (lookup, restore after an edit, the record of shown texts), beside `table_layout`'s `budget`, `cut`, `letter` and `restore`. `nvim/registry.lua` is unchanged: `nvim/fit.lua` keeps each cell's shown map on its registry entry, so the maps go when a reload releases the entries.
5. **The restore needs the text before the edit, and fails closed without it.** Lookups go by the text in the buffer, as planned, but restoring an edited cut text needs the text it was edited from, because the hidden part depends on where the cell was last cut. The re-pad keeps a snapshot of every cell and the undo state number (`changenr()`); it is trusted only when that state is on the path from the root of the undo tree to the newest change. A `u` whose `TextChanged` never fired, followed by an edit of a cut cell, leaves the cell with no value, and the save rejects it.
6. **Every edited cell gets a shown map, not only cut ones**, seeded with its loaded value, so `u` back to any earlier text of a cell finds its value once the cell has been cut. The plan expected the map to hold only cells that were cut and then edited; it holds cells that were cut or edited. `require("ado").ux_stats()` prints its size.
7. **A value whose cut text already stands for another value is shown in full**, since one text with two values would make `u` find the wrong one. It happens only after a whole-cell replacement that keeps the head, such as `cic` to a title starting with the same words.
8. **A type typed over its letter is that type.** The save checks types against the project's `types`, so the type column takes unknown text as the value instead of rejecting it.
9. **Text that reads as a cut of the loaded value**, a head of it followed by `…`, in a cell with no map, has no value: a cut text whose map was lost can never pass for a new title.
10. **`<leader>wx` on a cell with no value shows the value it was loaded with**, with a warning, since there is no full value to show; `u` returns to the edit.
11. **The rejection message** uses the label every other rejection uses: `#103 (line 3) in <view>: the title was cut to fit the window and the … was edited, so its full text is not known; undo the edit, or press <leader>wx on the cell and edit the full title`.
12. **The float also opens on the item view's own title line and its field values** when they are cut, showing the value; it sits above the cursor when the rows below cannot hold it; its delay is `require("ado.nvim.hover").delay`, not a `setup()` option.
13. **A resize rewrites only the lines that change, with the same row IDs**, so a row yanked before a resize still pastes and saves, and resets the window's sideways scroll, which tmux showed was left over from before the rows fitted. **(changes earlier behaviour)** Like a load, the rewrite clears the undo history of the unmodified view, so a redo left after `u` back to the loaded text is lost on a resize.
14. **An expansion lays out its new rows alone** (`fit.render_more`) and the re-pad of `insert_lines` fits all rows together; `item_view.lua` no longer keeps `entry.widths`.
15. **`cells.write` can write the item view's own title**, for `<leader>wx`; the pickers never call it for that line.
16. **Two more headless facts, for section 4.** `vim.cmd("undo")` in a spec fires no `TextChanged`, which `fit_spec` uses to build an untrusted undo state; and `CursorMoved` must be fired by the spec, as `TextChanged` is.

Manual checks still to run in the owner's editor, in addition to the phase's list above:

- At 100 and 60 columns on a real area with long titles: `$`, `w` and `f│` along every row never scroll the view; the float shows assignee emails.
- `cw` on the first word of a cut title, then `:w`: the summary shows the whole old and new title. `x` on the `…`, then `:w`: the save is rejected with the row named; `u`, then `:w` again, plans nothing.
- Type into the middle of a cut title in Insert mode, `<Esc>`: the end of the title is kept; one `u` restores the row.
- Open and close the detail split: the area view re-fits; edit a row first and the window bar says `fits the window after :w or <leader>wr`.
- `dd` a row with a cut title in the area view, `p` it among an item view's children in a window of another width, `:w`: the summary lists the parent change and no title change.
- With `'number'` on, or `'winborder'` set (0.11), the rows still fit and the float uses the border.
- A week of use with no save writing a cut title (the plan's exit criterion).

#### Addendum: visible work item IDs (2026-10-19)

The owner asked for "work item IDs as columns in the nav views and as the first field in the work item details; these are important for me to be able to copy paste easily". Built on branch `feat/navigator`. This changes the column model of phases 1 and 5:

1. **Every row view starts with an id column**: the area view, "my work items", and the item buffer's parent, child and link rows. It shows the plain number, padded like the other columns, so `yic` and `yiw` yank just the number. The concealed row ID prefix stays the row's identity; the id column is display only. A row is now `<id> │ <type> │ <state> │ <title> │ <assignee> │ <tags>`, parsed by the same rule with one more separator before the title (`core/table_layout.lua`, layout `head = 3`).
2. **The item buffer's first field line is `id: <number>`**, above `type:`.
3. **The id column is never cut and takes its width first** in `table_layout.budget`; the other columns give way as before.
4. **IDs are read-only.** A changed id cell or `id:` line rejects that row at `:w` ("the ID is read-only; put 101 back, or reload") and nothing is sent; the row's other edits are not planned. A typed line leaves its id cell empty, and its ID shows after the save reloads. A pasted row keeps the ID text it was copied with; moves and copies are still decided by the row ID prefix.
5. **Child rows keep their indent in the type column**, now the layout's indent cell, so the IDs line up in one column.
6. The hover float (`K`, and the cut-cell float) shows the ID as before.

Deviations, each low risk. Those marked **(changes earlier behaviour)** alter what phases 1 to 5 built:

1. **(changes earlier behaviour)** Rows need 9 more columns for 6-digit IDs (6 for the number, 3 for its separator) before they fit with the title at 20. Phase 5's rows fit a 60-column window. In tmux, with one 6-digit ID in the view, rows with long cells ran 4 columns past a 60-column window, so `$` scrolled the view sideways by 4; they fit from about 65 columns, depending on the widest state and the length of the hidden row ID prefix, which grows through a session. This follows from decision 3 (the ID is never cut) and the 20-column title floor; neither was changed. `table_layout_spec` checks every step boundary, now 9 columns wider.
2. **(changes earlier behaviour)** In Normal mode the cursor is moved out of a row's concealed row ID prefix on `CursorMoved`. Without this, `0`, `G` or `gg` leave the cursor on the hidden `/`, where it shows on the ID's first digit, and `yiw` yanks `/`.
3. **A typed line with text in its id column is rejected** ("a new line has no ID until the save creates it; leave its id column empty"), so a line typed to look like an existing item is never created as a new one.
4. **The rejection for a row that lost a separator** now reads "the row needs its five │ separators (id │ type │ state │ title │ assignee │ tags)".
5. **A parsed row holds the id cell's text as `shown_id`**, not `id`, so it never overwrites the work item ID of a loaded row. Core view records built by hand (`tests/support/records.lua`) carry it too; a record without it is not checked.

`make test` passes 662 tests (638 before) in name order and with `ORDER=reverse` and `ORDER=shuffle`; the change adds `tests/nvim/ids_spec.lua` (12) and cases in `table_layout_spec`, `plan_spec`, `lines_spec`, `fit_spec`, `complete_spec` and `pick_spec`, and the specs that found cells by position now find them by column name (`table_layout.INDEX`). Six guards were broken one at a time, each restored from a snapshot copy: the id cell comparison (5 specs failed), the `id:` line comparison (2), the new-line rejection (2), the id column's width in the budget (6), the id cut like a title together with a 2-column cap (16), and the cursor move out of the prefix (1).

`make bench` (WSL2, Neovim 0.11.6, 40 runs per case), every target met:

| Rows | Case | Rewrites | Median | Largest | TextChanged | Target |
| --- | --- | --- | --- | --- | --- | --- |
| 200 | full layout | | 1.27 ms | 2.49 ms | | none set |
| 200 | decorate every row | | 1.73 ms | 2.51 ms | | none set |
| 200 | re-pad, no column width change | 1 | 1.96 ms | 3.33 ms | 3.75 ms | under 5 ms |
| 200 | re-pad, widens a column | 200 | 2.48 ms | 3.84 ms | 4.44 ms | under 25 ms |
| 1,000 | full layout | | 6.61 ms | 8.60 ms | | under 50 ms |
| 1,000 | decorate every row | | 8.71 ms | 10.67 ms | | under 25 ms |
| 1,000 | re-pad, no column width change | 1 | 9.88 ms | 14.39 ms | 19.78 ms | under 25 ms |
| 1,000 | re-pad, widens a column | 1,000 | 14.23 ms | 17.74 ms | 24.02 ms | under 50 ms |

The bench's cell edits now name their column; before, they would have edited the column to the left once the id column came first.

Checked in tmux with the fake transport: at 100 columns every row fits; at 60 columns the IDs stay whole and aligned and `$` scrolls 4 columns (the fixture's IDs are 3 digits, plus one of 6 digits, which sets the column's width); `yic` and `G` then `yiw` yank `900033`; the item buffer shows `id: 100` first and its child rows indent in the type column; an edited ID is rejected in the summary float with nothing sent.

Manual checks still to run in the owner's editor:

- On a real area: `yiw` and `yic` on an ID cell, and on the item buffer's `id:` line, then paste into a browser or chat.
- At the widths the owner uses: whether rows with 6-digit IDs fit, and if not, whether the sideways scroll at 60 columns is acceptable or the title floor or another column should give way.
- `ciw` on an ID, `:w`: the save is rejected, naming the row; `u`, `:w` plans nothing.
- `dd` a row, `p` it in another area view, `:w`: one area change; `yyp`, `:w`: one copy, which shows its own ID after the reload.

## 6. Dependencies

No phase needs a new plugin or a newer Neovim than the 0.10 the README requires.

- `vim.ui.select` uses whatever replaces it (the owner has dressing.nvim); without a replacement the built-in list shows.
- `complete()` and `completefunc` are built in. When nvim-cmp is loaded, the views turn it off for their own buffers only; blink.cmp is asked to through `vim.b.completion = false`.
- Optional by feature detection: `'winborder'` (0.11) for the float border, `abbr_hlgroup` in completion items (0.11) for state colours in the menu. Without them the float uses `rounded` and the menu has no colours.
- Icons default to the characters in phase 2 and are overridable; nothing detects a Nerd Font.

No new domain objects are created, so nothing new feeds the analytics warehouse; writes stay recorded in the audit log as today.

## 7. Risks and assumptions

The risks specific to one phase are listed in that phase. These span phases, or are assumptions this plan makes.

| ID | Assumption or risk | What goes wrong if wrong | How the plan finds out early | Level | Phase |
| --- | --- | --- | --- | --- | --- |
| A1 | The headless facts in section 4 (explicit `TextChanged`, 80-column grid, `screenstring`) hold for every spec. | Specs pass while the editor misbehaves. | Each phase ends with manual checks in the owner's editor; the facts were checked on the owner's 0.11.6 binary. | Low | all |
| A2 | Views of 200 rows are the daily size, and 1,000 the most. | Timing targets aim at the wrong size. | `ux_stats` reports real durations in use. | Low | 1, 2, 5 |
| A3 | The owner's completion and picker plugins (nvim-cmp, dressing.nvim, noice.nvim) coexist with the plugin's menus once nvim-cmp is turned off in the views. | Two menus, or `<C-Space>` opening the wrong one. | Manual checks in phases 3 and 4 run in the owner's config. | Medium | 3, 4 |
| A4 | Hiding a cut tail with conceal cannot keep rows inside the window on 0.11.6 (section 5, phase 5). Whether 0.12 changes this was not checked. | If a later Neovim counts only drawn text, option C becomes cheaper. | `spike/ux/scroll_probe.lua` can be re-run on any version. | Low | 5 |

Decisions this plan makes, each low risk and reversible:

- People search runs before fitting (section 1).
- Re-pad rewrites only wrong runs of spaces with `nvim_buf_set_text`, and skips after `u`.
- Separators and marks are coloured by syntax rules, data colours by extmarks.
- `~` and `+` markers and the save summary share `core/row_changes.lua`.
- nvim-cmp is turned off inside the views.
- `<C-Space>` (with `<C-@>`, `<Nul>`, `<C-x><C-u>`) opens menus, and `<leader>we` picks a value; `<leader>we` is unused by the views and by the owner's global `<leader>w` keys (`wm`, `ws`, `wo`, `wa`, `wA`, `wi`, `wI`).
- A Visual-mode state pick offers only the states every selected row's type shares.
- People search waits 200 ms and 2 characters before calling ADO.
- A failed people search is reported once per Insert session.
- Type letters come from the type name's last word.
- A view with unsaved edits keeps its layout on resize.
- A buffer in two windows fits the narrower one.
- New lines are never cut.

## 8. Questions for the owner

**PQ1 (phase 5b).** How should columns fit the window?

- **T:** cut the text in the buffer, and have the save restore full values by the rule in phase 5. Rows always fit and nothing scrolls sideways, at the cost of a new rule in the save path, guarded by a rejection and the summary.
- **C:** the spike's conceal design. No change to the save, but moving to the assignee or tags of a row with a cut title scrolls the window and misaligns every row, and resizing a window rewrites the buffer.

Recommendation: T. Phase 5a prototypes T either way; without an answer, phases 1 to 5a go ahead and 5b waits.

**Answer (owner, 2026-10-15): T.** Long cells are cut in the buffer text, ending in `…`, and the plugin keeps the full value; the save restores full values. The two guards are required, not optional: the save rejects any cut cell it cannot restore to a full value, so a shortened value is never sent to ADO (fail closed), and the save summary shows every changed title in full before `y`. "Phase 5 as built" records how both are met.
