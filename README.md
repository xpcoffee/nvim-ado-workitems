# nvim-ado-workitems

Navigate, search, and edit Azure DevOps work items without leaving Neovim.

Backend is the `az` CLI (azure-devops extension); `az` owns auth/token refresh.
Requires Neovim 0.10+, `az`, and `pandoc` (for the description markdown round-trip).

## Setup

```lua
require("ado").setup({
  org = "your-org",       -- defaults to $ADO_ORG
  project = nil,          -- defaults to $AZURE_DEVOPS_EXT_DEFAULT_PROJECT, else a first-use picker
  default_query_top = 200,
  description_format = "markdown",
})
```

## Editing

The detail buffer is read-only. Put the cursor on a field and press `<CR>` (or
an insert key: `i`/`a`/`o`…) to open a focused floating editor for just that
field — text fields get a one-line input, State a select, Description a markdown
pane. Confirm with `<CR>` (`<C-s>` in the multi-line description), cancel with
`q`/`<Esc>`. The float closes itself and the change saves on confirm (with a
`rev` guard); nothing to clean up.

## Keymaps

Global (wired by the dotfiles spec): `require("ado").my_items()` / `.search()` /
`.open_prompt()`.

In a work-item buffer: `<CR>`/`i` edit field under cursor · `,wc` comment ·
`,wS` state · `,we` description · `,wb` browser · `,wr` reload.

In a picker: `<CR>` open · `<C-s>` change state · `<C-y>` yank id+url · `<C-o>` browser.

## Notes

- `az boards query` only hydrates the fields named in the WIQL `SELECT`; the
  query builders list them explicitly.
- Text search uses WIQL `CONTAINS WORDS` (word/prefix over the index), not true
  full-text. Recent edits may lag the index.
- Field edits use a client-side `rev` guard against clobbering concurrent edits.
