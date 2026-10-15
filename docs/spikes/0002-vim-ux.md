# Spike 0002: user experience of the views

- Status: findings, for the owner to review before planning
- Date: 2026-10-12
- Scope: the area view, the item view and the save summary (`lua/ado/nvim/{lines,view_buffer,area_view,item_view,summary_ui}.lua`)
- Prototypes: `spike/ux/` (throwaway; not loaded by the plugin)

The views are plain editable text, so Vim motions, registers, macros and undo work on them. Each line starts with a concealed row ID prefix, `/<row id> `, which ties the line to the row it showed (`docs/architecture.md`, "Saving views", defines this and the other terms used here: the type catalog, the save summary, the audit log, the core sandbox). This spike asks how to make the views look and behave better without giving up plain text or moving behaviour out of the Neovim-free core (`lua/ado/core`).

The owner finds the views practical but ugly and unwieldy. Five problems, labelled P1 to P5 throughout:

- **P1.** Editing a cell changes its width, so the separators on that line shift and the table stops lining up.
- **P2.** Columns do not fit the window. Wanted: they fit, long cells end in `…`, and the full text shows when the cursor rests on the cell.
- **P3.** Type and state are typed by hand; wanted: a list of the valid values.
- **P4.** Assignees are typed by hand; wanted: a search of ADO people by prefix while editing.
- **P5.** The views look plain next to well-regarded plugins; wanted: the techniques that make those feel finished.

Claims about other plugins and Neovim cite a source. "Verified" means a prototype in `spike/ux/` was run on Neovim 0.11.6 in a tmux pane and the screen captured; "reasoned" means it follows from verified behaviour but was not run; "unverified" means the claim is from documentation summaries or memory and was not checked.

## 1. Summary

Ranked by value for effort. R1 to R6 label the recommendations.

1. **R1 (P1): re-pad the buffer text after every edit, and add a cell text object.** On `TextChanged` and `InsertLeave`, rewrite each row with real spaces padded to the column widths, joined to the user's change with `:undojoin`. Verified: the columns line up again on `<Esc>`, one `u` undoes the edit and the re-pad together, and a blockwise visual change across a column still works. Add `ic`/`ac` ("inner cell", "a cell") so `cic` replaces a whole cell; today `cw` on `Jane Doe` leaves `Doe` behind (verified). Small change to `lines.lua` and `view_buffer.lua`.
2. **R2 (P5): theme-aware colour and change markers.** Colour type and state with the colours ADO already returns from the type catalog call (verified: the same `workitemtypes` call returns `color` per type and per state, so no extra call), dim the separators, link every highlight group to a standard group with `default = true`, mark edited and new rows in the sign column, and put counts and the edited-row count in the winbar. Small change: a projection change in `nvim/az.lua` and `core/types.lua`, the rest in the presentation layer. Section 3.5 lists it as P5-a to P5-e, with optional further polish as P5-f to P5-h (save-summary verbs, an empty-state line, `?` help).
3. **R3 (P3): enum values offered in place.** In Insert mode, a key in the type or state cell calls `complete()` with the valid values for that row (verified working from a plain mapping). In Normal and Visual mode, a key opens `vim.ui.select` and writes the choice into that cell on every selected row, so a bulk change of one column needs no blockwise visual selection. No dependency: `vim.ui.select` uses whatever picker the owner has installed.
4. **R4 (P2): fit columns to the window and truncate with `…`.** Width budgets per column from the window width; the tail of a long cell is concealed with an extmark whose conceal character is `…`; a float after a short pause shows the full text of a truncated cell. Verified: the conceal and the budgets. Medium effort.
5. **R5 (P2): reveal the cell under the cursor while editing.** Needed because, with `concealcursor` including `i` (the row ID prefix needs it), text typed past the cut is hidden (verified). Showing the cursor cell in full was verified; hiding the cells to its right so the line stays inside the window was not prototyped. The first task of R5 is a prototype of that step combined with R1's re-padding, which was also not run together. This is the change with the most editing edge cases.
6. **R6 (P4): people search while editing the assignee.** Offer local candidates at once (assignees already on loaded rows, recent picks), then call the existing `resolve_identity` transport operation after a debounce and refresh the menu with `complete()` from the callback (verified with a 300 ms fake). Four real calls to the ADO people picker took 0.28 to 0.44 s. Medium effort; it touches the core because the picked identity should travel to the save.

R1 and R2 make the biggest visible difference for the least work. R4 and R5 are the ones to plan carefully: section 3.2 lists the options and what each breaks.

### Build order and dependencies

| Item | Depends on | Waits for an answer to | Files touched (expected) |
| --- | --- | --- | --- |
| R1 | none | Q1 (default: approach A) | `nvim/lines.lua`, `nvim/view_buffer.lua`, `nvim/keymaps.lua` (text objects) |
| R2 | none | Q5 (default: no `was:` text) | `nvim/az.lua` (`TYPES_PROJECTION`), `core/types.lua`, a new highlight module, `nvim/view_buffer.lua`, `nvim/area_view.lua`, `nvim/item_view.lua` |
| R3 | R1's cell text object (to find the cell under the cursor) | none | `nvim/keymaps.lua`, a new completion module, `core/types.lua` (states per type) |
| R4 | R1 (padding goes to the budget, not the widest cell) | Q2 (default: the drop order in Q2), Q4 (default: automatic float on truncated cells only) | a new pure `core/table_layout.lua`, `nvim/lines.lua`, `nvim/view_buffer.lua` |
| R5 | R4 | none | `nvim/view_buffer.lua` |
| R6 | R3 (the completion module and mapping) | Q3 (default: insert the email, no core change) | the completion module, `core/session.lua`; `core/plan.lua` only if Q3 picks the identity hint |

## 2. How the views render today

`lines.render` pads each cell with real spaces to the widest cell of its column at load time, joins cells with ` │ `, and prefixes `/<row id> `, which `view_buffer.lua` conceals with an extmark (`conceal = ""`, `conceallevel=2`, `concealcursor=nvic`). `lines.parse` reads a line back by splitting on `│` and trimming each cell, so it accepts padded and unpadded text alike. Nothing re-pads after an edit, which causes P1. Column widths come from content, never from the window, which causes P2; `nvim/layout.lua` sizes the three windows (area view, item view, detail split) and sets no column widths.

This is the oil.nvim pattern: real text, a concealed ID prefix, alignment computed once when the view loads ([oil `view.lua`](https://raw.githubusercontent.com/stevearc/oil.nvim/master/lua/oil/view.lua), [oil `syntax/oil.vim`](https://raw.githubusercontent.com/stevearc/oil.nvim/master/syntax/oil.vim)). mini.files and fyler.nvim do the same ([mini.files](https://raw.githubusercontent.com/nvim-mini/mini.files/main/lua/mini/files.lua), [fyler `syntax/fyler_finder.lua`](https://raw.githubusercontent.com/A7Lavinraj/fyler.nvim/main/syntax/fyler_finder.lua)). None of them re-aligns while you edit, and none truncates editable text.

## 3. The problems

### 3.1 P1: editing a cell shifts the separators on its line

Three ways to keep columns aligned were found.

**A. Real padding, re-padded after each change.** The buffer keeps real spaces. After a change in Normal mode (`TextChanged`) and on `InsertLeave`, a function recomputes column widths and rewrites the lines whose padding is wrong, after `:undojoin` so the re-pad joins the user's change in the undo tree (`:help :undojoin`). vim-table-mode realigns real text on `CursorHold` and when the separator is typed ([table-mode.txt](https://raw.githubusercontent.com/dhruvasagar/vim-table-mode/master/doc/table-mode.txt); the realign function itself was not read, so "rewrites real text" is unverified for it).

- Mechanics: `nvim_buf_set_lines` on the changed lines, from an autocommand, skipped while in Insert mode.
- Cost: small. `lines.render` already pads; the new part is calling it on the edited buffer.
- What it breaks: during Insert mode the edited line drifts until `<Esc>`, because rewriting text under the cursor while typing would move the cursor. Every state in the undo tree is aligned (each user change is joined to its re-pad), so `u` lands on aligned text and the autocommand has nothing to rewrite, which keeps redo intact (reasoned from the prototype, which showed no extra change after `u`).
- Verified with `spike/ux/realign_proto.lua`: typing `In Progress` over `Active` drifted only that line; `<Esc>` widened the state column on all three rows; one `u` restored the original text and widths; `<C-v>` over the state column of three rows then `cClosed<Esc>` changed all three cells and re-padded.

**B. Unpadded text, padding as inline virtual text.** The buffer holds cells with no padding; extmarks with `virt_text_pos = "inline"` (Neovim 0.10, `:help nvim_buf_set_extmark()`, news-0.10) insert the spaces. csvview.nvim does this: it pads after each field with inline virtual text, tracks the widest cell per column incrementally, updates from `on_lines` (so also while typing), and renders only the visible lines from a decoration provider ([csvview `view.lua`](https://github.com/hat0uma/csvview.nvim/blob/main/lua/csvview/view.lua), [`metrics.lua`](https://github.com/hat0uma/csvview.nvim/blob/main/lua/csvview/metrics.lua), [`init.lua`](https://github.com/hat0uma/csvview.nvim/blob/main/lua/csvview/init.lua)). render-markdown.nvim pads table cells the same way (`cell = "padded"`) ([`table.lua`](https://github.com/MeanderingProgrammer/render-markdown.nvim/blob/main/lua/render-markdown/render/markdown/table.lua)).

- Mechanics: one inline extmark per cell boundary, recomputed on `TextChanged`/`TextChangedI`.
- Cost: medium. A renderer replaces the padding in `lines.render`; for long views it needs csvview's visible-range rendering.
- What it breaks: blockwise visual mode and any command that works by screen column (`|`, `<C-v>` blocks), because screen columns no longer map to the same byte offsets on every row. Verified with `spike/ux/align_proto.lua`: `<C-v>` over the state column of three rows then `cClosed<Esc>` deleted the separator on two of the three rows and joined their cells. Yanked lines carry no padding, which is harmless since `lines.parse` trims.
- Verified benefits: alignment held while typing in Insert mode (the whole column widened on each key), and after `u`, `dd` and `p`. Rendering every row from scratch took 5.0 ms for 200 rows and 22.0 to 23.0 ms for 1,000 rows (two headless runs each); re-rendering on every `CursorMoved` at 1,000 rows would need visible-range rendering.

**C. Show raw text on the cursor line.** render-markdown.nvim stops rendering the cursor line ("anti-conceal") and does not render in Insert mode by default (`render_modes = { 'n', 'c', 't' }`) ([render-markdown.txt](https://raw.githubusercontent.com/MeanderingProgrammer/render-markdown.nvim/main/doc/render-markdown.txt)). That suits markdown, whose raw form is readable. Here the raw form is the same as the rendered form minus padding, so it buys nothing over A.

**Recommendation: A**, plus the cell text objects `ic` and `ac`. A keeps the property the design depends on (every Vim command sees the text it shows) and is the smaller change. The drift during Insert mode lasts until `<Esc>` and touches one line. If the owner never uses blockwise visual mode in these views, B gives live alignment while typing; that is Q1.

The cell text object selects from the separator before the cursor to the separator after it (trimmed for `ic`), so `cic`, `dic` and `yic` act on one cell whatever it holds. Today `cw` on an assignee replaces one word: verified in `spike/ux/complete_proto.lua`, where `cw` then choosing `Janet Doe` left `Janet Doe Doe`.

### 3.2 P2: columns do not fit the window

Fitting means giving each column a width budget from the window width, then truncating cells over budget with `…`. The hard part is that a truncated cell's text is still in the buffer and still editable.

**Options for truncation:**

| Option | How it works | Used by | What it breaks |
| --- | --- | --- | --- |
| Conceal the tail | An extmark from the cut point to the cell end with `conceal = "…"` (`:help nvim_buf_set_extmark()`, `conceal` takes one character) | render-markdown conceals excess whitespace this way; no plugin found that conceals editable text with `…` | With `concealcursor=nvic` (needed to keep the row ID hidden) the tail stays hidden on the cursor line, so text typed past the cut is invisible. Verified. The cursor can sit inside the hidden tail (verified: after `e` it was in the tail, drawn at the `…`). |
| Reveal the cursor cell | As above, but the renderer skips the truncation extmark for the cell under the cursor, re-run on `CursorMoved`/`CursorMovedI` | render-markdown's anti-conceal does this per line | The cursor line grows past the window and the cells to its right shift. Verified in `align_proto.lua` with `g:proto_reveal = "cell"`. |
| Render-only cells, edit in a float | The buffer shows a projection; `<CR>` on a cell opens an editor | markdown-pipetable.nvim (cell editor, own modal states) ([post](https://domlee.dev/posts/markdown-pipetable-nvim), [repo](https://github.com/dominic-righthere/markdown-pipetable.nvim)); this plugin's detail buffer already does it with `nvim/float.lua` | Vim editing of the table itself, which the design rules out. |
| Draw the table as virtual lines | `conceal_lines` (0.11) hides the real lines and `virt_lines` draws the table | markview-smart-tables.nvim; its cursor "appears pinned to the table's top line" ([repo](https://github.com/gunasekar/markview-smart-tables.nvim)) | The cursor and motions no longer match what is shown. |

Not fitting has its own cost, verified at 60 columns: with `nowrap`, moving to the end of a long row scrolls the window sideways, which hides the type and state columns of every row.

**Recommendation: conceal the tail, reveal the cell under the cursor, and keep the cursor line inside the window.**

- Budgets: fixed widths for type, state, assignee and tags (initial values 10, 10, 14, 14 at 100 columns, chosen to fit the mockups in section 4; tune after trying them), the title takes the rest. Below about 70 columns, the type cell is concealed to a single coloured letter (`B`, `S`, `T`, `F`: an extmark conceal over the whole cell, one replacement character) and tags are hidden on rows (shown in the hover float). Which columns drop, and in what order, is Q2.
- While the cursor is in a cell, that cell is shown in full. Cells to its right on the cursor line are hidden while that line is wider than the window, so the window never scrolls sideways. This "hide to the right" step was not prototyped.
- Approach A (real padding) and truncation combine: rows are padded to the budget, not to the widest cell, and only rows with a truncated cell have a longer real text. Blockwise visual mode over a column then misbehaves on those rows only (reasoned, not tested). R3's "set this column on the selected rows" covers the common bulk edit.

**Hover: show the full text.** After the cursor rests about 300 ms in Normal mode on a truncated cell, a float shows the full row: title, state, assignee with email, tags, area. Two ways to open it:

- `vim.lsp.util.open_floating_preview(lines, syntax, opts)` needs no LSP client and takes `close_events`, `focus_id`, `border`, `title` and `max_width` (`:help vim.lsp.util.open_floating_preview()`). Whether its default `close_events` include `CursorMoved` is unverified; pass them explicitly.
- A plain `nvim_open_win` float with `relative = "cursor"`, `focusable = false`, `style = "minimal"`, sized with `nvim_win_text_height()` (0.10, news-0.10). This gives full control, and `'winborder'` (0.11) supplies the user's border style.

Use a timer started on `CursorMoved` in the view buffer rather than `CursorHold`: `CursorHold` waits `'updatetime'`, 4000 ms by default (`:help 'updatetime'`), and lowering it is global. `K` already previews in the detail split, so the float stays automatic and only for truncated cells, or moves to a key; that is Q4.

### 3.3 P3: pickers for type and state

The valid values are known: the row's project `types` from `setup()`, and the states of the row's type from the type catalog the core already loads (`core/types.lua`).

**Options:**

- **`complete(startcol, items)` in Insert mode.** Shows the popup menu at the cell start; the user filters by typing and picks with `<C-n>`/`<C-y>` (`:help complete()`). Verified in `complete_proto.lua` for the state cell. It must be called from a plain mapping or `<Cmd>` mapping: called from an `expr` mapping it raised an error and nothing showed (the error text was not captured). Items can carry `menu` and `info` (`:help complete-items`), and `completeopt` with `popup` (0.10) shows `info` in a float.
- **`completefunc` for the buffer**, so `<C-x><C-u>` works too (`:help complete-functions`). Synchronous by protocol; fine for enums.
- **`vim.ui.select`** in Normal and Visual mode. Plugins replace it, so the owner's picker shows: snacks.nvim (`ui_select = true`, [picker docs](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md)), fzf-lua (`register_ui_select`, [README](https://github.com/ibhagwan/fzf-lua)), mini.pick (`MiniPick.ui_select`, [mini.nvim](https://github.com/echasnovski/mini.nvim)), telescope-ui-select ([repo](https://github.com/nvim-telescope/telescope-ui-select.nvim)). dressing.nvim is archived and points to snacks.nvim ([repo](https://github.com/stevearc/dressing.nvim)). The items are a static list (`:help vim.ui.select()`), which suits enums. The detail buffer already uses it for State (`nvim/detail.lua`).
- **Auto-trigger.** Neovim 0.12 adds `'autocomplete'`, with `'complete'` flags `F` and `o` to include `completefunc`/`omnifunc` (news-0.12). 0.12.0 was released on 2026-03-29 ([releases](https://api.github.com/repos/neovim/neovim/releases)); the owner runs 0.11.6, so this is optional.

**Recommendation:** a buffer-local Insert-mode key (proposed `<C-Space>`; `<C-x><C-u>` also works once `completefunc` is set) that completes the cell under the cursor, and a Normal/Visual key (proposed `<leader>we`; the views map none of these keys today (`nvim/keymaps.lua`), and the detail buffer's `,we` for the description is in a different buffer; global mappings in the owner's config were not checked) that opens `vim.ui.select` for the column under the cursor and writes the choice into that cell on the current row or every selected row. The write is an ordinary buffer change, so it shows in the summary like a typed edit and `u` undoes it. A state list per row, not per column, because rows of different types have different states.

### 3.4 P4: searching people for the assignee

The `az` transport already has `resolve_identity`, which posts a prefix to ADO's IdentityPicker through `az rest` and returns up to 10 identities with display name and email (`nvim/az.lua`). Measured from this machine, process start to exit, with the `ims` scope: 0.44 s and 0.30 s at the plugin's api-version 7.1-preview.1, and 0.38 s and 0.28 s at 5.0-preview.1. Four samples is enough to size a debounce, not to promise a latency.

**Options:**

- **Async `complete()`.** Return or show what is known at once, run the search, then call `complete()` again from the callback if the user is still in Insert mode on the same line. `completefunc` has no async protocol (`:help complete-functions`), so the refresh has to go through `complete()`. Verified in `complete_proto.lua`: after typing `Ja` and the key, the menu appeared 300 ms later with `Jane Doe`, `Janet Doe` and `Jan Kowalski`, and the guard (mode and line unchanged) is what keeps a late answer from landing on another line.
- **In-process LSP server.** `vim.lsp.start()` accepts a Lua function as `cmd`, so the plugin can serve `textDocument/completion` itself, returning `isIncomplete = true` so clients ask again as the user types (`:help lsp-server`; Neovim's own `runtime/lua/vim/pack/_lsp.lua` uses this for hover; none-ls uses it too, [none-ls](https://github.com/nvimtools/none-ls.nvim)). One implementation then feeds built-in `vim.lsp.completion`, and blink.cmp and nvim-cmp through their LSP sources (the LSP sources were not re-checked in this spike). Cost: an LSP client attached to every view buffer, and the user's completion plugin must have its LSP source enabled.
- **Live picker.** `vim.ui.select` cannot search as the user types. Live sources need each picker's own API: snacks.nvim `live`, fzf-lua `fzf_live`, mini.pick `set_picker_items` (the snacks and fzf-lua APIs are unverified in detail). One adapter per picker.
- **Plugin completion sources.** blink.cmp (`get_completions(ctx, callback)`, [source boilerplate](https://cmp.saghen.dev/development/source-boilerplate)) and nvim-cmp (`complete(params, callback)`, [cmp.txt](https://github.com/hrsh7th/nvim-cmp/blob/main/doc/cmp.txt)). One adapter each.

**Recommendation:** async `complete()` first, with local candidates so the menu is never empty: the assignees on the loaded rows of every open view, and people picked earlier in the session. Debounce the search (proposed 200 ms after the last key), cache answers by prefix, and filter a cached shorter prefix locally while the call runs. Show the email as `menu` or `info` so two people with the same name can be told apart. Leave the in-process LSP server as a later, optional step if the owner wants the same menu inside blink.cmp.

The save currently resolves the assignee text again and rejects text that matches no identity or several (`plan.prepare`; requirement R5.19 in RFC 0001). If completion inserted a display name that two people share, the save would reject what the user picked. Two ways out: insert the email instead (unambiguous, wider), or keep the picked identity in the view state keyed by row ID and text and hand it to the plan as a hint. That is Q3.

### 3.5 P5: what makes a UI feel finished

The plugins people cite as polished share a short list of techniques. Each is small on its own.

- **Highlight groups linked to standard groups, with `default = true`, re-applied on `ColorScheme`.** lazy.nvim (about 35 `Lazy*` groups, for example `LazyDimmed` linked to `Conceal`, [colors.lua](https://raw.githubusercontent.com/folke/lazy.nvim/main/lua/lazy/view/colors.lua)), trouble.nvim ([repo](https://github.com/folke/trouble.nvim)) and oil.nvim (`OilCreate` to `DiagnosticInfo`, `OilDelete` to `DiagnosticError`, [init.lua](https://raw.githubusercontent.com/stevearc/oil.nvim/master/lua/oil/init.lua)) do this, so every colour scheme works. mason.nvim hard-codes hex colours for most groups and does not follow the theme ([colors.lua](https://raw.githubusercontent.com/williamboman/mason.nvim/main/lua/mason/ui/colors.lua)).
- **Secondary text dimmed with `Comment`, `Conceal` or `NonText`**: separators, counts, row markers. Same sources.
- **Colour from the data.** octo.nvim builds a highlight group per label colour and picks black or white text by luminance (`0.299r + 0.587g + 0.114b`) ([colors.lua](https://raw.githubusercontent.com/pwntester/octo.nvim/master/lua/octo/ui/colors.lua)). ADO returns a colour per type and per state from the `workitemtypes` call the catalog already makes (verified for `Bug` in the `Example` project: `CC293D` for the type, `b2b2b2`, `007acc`, `ff9d00`, `339933` for its states); today the projection `TYPES_PROJECTION` in `nvim/az.lua` drops them.
- **Floats with a title and a key-hint footer.** snacks.nvim builds the footer from the window's real keymaps and falls back to `'winborder'` for the border ([win.lua](https://raw.githubusercontent.com/folke/snacks.nvim/main/lua/snacks/win.lua)). Float `footer` needs 0.10 and `'winborder'` 0.11 (news-0.10, news-0.11). The save summary already has a title and footer.
- **A confirm float that reads like a diff.** oil.nvim's confirmation puts a fixed-width verb at the start of each line (`CREATE`, `DELETE`, `MOVE`, `CHANGE`, `COPY`), coloured through its `Oil*` groups ([confirmation.lua](https://raw.githubusercontent.com/stevearc/oil.nvim/master/lua/oil/mutator/confirmation.lua), [oil_preview.vim](https://raw.githubusercontent.com/stevearc/oil.nvim/master/syntax/oil_preview.vim)).
- **Help on `?`.** snacks.nvim lays out the buffer's real keymaps in columns ([win.lua](https://raw.githubusercontent.com/folke/snacks.nvim/main/lua/snacks/win.lua)); neogit shows a hint line at the top of its status buffer ([README](https://raw.githubusercontent.com/NeogitOrg/neogit/master/README.md)).
- **Icons as a user-overridable table with a fixed width.** No plugin read detects whether a Nerd Font is installed; they ship a table the user overrides (snacks.nvim `icon_width = 2`, [picker docs](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md); neogit defaults to `>`/`v`).
- **Progress that replaces itself in place.** snacks.nvim's notifier replaces a message with the same `id` ([notifier docs](https://raw.githubusercontent.com/folke/snacks.nvim/main/docs/notifier.md)); fidget.nvim shows a spinner and a `done_icon` for `done_ttl` seconds ([fidget-option.txt](https://raw.githubusercontent.com/j-hui/fidget.nvim/main/doc/fidget-option.txt)). Neovim 0.12 adds progress messages through `nvim_echo()` with a `kind` (news-0.12).

oil.nvim marks no individual rows as changed; it relies on the buffer's `modified` flag ([view.lua](https://raw.githubusercontent.com/stevearc/oil.nvim/master/lua/oil/view.lua)). Per-row markers would go beyond oil.

**Recommendation, in order.** P5-a to P5-e make up R2; P5-f to P5-h are optional and can follow in any order.

1. P5-a: One highlight module: groups such as `AdoType`, `AdoState`, `AdoSeparator`, `AdoDirty`, each linked with `default = true`, plus generated groups per ADO colour (octo's method), re-made on `ColorScheme`.
2. P5-b: Add `color` per type and per state to `TYPES_PROJECTION`; colour the type cell and draw a `●` in the state colour before the state cell (inline virtual text: the same width on every row, so alignment and column commands are unaffected, which is reasoned and not tested).
3. P5-c: Separators and the area and heading markers in `NonText`.
4. P5-d: Sign-column markers from a comparison of each row with its loaded snapshot: `~` changed, `+` new or pasted. Optionally the old value at the end of the line in `Comment` (`was: Active`).
5. P5-e: Winbar: area, filters, then counts and the number of edited rows, right-aligned with `%=`.
6. P5-f: Save summary: fixed-width verbs, coloured like oil's, and the footer from the real keys.
7. P5-g: An empty-state line ("No open items here. `<leader>wf` changes the filter.") as virtual text instead of an empty buffer.
8. P5-h: `?` opens the view's keymaps in a float.

## 4. Proposed rendering

In the mockups, `│` separators, `●` dots, the `~`/`+` sign column and the winbar (first line) are drawn by the renderer; the cells are buffer text. The row ID prefix is concealed as today. `…` marks a concealed tail.

### 4.1 Area view at 100 columns

```text
 Team A  open · any type · anyone                     3 areas · 42 items · 2 edited
  ▸ Reports/
  ▸ Scheduling/
  Bug        │ ● Active   │ Crash when the area path holds a slash │ Jane Doe       │ auth
~ User Story │ ● New      │ Show the save summary next to the cur… │ Bartholomew F… │ ux · q4-plann…
  Task       │ ● Resolved │ Fix the login redirect loop on expire… │                │
+ Task       │ ● New      │ Add a people search to the assignee c… │ Sam Robertson  │ ux
```

### 4.2 Area view at 60 columns

The type cell is concealed to its letter and tags are hidden on rows; both show in the hover float.

```text
 Team A…  open                   42 items · 2 edited
  ▸ Reports/
  ▸ Scheduling/
  B │ ● Active   │ Crash when the area path hold… │ Jane Doe
~ S │ ● New      │ Show the save summary next to… │ Barthol…
  T │ ● Resolved │ Fix the login redirect loop o… │
+ T │ ● New      │ Add a people search to the as… │ Sam Rob…
```

### 4.3 While editing a cell

The user runs `cic` on the second row's title and types. The title cell is shown in full and the cells to its right on that line are hidden; the other rows do not move. Here the title itself (76 columns) is wider than the 72 left after the type and state cells, so its end runs past the window edge, and moving the cursor there scrolls the window sideways (`:help 'sidescroll'`). That is the one case fitting cannot avoid: a single cell wider than the window. With approach A the drift on the edited line is at most the cell's growth, and `<Esc>` re-pads.

```text
 Team A  open · any type · anyone                     3 areas · 42 items · 2 edited
  ▸ Reports/
  ▸ Scheduling/
  Bug        │ ● Active   │ Crash when the area path holds a slash │ Jane Doe       │ auth
~ User Story │ ● New      │ Show the save summary next to the cursor instead of the centre of th
  Task       │ ● Resolved │ Fix the login redirect loop on expire… │                │
+ Task       │ ● New      │ Add a people search to the assignee c… │ Sam Robertson  │ ux
```

On `<Esc>`, the title column stays at its budget (the budget comes from the window, not the content), the cursor cell keeps showing in full while the cursor is in it, and moving off it truncates it again. A cell that grows within its budget widens its column on every row on `<Esc>`.

Typing in the assignee cell shows the menu under the cell, local candidates first:

```text
~ User Story │ ● New      │ Show the save summary next to the cur… │ Ja▏            │ ux · q4-plann…
  Task       │ ● Resolved │ Fix the login redirect loop on expire… │ Jane Doe     jane.doe@…
+ Task       │ ● New      │ Add a people search to the assignee c… │ Janet Doe    janet.doe…
                                                                     Jan Kowalski jan.kowalski@…
```

### 4.4 Item view at 100 columns

`parent` at the end of the parent row is the end-of-line label the view already shows.

```text
 #4812 Bug                                                                      children: open only
  Crash when the area path holds a slash in its name
    type:     Bug
    state:    ● Active
    assignee: Jane Doe
    tags:     auth · regression
  Feature    │ ● Active   │ Work item navigator v1                    │ Sam Robertson  │      parent
  ▸ Team A/
  ── Children  2 open · 1 closed hidden
  Task       │ ● Active   │ Reproduce with a nested area path         │ Jane Doe       │ auth
~ Task       │ ● New      │ Escape slashes in area buffer names       │ Bartholomew F… │
  ── Related  1
  Bug        │ ● Closed   │ Area view drops sub-areas with a dot      │ Janet Doe      │ regression
```

### 4.5 Item view at 60 columns

```text
 #4812 Bug                              children: open only
  Crash when the area path holds a slash in its name
    type:     Bug
    state:    ● Active
    assignee: Jane Doe
    tags:     auth · regression
  F │ ● Active   │ Work item navigator v1         │ Sam Rob…
  ▸ Team A/
  ── Children  2 open · 1 closed hidden
  T │ ● Active   │ Reproduce with a nested area … │ Jane Doe
~ T │ ● New      │ Escape slashes in area buffer… │ Barthol…
  ── Related  1
  B │ ● Closed   │ Area view drops sub-areas wit… │ Janet Doe
```

The field lines already align, since `lines.lua` pads the field name; they need the colour dot and truncation only.

## 5. Core and presentation

The core keeps everything that decides what is shown or allowed; the presentation layer keeps extmarks, highlights, floats, completion menus and autocommands.

| Concern | Core (`lua/ado/core`, no `vim`) | Presentation (`lua/ado/nvim`) |
| --- | --- | --- |
| Column layout | A pure `layout(rows, budget, measure)` returning each column's width and each cell's cut point; `measure` is passed in (it is `vim.fn.strdisplaywidth` in Neovim), so the sandbox specs can test it. Which columns drop at which widths. | Window width, re-render on `WinResized`, the conceal and padding extmarks, re-padding and `:undojoin`. |
| Enum values | Valid types per project and states per type, from the catalog (`core/types.lua` has both). | `complete()`, `vim.ui.select`, writing the choice into cells. |
| People search | A session method that merges local candidates, caches by prefix and ranks; it calls the existing `resolve_identity` operation. Any hint about the picked identity that the save uses. | The debounce timer, the in-Insert-mode guard, the menu. |
| Hover content | A function from a row to labelled values. | The float and its timer. |
| Change markers | A function from a snapshot row and a parsed row to the changed fields (the plan already computes this per save; it needs to be callable per row). | Signs and end-of-line text. |
| Colours | The colour per type and state, carried in the catalog. | Highlight groups made from those colours. |

The parser needs no change: it already splits on `│` and trims. The registry, the plan and the save are untouched by R1 to R5; R6 adds the identity hint only if the owner picks that answer to Q3.

Observability: people-search calls should report their duration and result count through the existing progress messages, so slow searches are visible without a debugger. The writes they lead to are already in the audit log.

## 6. Dependencies

None of the recommendations needs a new plugin.

- `vim.ui.select` uses the owner's picker if one replaces it, else the built-in list.
- `complete()` and `completefunc` are built in. blink.cmp and nvim-cmp keep working in other buffers; inside the views the plugin's own mapping drives the menu. An in-process LSP server (section 3.4) would feed blink.cmp and nvim-cmp later without a dependency, through their LSP sources.
- Icons: a table with ASCII defaults (the letters in section 4.2, `●`, `▸`, `~`, `+`), overridable with Nerd Font glyphs.
- Neovim version: inline virtual text and float footers need 0.10; `'winborder'` and `conceal_lines` need 0.11; `'autocomplete'` and progress messages need 0.12. The README says 0.10+; the owner runs 0.11.6.

## 7. Open questions for the owner

Each question names the item it holds up and the default planning should assume if it stays open.

1. **Q1 (R1).** Do you use blockwise visual mode (`<C-v>`) or `|` in these views? If not, approach B (inline padding) aligns while you type; if so, approach A. Default: A.
2. **Q2 (R4).** At narrow widths, which columns may drop or shrink, and in what order? Default: tags hidden first, then type shown as a letter, then assignee shortened; the title never below 20 columns.
3. **Q3 (R6).** Should a picked assignee be inserted as the display name, with the plugin remembering who was picked so the save cannot find it ambiguous (a change to the view record and `core/plan.lua`), or as the email (no core change, wider column)? Default: the email, since it needs no core change; the display name can follow.
4. **Q4 (R4).** Should the hover float open by itself on truncated cells after a pause, or only on a key? `K` is taken by the detail preview. Default: by itself, truncated cells only.
5. **Q5 (R2).** Is the old value at the end of an edited line (`was: Active`) useful, or noise next to the sign-column marker? Default: leave it out.

No recommendation needs a newer Neovim than the 0.10 the README requires, except optional uses of `'winborder'` (0.11), which can be feature-detected.

## Appendix: prototypes run

All three are in `spike/ux/` and run with `nvim --clean -u spike/ux/<file>`. They were driven with `tmux send-keys` in a 100-column pane (and 60 for the narrow check) and read back with `tmux capture-pane`.

| Prototype | What it does | Result |
| --- | --- | --- |
| `align_proto.lua` | Approach B: unpadded cells, inline-virtual-text padding, tail conceal with `…`, re-rendered on `TextChanged`, `TextChangedI`, `CursorMoved`, `CursorMovedI`, `WinResized`. `g:proto_reveal` = `none`, `line` or `cell`. `:lua ProtoBench(n)` times a render of n rows. | Aligned while typing, after `u`, `dd`, `p`. Typed text past the cut was hidden with `reveal = none`. Cell reveal showed the full assignee and shifted the rest of that line. `<C-v>` change over a column broke two of three rows. 5.0 ms per render at 200 rows, 22.0 to 23.0 ms at 1,000. At 60 columns, going to the end of a long row scrolled every row sideways. |
| `realign_proto.lua` | Approach A: real padding rewritten on `TextChanged` and `InsertLeave` after `:undojoin`. | Only the edited line drifted during Insert mode; `<Esc>` re-padded all rows; one `u` undid edit and re-pad; `<C-v>` change over a column worked. |
| `complete_proto.lua` | Loads `align_proto.lua` and maps `<C-l>` in Insert mode: `complete()` with states, or a fake people search answering after 300 ms. | Enum menu appeared at the cell start; the fake search menu appeared after the delay; from an `expr` mapping, `complete()` failed. `cw` on `Jane Doe` replaced only `Jane`. |

Two read-only calls were made to ADO: one `workitemtypes` call for the `Example` project (type and state colours) and two IdentityPicker searches (`Al`, `Alex`) to time them.
