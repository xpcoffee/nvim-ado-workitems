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

## Keymaps

Wire these to the public API (the dotfiles spec does this):

| Key | Action |
|---|---|
| global | `require("ado").my_items()` / `.search()` / `.open_prompt()` |
| in a work-item buffer | `,ww` save · `,wc` comment · `,wS` state · `,we` edit description · `,wb` browser · `,wr` reload |

In a picker: `<CR>` open · `<C-s>` change state · `<C-y>` yank id+url · `<C-o>` browser.

## Notes

- `az boards query` only hydrates the fields named in the WIQL `SELECT`; the
  query builders list them explicitly.
- Text search uses WIQL `CONTAINS WORDS` (word/prefix over the index), not true
  full-text. Recent edits may lag the index.
- Field edits use a client-side `rev` guard against clobbering concurrent edits.
