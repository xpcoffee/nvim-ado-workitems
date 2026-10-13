# Plan 0001: Implementing the work item navigator and the open-state filter

- Status: Draft, for the owner's review before phase 0 starts
- Date: 2026-10-11
- Implements: [RFC 0001](../rfc/0001-workitem-navigator.md) (navigator) and [RFC 0002](../rfc/0002-open-state-filter.md) (open-state filter)
- Builds on: the oil.nvim spike, branch `spike/oil-adapter`, `docs/spikes/0001-oil-adapter.md`

Requirement IDs (R2.1, R5.10, ...) refer to the two RFCs. "A0001-N" is acceptance behaviour N in RFC 0001 section 8, and "A0002-N" is behaviour N in RFC 0002 section 7. "RFC Q4" is open question Q4 in RFC 0001; this plan's own questions for the owner are PQ1 to PQ4, in section 8. RFC terms (row, snapshot, change plan, location, revision guard, open state) keep their RFC meaning. This plan adds four:

- **Core**: the modules under `lua/ado/core/`. They hold behaviour and state, and never touch `vim` (R6.1).
- **Presentation layer**: the modules under `lua/ado/nvim/`, which own buffers, windows, keymaps and the `az` CLI (R6.5).
- **Transport**: the table of asynchronous functions through which the core reaches Azure DevOps (ADO) (R6.3). The presentation layer supplies the `az` transport; tests supply the fake transport.
- **Sandbox**: a Lua environment in which reading the global `vim`, requiring a non-core module, or starting a process raises an error. Core tests run inside it.

## 1. Why this order

1. **The seam comes first.** Every later phase writes core code and core tests. Without a test runner and a transport interface in place, the first feature would be written against `vim.system` directly, as `client.lua` is today, and need rewriting.
2. **RFC 0002 ships next** because it is small (7 requirements, 3 behaviours), it improves two lists the owner uses daily, and it builds the type catalog (states and their categories per type) that the area view filter (R2.4), state validation (R5.7) and type changes (R5.22) all need.
3. **Reading before writing.** The area view and the item view ship read-only first. That proves the row format, the concealed row IDs, buffer naming and navigation on real data, while a bug can only show something wrong, not change ADO.
4. **Editing grows by risk.** Phase 4 builds the whole save pipeline (rows to plan, summary, confirm, apply, partial-failure report, audit log) with only title and state edits, the two whose mistakes are easiest to see and undo. Phase 5 adds structural edits (moves, copies, link removals, creates), which carry most of the R5 rules. Phase 6 adds the columns that need extra lookups (assignee identities) or lose data (type changes).

Each phase ends with a usable plugin: no phase leaves a feature half-wired behind a flag.

## 2. Phases at a glance

| Phase | Delivers to the user | Acceptance behaviours |
| --- | --- | --- |
| 0. Test harness and core/transport seam | No visible change; existing pickers and detail buffer work as before | none (harness only) |
| 1. Open-state filter (RFC 0002) | "My work items" and search show only open items; search toggles to all states | A0002-1 to 3 |
| 2. Read-only area view | Browse configured areas, sub-areas, filters, back/forward, open in browser | A0001-1 to 3 |
| 3. Read-only item view | Parent, area, children, Related links, inline expansion, the view layout (owner decision 2026-10-12: one column, area view on top, item view, then detail) | A0001-4, 5 |
| 4. Column edits and the save pipeline | Edit title and state in either view, `:w`, summary, confirm, apply, audit log | A0001-18 to 20, 23, 24 |
| 5. Structural edits | Move, copy, delete (link removal), new lines, across buffers | A0001-6 to 17, 21, 22, 27 |
| 6. Remaining columns | Edit assignee, tags and type | A0001-25, 26, 28 to 30 |

Section 9 lists the dotfiles changes, which follow phases 2, 3 and 5.

## 3. Module layout

The target layout. Each phase section says which files it creates or changes.

```text
lua/ado/
  init.lua                public API: setup, my_items, search, open, open_prompt (all existing), area_view, item_view
  config.lua              setup() options (uses vim.tbl_extend, so stays outside core)
  core/
    transport.lua         interface contract; validate(t) checks every operation exists P0
    session.lua           transport, org, project, caches, latest item per ID       P0
    workitem.lua          normalise raw ADO JSON to domain items; parse relations  P0
    query.lua             structured query specs                                   P0
    wiql.lua              render a query spec to WIQL (moved from lua/ado/wiql.lua) P0
    types.lua             type catalog: states, categories, open set, validation   P1
    area_path.lua         convert between area path forms                          P2
    location.lua          area and item locations, buffer URI encode/decode        P2
    history.lua           back/forward over locations                              P2
    area_view.lua         load an area view's rows                                 P2
    urls.lua              browser URLs for items and area queries                  P2
    item_view.lua         load an item view's sections; expand one level           P3
    plan.lua              change plan from views of rows                           P4, P5, P6
    summary.lua           plan to grouped summary lines (R7.2)                     P4
    apply.lua             execute a plan; partial-failure report; audit events     P4
  nvim/
    az.lua                az transport (from client.lua)                           P0
    picker.lua            telescope pickers (moved)                                P0
    detail.lua            detail buffer (rendering half of workitem.lua, moved)    P0
    float.lua             field editors (moved)                                    P0
    lines.lua             row <-> line text, string functions only                 P2
    registry.lua          session-wide row ID registry                             P2
    view_buffer.lua       buffer creation, naming, conceal, winbar, BufWriteCmd    P2, P4
    layout.lua            area window, detail split, item side panel               P2, P3
    area_view.lua         area view buffer                                         P2
    item_view.lua         item view buffer, expansion                              P3
    keymaps.lua           default view keymaps                                     P2
    progress.lua          load and save progress messages                          P2
    save.lua              collect modified views, run plan, confirm, apply, reload P4
    summary_ui.lua        summary float with accept/cancel                         P4
    audit.lua             append audit events to the log file                      P4
tests/
  run.lua                 runner: core suite in the sandbox, then the nvim suite
  support/sandbox.lua     sandboxed loader and assertion helpers
  support/fake_transport.lua
  fixtures/seed.lua       fake ADO data
  core/*_spec.lua         core tests (sandboxed)
  nvim/*_spec.lua         presentation tests (headless Neovim, processes blocked)
Makefile                  `make test`, `make test-core`
```

`lua/ado/client.lua`, `wiql.lua` and `workitem.lua` disappear in phase 0; their callers move to the new modules.

## 4. The transport

### 4.1 Interface

Every operation has the shape `transport.<op>(params, cb)`.

- `cb(err, result)` is called exactly once. `err` is `nil` on success, otherwise `{ kind = "auth" | "not_found" | "conflict" | "invalid" | "failed", message = string }`.
- The callback MAY run synchronously (the fake does by default) or later (the `az` transport runs it on the main loop through `vim.schedule`). Core code must be correct either way: it must not rely on code after the call running before the callback.
- Results are ADO REST JSON shapes (`{ id, rev, fields = {...}, relations = {...} }`), not domain objects. `core/workitem.lua` normalises them, so the fake exercises normalisation too.
- Queries pass both forms: `{ wiql = string, spec = table }`. The `az` transport sends `wiql`; the fake evaluates `spec`. `core/wiql.lua` renders one from the other, and its tests compare WIQL strings, so the two cannot drift without a failing test.

| Operation | Params | Result | `az` route | Status |
| --- | --- | --- | --- | --- |
| `list_projects` | `{}` | `{ name... }` | `az devops project list` | Verified: in use (`client.ensure_project`) |
| `query` | `{ wiql, spec }` | list of raw items, fields named in `SELECT` | `az boards query --wiql W --project P` | Verified: in use (`client.query`). VERIFIED 2026-10-12 for the item view: `[System.Id] IN (...)` returns the items that exist and leaves out an ID that does not, with no error; each result carries `relations: null`. VERIFIED 2026-10-12 for the area view: `[System.AreaPath] =` and `UNDER` with the field form (case-insensitive), `[System.TeamProject] IN`, `[System.AssignedTo] = @Me`, `[System.WorkItemType] IN`, and `[System.Tags] CONTAINS 'tag'`, which matches whole tags only (a 3-character prefix of a tag matched 0 items). Changed 2026-10-12: with no results `az` prints nothing rather than `[]`; with many, it stops fetching once it holds 1,000 items, checking between batches, so it can return a little over 1,000 (1,179 seen). |
| `get_work_item` | `{ id, relations = true }` | raw item with `rev` and `relations` | `az boards work-item show --id N --expand relations` | VERIFIED 2026-10-12, changed: `show`'s default `--expand` is `all`, which already carries `relations`; `--expand relations` returns the same relations and fewer fields (28 against 46 on one Feature, dropping computed fields such as `System.AreaLevel1` that no caller reads). Neither form has `_links`. Each relation is `{ rel, url, attributes = { isLocked, name } }`: `Hierarchy-Reverse` is the parent (name `Parent`), `Hierarchy-Forward` a child (`Child`), `System.LinkTypes.Related` has `name = "Related"` and a `comment`. Relations also include `ArtifactLink` (pull requests, `vstfs:` URLs) and `AttachedFile` (an `.../_apis/wit/attachments/<guid>` URL whose tail can end in digits), so the target ID is read only from a URL ending `/_apis/wit/workItems/<id>`. Fixture: `tests/fixtures/az/work_item_show_relations.json`. |
| `query_children` | `{ id }` | raw items whose parent is `id` | `query` with `WHERE [System.Parent] = N` | VERIFIED 2026-10-12, changed: WIQL accepts `[System.Parent] = N` and `[System.Parent] IN (...)`, and `System.Parent` can be selected. Because the route is a plain `query`, no `query_children` operation was added: the core sends the `[System.Parent]` query through `query`, still 1 call per expansion. The fallback is not needed. Fixture: `tests/fixtures/az/query_children.json`. |
| `area_children` | `{ project, path }` | `{ { name, path, hasChildren }... }`, one level | `az boards area project list --project P --path PATH --depth 1` | VERIFIED 2026-10-12 on `Example` and `Operations`, changed: `--path` takes only the absolute node form (`\Example\Area\Software\Platform`; relative and field forms fail with "expected to be absolute path"), the response is the node itself with its `children`, each child's own `children` is `null`, and the project's root node is `\Example\Area`, named after the project. Children come in ADO's order, not by name. Fixtures: `tests/fixtures/az/area_children_platform.json`, `area_children_leaf.json`. |
| `work_item_types` | `{}` | `{ { name, isDisabled, states = { { name, category }... } }... }` | `az devops invoke --area wit --resource workitemtypes --route-parameters project=P --api-version 7.1 --query "value[].{name: name, isDisabled: isDisabled, states: states[].{name: name, category: category}}"` | VERIFIED 2026-10-11 on project `Example`: 23 types, every state carries `category`. The `--query` projection is an addition: without it the response is 1.2 MB (form XML, field lists), with it 8.5 KB. Fixture: `tests/fixtures/az/work_item_types.json`. Fallback per type: `--resource workitemtypestates --route-parameters project=P type=T --api-version 6.0`, VERIFIED 2026-10-11 to return `category`; fixture `tests/fixtures/az/work_item_type_states_task.json`. |
| `update_fields` | `{ id, fields = { [ref] = value } }` | raw item, new `rev` | `az boards work-item update --id N` with `--title`, `--state`, `--assigned-to`, `--fields System.Tags=...` | Removed 2026-10-13: the detail buffer and the picker now write through `patch_work_item` (section 8). Verified for those four while in use. VERIFIED 2026-10-12 for phase 4 on two throwaway Tasks, through the `az` transport with the write guard on: `--title` and `--state` each return the full item with `rev` one higher, and both in one call also raise `rev` by one; the response carries `relations`. A state the type lacks fails with "The field 'State' contains the value 'Bogus' that is not in the list of supported values" and leaves `rev` unchanged. Revision guard: `show` and `az boards query` both report the `rev` each write produced, so a snapshot `rev` from a query compares directly with the `rev` that `Session:update_if_unchanged` reads. VERIFIED 2026-10-12 for phase 5, on test items through the write guard: `--area` is accepted, and setting the area an item already has leaves `rev` unchanged. A move to a different area was not run against ADO, because the only area agents may write to has no sub-areas; the move is tested against the fake only. VERIFIED 2026-10-12 for phase 6 on test item #900058 through the write guard (PQ3): `--fields System.WorkItemType=T` changes the type (Task to User Story and back, `rev` one higher each time). A type change whose current state the new type lacks fails with "The field 'State' contains the value 'Testing' that is not in the list of supported values" and leaves `rev` unchanged; the same change with `--state` in the same call succeeds. `--assigned-to EMAIL` assigns and `--assigned-to ""` unassigns. Changed: `--fields System.Tags=...` merges into the existing tags, so it cannot remove one (setting `b` on an item tagged `a; b` left `rev` unchanged, and so did an empty value). Tag updates therefore go through `az rest --method patch --url https://dev.azure.com/ORG/_apis/wit/workitems/N?api-version=7.1 --resource 499b84ac-1321-427f-aa17-267ca6975798 --headers Content-Type=application/json-patch+json --body '[{"op":"replace","path":"/fields/System.Tags","value":"..."}]'`, VERIFIED the same day to replace the list and, with an empty value, clear it; the response is the full item with the new `rev`. `az devops invoke --area wit --resource workitems` cannot send it: it picks the create route, whose URL needs a type. |
| `add_link` | `{ id, rel, target, name }` | raw item | `az boards work-item relation add --id N --relation-type NAME --target-id M` | Removed 2026-10-12: links now go in `patch_work_item` (owner request "One write per work item", section 8). VERIFIED 2026-10-12 while in use: `--relation-type` takes the display name (`Parent`, `Related`), ADO stores the link on both items, and neither item's `rev` changes (changed from assumption 4). A second parent fails with "TF201036: You cannot add a Parent link between work items N and M because a work item can have only one Parent link." Adding a Related link that already exists succeeds and changes nothing. The fixture `work_item_relation_add.json` was removed with the route. |
| `remove_link` | `{ id, rel, target, name }` | raw item | `az boards work-item relation remove --id N --relation-type NAME --target-id M --yes` | Removed 2026-10-12, as `add_link`. VERIFIED 2026-10-12 while in use: it removes both ends; removing a link that does not exist fails with "Id(s) supplied in --target-id is not valid". |
| `create_work_item` | `{ project, type, patch }`: `patch` is a JSON Patch of field `add`s and relation `add`s | raw item with new `id` | Changed 2026-10-12: `az rest --method post --url https://dev.azure.com/ORG/PROJECT/_apis/wit/workitems/$TYPE?api-version=7.1 --resource 499b84ac-1321-427f-aa17-267ca6975798 --headers Content-Type=application/json-patch+json --body PATCH`, with the project and type percent-encoded | VERIFIED 2026-10-12 on test Task #900392 through the write guard: one call with title, area, tags, the signed-in user as assignee and a parent link to #900390 returns the new item at `rev` 1 in `New`, with the tags, the assignee and the parent relation; #900390 gains the child link and stays at `rev` 1. Before 2026-10-12, VERIFIED on 3 test items through `az boards work-item create`, with the parent link a second call. Fixture: `tests/fixtures/az/work_item_create.json`. |
| `patch_work_item` | `{ id, patch }`: a JSON Patch applied whole or not at all | raw item with the new `rev` and `relations` | `az rest --method patch --url https://dev.azure.com/ORG/_apis/wit/workitems/N?api-version=7.1 --resource 499b84ac-1321-427f-aa17-267ca6975798 --headers Content-Type=application/json-patch+json --body PATCH` | VERIFIED 2026-10-12 on test items #900390 (User Story), #900391 (Task) and #900392 (Task) through the write guard (owner request "One write per work item", section 8). (1) One patch on #900391 with `test /rev` 1, title, state `Active`, tags `replace` on an item with no tags, the signed-in user as assignee and a parent relation `add` to #900390: all applied, `rev` 1 to 2 (one revision); #900390 gained the child link and stayed at `rev` 1. (2) The same patch again with the stale `test /rev` 1: HTTP 412, "VS403351: Test Operation for path /rev failed, value 2 was not equal to test value 1." (`TestPatchOperationFailedException`), and nothing changed; the transport reports it as a `conflict`. Fixture: `tests/fixtures/az/work_item_patch_test_failed.txt`. (3) `remove /relations/0`, the index from a read just before, with `test /rev`: removed the parent link on both ends; `rev` stayed 2, so a link change leaves `rev` as it was, through this route too. (4) A Task to User Story type change with state `Testing`, which Task lacks, in one patch: applied, `rev` 2 to 3. (5) Found in the check: `test /relations/0/url` works. With a URL other than the relation's, ADO refuses the patch with the same exception and removes nothing; with the URL exactly as the read returned it (it carries the project GUID, `.../example-org/<guid>/_apis/wit/workItems/N`), the removal goes ahead. The plugin tests each relation it removes this way. (6) The write guard refused, before any write, a patch adding a Related link to a pre-existing item ("title does not start with '[nvim-ado test]'") and a patch changing a type to Issue. (7) Through `core/apply.lua`: a save of 5 changes to 2 items (a parent removal and a tags change on #900392; a parent add, a type change with state and a retitle on #900391) made one patch per item; the cleanup save of 9 changes to 3 items made one patch per item. Each request costs 1 read by apply, 1 read by the guard per item it writes, and 1 write. The response carries `relations: null` when the item has none. Fixture: `tests/fixtures/az/work_item_patch.json`. Not checked: adding a Related link that already exists through this route; the plan never sends one for a link the views loaded. |
| `resolve_identity` | `{ text }` | `{ { display_name, unique_name, mail, id }... }` | `az rest --method post --url https://dev.azure.com/ORG/_apis/IdentityPicker/Identities?api-version=7.1-preview.1 --resource 499b84ac-1321-427f-aa17-267ca6975798 --headers Content-Type=application/json --body '{"query":TEXT,"identityTypes":["user"],"operationScopes":["ims"],"options":{"MinResults":10,"MaxResults":10},"properties":["DisplayName","SignInAddress","Mail","Active"]}'` | VERIFIED 2026-10-12, changed (PQ4). The people picker matches a prefix of a name or an email: the signed-in user's email, a 4-character prefix of it and a surname each returned 1 identity, a common first name 15 with the `ims` scope (20, the cap, with `ims` and `source`), and a made-up name 0. The `ims` scope keeps to identities the organisation knows; each has a `localId`. The result is `results[0].identities[]` with `displayName`, `signInAddress` (the unique name `--assigned-to` takes), `mail`, `localId` and `active`. Neither planned route works: `az devops invoke --area IdentityPicker` fails with "--area is not present in current organization", because az looks areas up in the organisation's `_apis/ResourceAreas`, which does not list it; and `--area IMS --resource Identities` with `searchFilter=General` or `DisplayName` matches whole names only (the full name or the email returned 1, a first name or surname alone 0). `az devops user list` was not tried. Fixture, redacted: `tests/fixtures/az/identity_picker.json`. |
| `add_comment` | `{ id, text }` | raw item | `az boards work-item update --id N --discussion TEXT` | Verified: in use |

Since 2026-10-12 a save writes each work item with one request: `patch_work_item` for an existing item, `create_work_item` for a new one with its parent link in the same call (owner request "One write per work item", section 8; `docs/architecture.md`, "Write requests"). Browser URLs need no transport: `core/urls.lua` builds them. The area-query URL form `https://dev.azure.com/ORG/PROJECT/_queries/query/?wiql=...` was checked 2026-10-12 without a browser, by requesting it with an access token: the page loads (HTTP 200) for URLs up to 3,053 characters and returns HTTP 404 from 3,061, so the plugin refuses to open one over 3,000. Whether the page runs the query as expected is left to the owner's phase 2 manual check.

Each phase that first uses an UNVERIFIED route starts with a route check: run the command by hand against ADO, save one redacted response as a fixture under `tests/fixtures/az/`, and shape the fake's output to match. Whether agents may run those commands is PQ1 in section 8.

### 4.2 Fake transport

`tests/support/fake_transport.lua`, vim-free, so it loads inside the sandbox.

- `Fake.new(seed)` builds in-memory items, areas, types and identities from `tests/fixtures/seed.lua`.
- It implements every operation in 4.1, evaluates query `spec` tables, bumps `rev` on each write, and stores links on both ends, bumping both revisions (assumption 4 in section 7). Changed 2026-10-12: links leave both revisions as they were, as in ADO; `patch_work_item` and `create_work_item` apply a JSON Patch whole or not at all, including a failed `test` op, which is a `conflict`, and relation removal by index.
- `fake.calls` records every call in order; `fake.writes` records only writes. Tests assert on both, for example "0 writes" for a rejected plan.
- `fake:fail_on(op, n, err)` makes the n-th call of `op` fail; `fake:edit_remotely(id, fields)` simulates another user's change (A0001-24).
- `fake.mode = "deferred"` queues callbacks until `fake:flush()`, so tests can check progress events and that the core does not depend on synchronous callbacks.

The seed starts from the spike's `fake.lua` data (11 items in areas `P/Team` and `A` to `D`, including two items titled "Same title" and one titled "A/B test rollout") and adds: types with categories, including `Discarded` in `Removed`; one state name that is open for one type and finished for another (A0002-2); Related links; two identities matching "Alex" (A0001-25).

### 4.3 What is reused from the spike

The spike core planned all 14 edit scenarios correctly from rows, with `vim` access forbidden. It is the starting point for `core/plan.lua`, not a finished module.

| Spike file | Use |
| --- | --- |
| `spike/lua/ado_spike/core.lua`, `M.plan` | Port into `core/plan.lua` in phases 4 and 5. Keep the algorithm: index snapshot and current rows by ID per view; collect removals and additions per relationship kind across all views; combine column edits per ID across views and reject conflicts; the `block_parent` rule for R5.8. Change: ops become records with `rev` and row references; notes and rejections become records `{ id, views, rule, message }` rather than strings; default types come from config, not a hard-coded `"Task"`; a create no longer sets `state = types[type][1]` (which errors on an unknown type) and leaves the initial state to ADO; add the `parent`, `link` and `self` view kinds, R5.12, R5.13, R5.21 and R5.22. |
| `M.summary` | Port into `core/summary.lua`, regrouped to R7.2. |
| `fake.lua` | Seed data and write semantics for the fake transport (4.2). |
| `core_check.lua` | Sandbox technique for `tests/support/sandbox.lua`. |
| Process blocking in `run.lua` | Copied into `tests/run.lua`. |
| Scenarios S1 to S16 (edit scenarios in `spike/run.lua`) and T1 to T3 (save tests in `spike/run_save.lua`: T1 cancel, T2 accept, T3 saving another oil buffer) | Become test cases: S3 is A0001-8, S5 is A0001-9, S6 is A0001-16, S8 is A0001-15, S2b is A0001-18, S12 is the state form of A0001-19, S13 (duplicate titles, slash) goes to `tests/nvim/lines_spec.lua`, S15 (expansion with unsaved edits) to `tests/nvim/expand_spec.lua`, S3 (cross-buffer move) to `tests/nvim/paste_spec.lua`, T1 to T3 to `tests/nvim/save_spec.lua`. |
| `rows.lua`, the oil adapter, `run_save.lua` | Not reused: they depend on oil internals (RFC Q4). |

Fetch the sources with `git show spike/oil-adapter:spike/lua/ado_spike/core.lua` from this repository.

### 4.4 Records the core plans with

Phase 4 creates these shapes; phases 5 and 6 add fields but do not change existing ones.

```lua
-- One view record per area view, and one per relationship slot of an item view (phase 5).
view = {
  key = "ado://item/1234#children",   -- buffer name plus slot; names the view in summaries
  kind = "area" | "self" | "parent" | "children" | "link",
  rel = "Project\\Team\\Sub" | 1234,  -- area path for "area"; item N for the others
  link_type = "System.LinkTypes.Related", -- "link" only
  snapshot = { row... },               -- rows displayed at last load (R5.5)
  current  = { row... },               -- rows parsed from the buffer now
}
row = {
  id = 1234 | nil,                     -- nil for a new line
  line = 7,                            -- buffer line, for rejections that name the row
  title, state, type, assignee, tags,  -- column text as displayed or edited
  rev = 12,                            -- snapshot rows only: rev at load (R5.14)
  block_parent = 1200 | nil,           -- ID of the expanded row this row is displayed under (R5.8)
}
op = { kind = "update" | "set_area" | "remove_link" | "add_link" | "set_parent" | "create",
       id = 1234, field = "System.State", from = "Active", to = "Resolved",
       expect_rev = 12, views = { "ado://area/P/Team" } }
note = { id = 1234, views = {...}, rule = "R5.4", message = "..." }   -- "no change" and warnings
rejection = { id = 1234 | nil, line = 7, views = {...}, rule = "R5.10", message = "..." }
plan = { ops = { op... }, notes = { note... }, rejections = { rejection... } }
```

`kind = "self"` is the item view's own row, which only takes column edits. Phase 4 uses `area`, `self` and `children`; phase 5 adds `parent` and `link`.

Some checks need data the rows do not hold: the ancestors of a new parent (R5.12, phase 5) and identities for assignee text (R5.19, phase 6). A **prepare step**, `plan.prepare(views, session, cb)`, fetches that data through the transport before `plan.compute(views, model, prepared)` runs. `compute` makes no transport calls, so a rejected plan has made no writes.

## 5. Test approach

No busted or luarocks is installed, so the plugin carries its own runner, run by Neovim's built-in LuaJIT through `nvim -l`.

- **Command.** `make test` runs `$(NVIM) --headless -u NONE -l tests/run.lua`, with `NVIM ?= nvim`. On the owner's machine: `make test NVIM=/path/to/nvim`. `make test-core` runs only the core suite. The runner exits non-zero on any failure.
- **Specs.** Each `*_spec.lua` file calls `test(name, fn)`; the runner supplies `test`, `eq(actual, expected)` (deep equality with a diff on failure), `ok(value, message)` and `fails(fn, pattern)` as globals. Async tests set a `done` flag in the callback and the helper fails the test if it stays unset after `fake:flush()`.
- **Core suite** (`tests/core/`). The sandbox loads each spec with an environment whose `__index` raises on `vim`, and gives it its own `require` that loads only `ado.core.*` from `lua/ado/core/` and `tests.*` from `tests/`, in the same environment. Any other `require` raises, so a core module that pulls in a presentation module fails its tests. As a backstop for code paths no test runs, the runner also scans `lua/ado/core/*.lua` for `vim%.` and `require%(["']ado%.nvim` and fails on a match.
- **Presentation suite** (`tests/nvim/`). Runs with the real `vim`, after prepending the repository to `runtimepath`, against a session built on the fake transport. It covers what the core cannot: line parsing and rendering, `BufWriteCmd`, cross-buffer paste, expansion with unsaved edits, and that saving another buffer leaves views alone (R6.8). The summary's accept/cancel goes through an injectable `confirm` function so tests can answer it.
- **No processes.** Before loading any spec the runner replaces `vim.system`, `vim.fn.system`, `vim.fn.jobstart`, `io.popen` and `os.execute` with functions that raise, as the spike did. No test can reach `az` or the network.

Each acceptance behaviour gets one core test named after it, for example `test("A0001-7 move child between parents is one parent change", ...)`, so `make test` output doubles as the RFC coverage list.

## 6. Phases

### Phase 0: Test harness and core/transport seam

**Delivers.** No change in behaviour. The pickers, the detail buffer and the field editors keep working, now through the transport. R6.3, R6.4, R6.6 and the start of R6.7.

**Modules.**
- Create `tests/run.lua`, `tests/support/sandbox.lua`, `tests/support/fake_transport.lua` (operations used today only), `tests/fixtures/seed.lua`, `Makefile`.
- Create `core/transport.lua`, `core/session.lua`, `core/query.lua`.
- Move `lua/ado/wiql.lua` to `core/wiql.lua`, rendering from query specs.
- Split `lua/ado/workitem.lua`: `normalise` goes to `core/workitem.lua`, taking `org` as a parameter instead of reading `config`; rendering, pandoc conversion and keymaps go to `nvim/detail.lua`.
- Turn `lua/ado/client.lua` into `nvim/az.lua`, implementing the 4.1 interface for `list_projects`, `query`, `get_work_item`, `update_fields`, `add_comment`. The `friendly_error` mapping becomes `err.kind = "auth"`.
- Move `picker.lua` and `float.lua` under `nvim/` unchanged except for `require` paths.
- Create `core/write_guard.lua`: wraps any transport and, when enabled, refuses a write before it starts unless the target item is in the allowed area path or its sub-areas (section 8, PQ1) and neither the item's current type nor its new type is `Issue`. Creates must target an allowed area and a type other than `Issue`. Agent-run route checks and manual tests MUST run with it enabled through `setup({ write_guard = { area = "...", deny_types = { "Issue" } } })`; it is off by default for the owner's normal use.

**Core tests.** `wiql_spec` (today's two queries render byte-identical WIQL, quote escaping), `workitem_spec` (normalise with and without `_links`, missing assignee), `sandbox_spec` (a fixture module that reads `vim` fails; one that requires `ado.nvim.az` fails), `fake_transport_spec` (calls recorded, `fail_on`, deferred mode), `write_guard_spec` (a write outside the area, to an `Issue`, or changing a type to `Issue` is refused with zero transport calls; reads pass through).

**Manual check.** With the dotfiles unchanged: `<leader>wm`, `<leader>ws`, `<leader>wo`, then in a detail buffer edit a title with `<CR>` and reload with `<leader>wr`.

**Exit criteria.** `make test` passes and the static scan finds nothing; the manual check behaves as on `main`; no file outside `lua/ado/nvim/` and `lua/ado/init.lua` / `config.lua` calls `vim`.

### Phase 1: Open-state filter (RFC 0002)

**Delivers.** R1.1 to R1.7. "My work items" shows only open items. Text search shows only open items, and `<C-a>` in the search picker re-runs it in every state (R1.4); `ado.search({ all_states = true })` does the same. The state picker in the detail buffer uses the type catalog, replacing `client.states` (R1.6).

**Modules.** Create `core/types.lua`: loads the catalog once per session through `work_item_types`, falls back to one `workitemtypestates` call per type when categories are missing, answers `is_open(type, state)`, `states(type)`, `open_condition(types?)`. Change `core/wiql.lua` (per-type state condition, R1.5), `core/session.lua` (catalog cache), `nvim/picker.lua` (toggle), `nvim/detail.lua` (state picker), `config.lua` (`open_categories`, R1.3). Add `work_item_types` to `nvim/az.lua` and the fake.

**Route check first.** Run the `workitemtypes` call by hand and confirm states carry `category`. If they do not, the per-type fallback becomes the main path, which costs one call per type the first time (assumption 2 in section 7).

Result, 2026-10-11: states carry `category` (assumption 2 holds), so the catalog costs 1 call per session. The real data has the case A0002-2 describes: `Resolved` is in the `Resolved` category for `Bug` and in `InProgress` for `Epic`. Three types (`Epic`, `Research`, `Requirement`) are disabled; the catalog keeps them, because existing items of a disabled type still need the open filter.

**Phase 1b, 2026-10-12: configured projects.** Delivers the owner decision "Configured projects" in section 8 (RFC 0002 R1.8, R1.9, A0002-4). Changes `core/query.lua` (`scope`: the project condition, with each project's open condition tied to it), `core/session.lua` (projects, one catalog per project, loaded lazily), `config.lua` (`projects`) and `nvim/session.lua`. The `az` transport now returns an empty list when `az boards query` prints nothing, which it does for a query with no results; before, that case was reported as "failed to parse az output". The real-data check is recorded below the phase 1 check.

Real-data check, 2026-10-11, reads only: "my work items" returned 65 items, all in an open state (200 of 945 in every state, after the `default_query_top` cap). The rendered WIQL is 2,316 characters. The check also found that `az boards query --project P` does not limit WIQL to project P: it searches the whole organisation. "My work items" is unaffected for the owner (all 945 results are in `Example`), but 523 of 1,162 all-states results for "bug" came from other projects (`Documents`, `Operations`, `Sandbox`, `Playground`). The catalog holds only the configured project's types. Items whose type the project lacks (`Risk`, `Request`, `Change`, ...) therefore never appear in the open search, and items of a shared type name (`Bug`, `Task`) are judged by this project's categories. Risk 9 in section 7 records the choice for the owner.

Real-data check for phase 1b, 2026-10-12, reads only, through the `az` transport with the write guard on and `projects` set to `Example` only. Open search for "bug": 200 items (the `default_query_top` cap), 0 from other projects, 0 in a state that `Example`'s catalog counts as finished. All-states search for "bug": 200 items, 0 from other projects (on 2026-10-11, 523 of 1,162 came from other projects). "My work items": 65 items, all in `Example`, all open. One catalog load: 23 types, 1 call.

**Core tests.** A0002-1, A0002-2, A0002-3; catalog loads once (second use makes 0 calls); per-type fallback when categories are missing; configured `open_categories`; state names with quotes; the condition restricted to a given type list.

**Manual check.** `<leader>wm` hides a `Resolved` item assigned to the owner; `<leader>ws` for a word in a closed item's title finds it only after `<C-a>`; `:messages` shows one catalog load per session.

**Exit criteria.** Tests pass and the manual check behaves as described. Owner sign-off, separate from the agent's gate: no finished item in "my work items" for a day of use.

### Phase 2: Read-only area view

**Delivers.** R2.1 to R2.9 (R2.7 opens the detail buffer in a split; the item view panel joins it in phase 3), R4.1 for area locations, R4.4 (reload; views are not editable yet), R4.5, R5.1 (every row carries a concealed row ID), R7.3 for loads, R8.1, R8.2, R8.3 (`area_view()`).

Rows render as `/<row id> <type> │ <state> │ <title> │ <assignee> │ <tags>` (owner decision 2026-10-12: title after state). In the item view, the viewed item is its title on one line followed by one line per field (`  type:`, `  state:`, `  assignee:`, `  tags:`), owner decision 2026-10-12; phase 4 edits a field by editing its line; sub-area rows as `/<row id> ▸ <name>/`. Parsing takes type and state from the first two separators and assignee and tags from the last two, so a title containing `│` or `/` needs no escaping. Buffers are `buftype=acwrite`, `modifiable=false` in this phase. The filter header is the window bar, so every buffer line is a row (R2.6). Buffer names follow `ado://area/<path with "/">?state=open&type=&assignee=&tag=&sub=0` (R4.5).

Default keys, all buffer-local, defined in `nvim/keymaps.lua`. The `<leader>w` keys follow the detail buffer's (`<leader>wb`, `<leader>wr`), and buffer-local keys take precedence over the global ones in section 9.

| Key | Where | Action | Phase |
| --- | --- | --- | --- |
| `<CR>` | both views | select: navigate, or open an item (R2.3, R2.7, R3.2, R3.3) | 2 |
| `-` | area view | parent area (R2.9) | 2 |
| `[h` / `]h` | both views | history back / forward (R4.1) | 2 |
| `<leader>wf` | area view | choose filters (R2.4) | 2 |
| `<leader>wu` | area view | sub-area toggle (R2.5) | 2 |
| `<leader>wb` | both views | open the view's query, or the item under the cursor, in the browser (R2.8, R3.6) | 2, 3 |
| `<leader>wr` | both views | reload (R4.4) | 2 |
| `<Tab>` | item view | expand or collapse a child (R3.4) | 3 |
| `K` | item view | preview in the detail split (R3.5) | 3 |
| `gd` | item view | open in the detail buffer (R3.5) | 3 |
| `<leader>wt` | item view | all-states toggle (R3.8) | 3 |
| `<leader>wi` | detail buffer | open the item view for this item (R3.7) | 3 |

**Modules.** Create `core/area_path.lua` (ADO's `Project\Team\Sub`, the classification node form `\Project\Area\Team\Sub`, and the `/` form used in URIs and `area_paths`; config accepts `\` and `/`), `core/location.lua`, `core/history.lua`, `core/area_view.lua` (2 calls per load: `area_children` and `query`; the catalog is cached), `core/urls.lua`; `nvim/lines.lua`, `nvim/registry.lua`, `nvim/view_buffer.lua`, `nvim/area_view.lua`, `nvim/layout.lua`, `nvim/keymaps.lua`, `nvim/progress.lua`; `init.lua` (`area_view(path?)`), `config.lua` (`area_paths`, `area_filters`). Add `area_children` to the transport and fake.

The row ID registry maps a session-wide counter to `{ kind, item id or area path, view, snapshot row }`. Two rows for the same item get different row IDs, which lets phase 5 tell a paste from the original. This follows the spike's recommendation over using the work item ID as the prefix, because sub-area and fixed rows need IDs too.

**Route check first.** `area_children` (path form and output shape) and the browser query URL.

Result, 2026-10-12: see the `query` and `area_children` rows and the browser URL paragraph in section 4.1. Assumption 3 holds: node paths convert to field paths by dropping the second segment, `Area`, in both projects checked.

What was built differs from the text above in these ways, each low risk:

- Sub-areas are sorted by name, case-insensitive; ADO returns them in its own order.
- Items are ordered newest change first, as in the other lists.
- An area view is scoped to the project its path names (`[System.TeamProject] IN ('P')`), and judges open states by that project's catalog, whether or not the project is in `projects`.
- The browser query limits the open condition to the types of the loaded items, which returns the same items as of the load and keeps the URL short. A truncated view keeps the condition for every type. To make that fit, the open condition now shares one clause between types with the same open states: on `Example` the "my work items" WIQL went from 2,316 to 1,692 characters (13 clauses for 23 types). A URL over 3,000 characters is refused with a warning rather than opened.
- `:w` in a view saves nothing and says the view is read-only (`buftype=acwrite` needs a `BufWriteCmd`).
- The filter keys are `state` (`open`, `all` or state names), `assignee` (`@Me` or a name or email), `types` and `tag` (one whole tag). Tags match whole, because that is what ADO's `CONTAINS` does on `System.Tags`.

Real-data check, 2026-10-12, reads only, through the `az` transport with the write guard on and `projects` set to `Example`. Item titles were not printed and no browser was opened.

| View | Sub-areas | Items |
| --- | --- | --- |
| Team A, open | 0 | 8 |
| Team A, open, with sub-areas | 0 | 8 |
| Team A, open, `@Me` | 0 | 5 |
| Team A, open, type `Task` | 0 | 2 |
| Team A, all states | 0 | 12 |
| Team A, all states, with sub-areas | 0 | 12 |
| Platform, open | 5 | 200 of 470 (truncated) |
| Platform, open, with sub-areas | 5 | 200 of 1,179 (truncated; `az` stopped near 1,000) |

Team A has no sub-areas, so the toggle cannot change its counts; its parent `Platform` shows the 5 sub-areas (Backlog, Team C, Team A, "Team B, North", Team D) listed before its items. The all-states count, 12, matches a hand-written WIQL query for the area run the same day. Browser URLs were built for three views: 1,125 characters (Team A, open), 2,715 and 2,717 (the two truncated `Platform` views). The catalog loaded once, 23 types in 1 call.

**Core tests.** A0001-1, A0001-2, A0001-3; WIQL for each filter (state open / all / names, `@Me` and named assignee, type list, tag `CONTAINS`) with `=` and `UNDER` (R2.5); area path conversions both ways; location URI round trip; history back and forward, and forward cleared by a new navigation; parent area of a top-level path is none; results beyond the existing `default_query_top` setting (200) set a `truncated` flag on the view. Presentation: `lines_spec` renders and parses rows, including the spike's duplicate titles and slash (S13).

**Manual check.** Open the view from the picker on each configured path; enter a sub-area and see filters carried; `-` back up; set assignee to `@Me`; toggle sub-areas and compare counts with the ADO web UI; `<leader>wb` opens the same query in the browser; `<CR>` on an item opens its detail buffer in a split with the area view still open.

**Exit criteria.** Tests pass; on one configured area the item counts match the ADO web UI for 3 filter combinations (open with any assignee; open with `@Me`; all states with sub-areas on); the window bar shows the active filters.

### Phase 3: Read-only item view

**Delivers.** R3.1 to R3.8, R4.1 shared across both views, R4.2, R4.3, R2.7 completed, R8.3 (`item_view(id)`), R8.5 (`link_types`, default parent, child and Related, RFC Q6).

The buffer holds, in order: the item's own row, a parent row, an area row, a children section, then one section per link type, each section starting with a fixed heading row. Children and links follow the open-state filter, applied client-side so the all-states toggle (`<leader>wt`) needs no refetch; the parent row always shows (R3.8). A load costs 2 calls: `get_work_item` with relations for N, then one `query` with `[System.Id] IN (...)` for every related ID.

`<Tab>` on a child row expands or collapses it (R3.4). Expansion costs 1 call (`query_children`) and inserts the child rows beneath, marked with `block_parent`; collapse costs none. Expansion inserts lines into the buffer rather than redrawing it, so phase 4 can keep unsaved edits through it. `K` previews the item under the cursor in the detail split without moving the cursor (R3.5); `gd` opens it in the detail buffer. `<leader>wi` in a detail buffer opens the item view for that item (R3.7).

`nvim/layout.lua` keeps three windows (R4.2): the area view, the detail split beside it, and the item view as a side panel, about 60 columns, beside the detail split. It reuses each window when it is still valid. Moving the cursor in the item view changes nothing else (R4.3).

**Modules.** Create `core/item_view.lua`, `nvim/item_view.lua`; change `core/workitem.lua` (relations: `System.LinkTypes.Hierarchy-Reverse` is the parent, `-Forward` a child, the target ID is the tail of `url`), `core/location.lua`, `nvim/layout.lua`, `nvim/detail.lua`, `init.lua`, `config.lua`. Add `query_children` to the transport and fake.

**Route check first.** `show --expand relations`, `[System.Id] IN`, `[System.Parent]`.

Result, 2026-10-12: see the `query`, `get_work_item` and `query_children` rows in section 4.1. Assumption 5 holds: expansion is 1 call.

What was built differs from the text above in these ways, each low risk:

- No `query_children` transport operation: expansion is a `query` with `[System.Parent] = N` (section 4.1). The fake now gives each seed item a `System.Parent` field; phase 5 must keep it in step when it changes links.
- Rows, in order: the item's own row (labelled "this item" after the line end), the parent row (labelled "parent"), or a fixed row `Parent: none` when there is none, the area row (`▸ <area path>/`), then a heading row per section (`── Children: 2 open of 3`, `── Related: 1`), each followed by its rows. Labels are virtual text, so the line text stays in the row format. A heading says how many rows the open filter hides and how many linked IDs ADO did not return ("1 not readable").
- Children and links are ordered by ID, so rows keep their place between loads; ADO's backlog order is not used.
- An item location is `{ id, all }`. Its buffer is `ado://item/<id>` for both values of `all`, because the toggle filters rows already loaded; the history records the toggle as a step. The toggle keeps expansions; going back or forward to an item shows it collapsed, as the RFC's Location rule says.
- Selecting a parent, child or link carries the all-states toggle to that item, as sub-areas carry filters (R2.3). Selecting also updates the detail split when one is open (R4.3: the detail changes on select or preview); it does not create one. `<CR>` on the item's own row opens it in the detail split.
- `link_types` always shows the parent and children (R3.1 makes them MUST); `System.LinkTypes.Hierarchy` in the list has no further effect. Each other type gets one section per link end (`-Forward`, `-Reverse`), named by ADO's link name.
- Open states for linked items are judged by each item's own project's catalog, loaded on first need; in practice all of them are in `Example`, so 1 call per session.
- The layout reuses a window only while it is in the current tab and still shows a buffer of its role; a window the user put another buffer in is left alone and a new split is made. Selecting an item in the area view leaves the cursor in the item panel. With no area window, selecting the area row opens one left of the detail split or panel.
- `<CR>` on an item in the area view now opens both the detail split and the item panel (R4.2), so the phase 2 test for a two-window layout became `tests/nvim/layout_spec.lua`.

Real-data check, 2026-10-12, reads only, through the `az` transport with the write guard on and `projects` set to `Example`. The transport counted every call; no write was attempted, no title was printed and no browser was opened. The items are in `Example\Software\Platform\Team A`, found with a read query (12 items in the area in every state).

| Item | Load calls | Parent | Children open / all | Related open / all | Expansion |
| --- | --- | --- | --- | --- | --- |
| A Feature | 3 (`get_work_item`, `query`, catalog) | none | 1 / 3 | 0 / 0 | its User Story child: 1 call, 3 rows (all states shown), collapse 0 calls; a closed Task child: 1 call, 0 rows |
| That User Story | 3 | shown | 2 / 3 | 0 / 0 | each of its 3 Task children: 1 call, 0 rows |
| One of its Tasks | 3 | shown | 0 / 0 | 2 / 2 | none |

The `<leader>wt` toggle made 0 calls in each case. The catalog call is the session's first; a second view in the same session costs 2.

**Core tests.** A0001-4, A0001-5; R3.1 row order; parent shown when its state is finished; children filtered by default and all shown with the toggle; expansion makes exactly 1 call and collapse 0; a location going back is collapsed (RFC section 4, Location); link types limited to `link_types`. Presentation: `expand_spec` inserts child rows under the right row and collapse removes only them; `layout_spec` reuses the three windows on a second selection.

**Manual check.** From an area view select a User Story: three windows appear; walk to a child and back with `[h`; expand a child with children; `<leader>wt` shows a closed child; `K` updates the detail split with focus kept; select the area row and land in the area view with default filters.

**Exit criteria.** Tests pass; the owner can walk a Feature to its Tasks and back without the web UI.

### Phase 4: Column edits and the save pipeline

**Delivers.** Title and state edits on any work item row in either view, saved with `:w`. R5.1 to R5.3, R5.7, R5.10 (column conflicts), R5.13, R5.14, R5.15, R5.16, R5.17 (title and state), R6.2, R6.8, R7.1 to R7.4, R4.4 (reload with unsaved edits asks first).

Views become modifiable. `:w` in any view collects every modified view buffer (R5.2), turns each into a view record (section 4.4) with `nvim/lines.lua` and the registry, and passes them to `core/plan.lua`. Any row added, removed, or edited in the assignee, tags or type column produces a rejection saying that edit is not supported yet, so nothing is ignored silently. Edits on sub-area rows are rejected (R5.16).

The summary float (R5.3, R7.2) lists the groups that exist in this phase (state and title changes, warnings such as R5.13, rejections); `y` applies, `n` or `q` cancels and leaves every buffer as edited. With any rejection, only cancel is offered.

`core/apply.lua` runs ops in order, one at a time:

- **Revision guard (R5.14).** Before the first op on an item, `get_work_item` reads its `rev` and compares it with the snapshot rev of the view where the edit was made. A mismatch fails that op. Later ops on the same item use the rev returned by the previous write, so the plan's own writes do not trip the guard. If two views hold different snapshot revs for one edited item, the plan rejects and asks for a reload.
- **Partial failure (R5.15).** The first failure stops the run. The report lists completed, failed and not-attempted ops; `nvim/save.lua` then reloads every view whose snapshot or relationship mentions a touched item.
- **Audit log (R7.4).** `apply` emits one event per op with time, op, work item ID, from and to values, and result. `nvim/audit.lua` appends each as one JSON line to `stdpath("state")/ado-workitems/audit.log`.
- **Progress (R7.3).** "Saving 2/5: #101 state" in the command line.

A save is blocked while any view is loading or expanding. Expanding a row in a modified view inserts the child rows and records them in the snapshot, and keeps the edits and the modified flag (R6.8).

**Modules.** Create `core/plan.lua` (column edits only, ported from the spike per 4.3), `core/summary.lua`, `core/apply.lua`, `nvim/save.lua`, `nvim/summary_ui.lua`, `nvim/audit.lua`; change `nvim/view_buffer.lua` (`BufWriteCmd`, modified tracking), `nvim/item_view.lua` (expansion into a modified buffer), `config.lua` (`audit_log`).

**Core tests.** A0001-18, 19, 20, 23, 24; the same title edit in two views makes one op; a removed or added row is rejected as not supported; a sub-area rename is rejected; two ops on one item read the guard once; a rejected plan makes 0 transport calls; every applied or failed op produces one audit event. Presentation: cancel makes 0 writes and keeps buffers modified (spike T1); accept makes 1 write and reloads unmodified (T2); writing an ordinary file while a view has unsaved edits leaves the view modified and unchanged (the oil failure, T3); expansion keeps an unsaved state edit (S15); reload with edits prompts.

Route check, 2026-10-12: see the `update_fields` row in section 4.1. Title and state updates and the revision guard behave as this phase assumed.

What was built differs from the text above in these ways, each low risk:

- An item view is one view record, not one per slot: each row carries its slot (`self`, `parent`, `child`, `link`), and the open-state filter applies to child and link rows only. Phase 5 splits it by slot when moves need it. Title and state edits work on every item row, including the parent and link rows, not only `self` and children.
- The item view's own item is a title line plus field lines (owner decision 2026-10-12). Editing the title line edits the title; editing the `state:` line edits the state. Editing the `type:`, `assignee:` or `tags:` line rejects the save with "the type line is not editable yet; only the title and the state can be edited" until phase 6.
- Every structural edit rejects the save with a line saying it is not supported yet: a deleted line, a new line, a pasted or copied row, and rows moved within a view. So does a row whose `│` separators were removed, an edited heading, area row or sub-area row (R5.16), an empty title, and an edit of the type, assignee or tags column. Blank lines are ignored.
- Expansion with unsaved edits (owner's safest-behaviour decision, delegated to this phase): `<Tab>` (expand and collapse) and `<leader>wt` are refused with a message while the item view has unsaved edits, and the edits stay. Inserting rows into an edited buffer would rely on line positions the edits may have moved, and a collapse would delete lines that may hold edits. An expansion made before editing is part of the snapshot, so its rows save like any other.
- Going back or forward to an item view with unsaved edits shows the buffer as edited, expansions included, rather than collapsed.
- Views cannot be edited while they load, while a row expands, or while a save applies. Loads and expansions stay out of the undo history, so `u` cannot undo a load.
- State text matches the type's states without regard to case, and the plan sends the catalog's spelling. Restating the current state is listed as "no change".
- After a save, the views that show an item the save touched reload, and on full success so does every saved view. After a failure, a saved view that shows no touched item keeps its edits, so its not-attempted changes can be saved again.
- The audit event's time is added by `nvim/audit.lua` when it writes the line, not by `core/apply.lua`.
- The report of a failed op repeats the message only for a revision conflict; other failures were already reported by the transport's error notifier (docs/architecture.md, Layers).

Real-data check, 2026-10-12, through the plugin in headless Neovim with the `az` transport and the write guard on, `projects` set to `Example`. The test items were two Tasks created for it in `Example\Software\Platform\Team A`, #900033 and #900034, titled `[nvim-ado test] ...`; no other item was written and no other title was printed.

| Step | Result |
| --- | --- |
| Area view of Team A: retitle #900033, set #900034 from `New` to `Active`, `:w`, accept | Summary listed 2 changes; 2 `update_fields` calls; read back: #900033 has the new title (rev 2 to 3), #900034 is `Active` (rev 3 to 4); the view reloaded unmodified; the audit log gained 2 lines with `result: ok` and the new revs |
| Retitle #900033 again, `:w`, cancel | 0 `update_fields` calls; rev and title unchanged in ADO; the buffer stayed modified |
| Reload, retitle #900033 through the guarded transport (as another user would), retitle it in the view, `:w`, accept | 0 `update_fields` calls from the save; the report said "Save stopped: 0 completed, 1 failed, 0 not attempted" with "#900033 changed remotely (rev 3 -> 4)"; ADO kept the other change; the view reloaded and shows it; the audit log gained 1 line with `result: failed` |

Afterwards both test items were set to `Closed` through the guarded transport.

**Manual check.** Retitle one Task in an area view and set another's state in an item view, `:w`, read the summary, accept; confirm both in ADO and in the audit log. Change an item in the web UI after loading it, edit it in the view, save: the op fails with the guard message and the view reloads.

**Exit criteria.** Tests pass and both manual checks behave as described. Owner sign-off, separate from the agent's gate: a week of title and state changes made through the views, with every audit log line matching a change the owner confirmed.

### Phase 5: Structural edits

**Delivers.** Every row of the R5 table except column edits already done: delete, paste with original kept, move, and new lines, in area views, child lists, the parent row and link sections. R5.4 to R5.6, R5.8 to R5.12, R5.18, R5.21 for new lines, R8.4, R8.6.

Copies carry the original's tags, as R5.6 requires. Text typed in the assignee or tags column of a new line is rejected as not supported yet, until phase 6.

Each item view is passed to the core as several views, one per relationship slot: `self` (N's own row, column edits only), `parent` (rel N), `children` (rel N) and one `link` view per link type (rel N). The area row is read-only; pasting onto it is rejected, because only area views change area paths (R5.11). Lines without a row ID are new lines; a line with fewer than four `│` separators is all title, so typing a title on an empty line works. A line whose row ID is not in the registry is rejected with its line number.

Ops run in this order, as in the spike: link removals, parent changes (`remove_link` then `add_link`), link additions, area changes, field updates, creates (each followed by its `add_link` to a parent). A copy (R5.6) is `create_work_item` with title, type and tags, plus the area and parent the R5.6 rule gives it; its state is left to ADO's initial state. Cycle checks (R5.12) need the new parent's ancestors: a prepare step before planning fetches them with `get_work_item`, one call per level, stopping at the root or at an item already loaded. The summary gains link removals, link additions, parent and area changes, copies and creates, and "no change" lines; link removals and copies are highlighted (R7.2).

**Modules.** Change `core/plan.lua` (removal and addition slots across views, block rule, R5.9 to R5.12; the rest of the spike algorithm), `core/summary.lua`, `core/apply.lua` (new op kinds), `nvim/lines.lua` (new lines), `nvim/item_view.lua` (sections to views), `config.lua` (`default_types`; the types per project come from `projects`, phase 1b). Add `add_link`, `remove_link`, `create_work_item` to the transport and fake.

**Route check first.** `relation add`, `relation remove`, `work-item create`, `--area` on update, on throwaway items (PQ1); and whether a link bumps both items' revisions (assumption 4).

**Core tests.** A0001-6 to 17, 21, 22 (asserting 0 writes), 27; a pasted copy's displayed descendants are dropped with a summary note (R5.8); a new line with a type outside its project's `types` rejects and names the row (R5.18); a new line in an area view uses `default_types.area`; a parent change whose `add_link` fails reports the item as having lost its parent. Presentation: a line yanked from one view and pasted in another keeps its identity (spike S3); undoing an expansion shows link removals in the summary rather than applying them (risk 3 in section 7).

Route check, 2026-10-12: see the `add_link`, `remove_link`, `create_work_item` and `update_fields` rows in section 4.1. Assumption 4 changed: a link leaves both items' `rev` as it was.

What was built differs from the text above in these ways, each low risk:

- An item view is still one view record. The core finds each row's relationship from its position: the item's own lines, the parent row, the area row, the Children heading and each link heading mark where a relationship's rows start. Deleting or moving one of those fixed lines rejects the save, as does deleting a sub-area row (R5.16). The effect is the per-slot split described above, without the presentation layer building several records.
- Reordering rows within one relationship is no change; phase 4 rejected it.
- The revision guard reads every item an op writes before the plan's first write to it, when the plan holds a snapshot rev for that item, so a link target with its own later edit is checked before the link changes it.
- Links other than parent and child are planned from the viewed item's end, with the section's display name, because `az` takes display names. Deleting the same link from both of its ends in one save is one removal; pasting an item into a link section that already holds it (hidden by the state filter) is "no change".
- A pasted row that moves an item carries its title and state edits to that item. A pasted row that becomes a copy gives the copy an edited title; a state edit on it is rejected, because a copy starts in its type's initial state.
- A copy keeps the original's type even when that type is not in the project's `types`; only new lines are checked against `types` (R5.18). Without configured `types`, new lines may use any type in the project's catalog. Superseded 2026-10-12 by the owner decisions "Copies of excluded types" and "Projects without types" in section 8.
- A new line with text in the state, assignee or tags column is rejected: the state because a new item starts in its type's initial state, the other two until phase 6.
- Rows carry `System.Parent` (added to the row query) and their area, so copies and the cycle check need no extra call; the cycle check reads an ancestor only when no loaded row shows its parent, one `get_work_item` per level.
- A save whose plan has nothing to send (for example a row deleted from an area view only, R5.4) reloads the saved views, so the deleted row shows again; phase 4 cleared the modified flag without a reload.
- The write guard gained an optional `title_prefix`: with it set, writes reach only items whose title starts with it, and creates and retitles must keep it. Agent-run checks set it to `[nvim-ado test]`, so a test run cannot write to an item it did not create.

Real-data check, 2026-10-12, through the plugin's views in headless Neovim with the `az` transport and the write guard on (`area` Team A, `deny_types = { "Issue" }`, `title_prefix = "[nvim-ado test]"`), `projects` set to `Example`. The test items were five items created for phase 5 in `Example\Software\Platform\Team A`: User Stories #900043 and #900044 and Task #900045, created in the route check with #900045 under #900043, and #900052 and #900053, created by the steps below. No other item was written and no other title was printed.

| Step | Result |
| --- | --- |
| Item view of #900043: a titled new line under Children, `:w`, accept | Summary "New items"; 2 writes (`create_work_item`, `add_link`); read back: #900052, a Task in state `New`, parent #900043, in Team A |
| `dd` #900045 in #900043's item view, `p` under Children in #900044's item view, `:w`, accept | Summary "Parent and area changes"; 2 writes (`remove_link`, `add_link`, plan 0001 PQ2); read back: #900045's parent is #900044, and #900043's only child is #900052 |
| Area view of Team A: `yy` #900043, `p` at the end, `:w`, accept | Summary "Copies: check these"; 1 write (`create_work_item`); read back: #900053 has the original's title, type (User Story) and tag, the same area, no parent, no assignee, no links, state `New` |
| Area view: `dd` #900053, `:w` | No summary to accept; 0 writes; the message reads "Nothing to save" and lists #900053 as no change; the view reloaded unmodified with the row back; read back: area unchanged |
| Item view of #900043: `dd` #900052, `:w`, accept | Summary "Link removals: check these"; 1 write (`remove_link`); read back: #900052 has no parent, state unchanged |

The audit log gained 4 lines, all `result: ok`. Afterwards the remaining link (#900045 under #900044) was removed and all five test items were set to `Closed` through the guarded transport; each has 0 work item links.

**Manual check.** On throwaway items: move a Task between two User Stories across two item views; copy an item into another area; delete a child row; add three new lines under a Feature; try a cycle and see it rejected; delete a row from an area view only and see "no change"; check each result in ADO and the audit log, and that link removals and copies stand out in the summary float.

**Exit criteria.** Tests pass; the owner reorganises one real backlog area through the views and the audit log matches the summary.

### Phase 6: Remaining columns

**Delivers.** Assignee, tags and type editable on existing rows, and assignee and tags on new lines. R5.17 complete, R5.19, R5.20, R5.21 for existing items, R5.22.

- **Assignee.** A prepare step before planning sends each changed assignee text to `resolve_identity`. Exactly one match resolves; none or several reject the save and name the row (R5.19). An empty column unassigns.
- **Tags.** The column holds `;`-separated tags. The plan compares sets and the summary lists tags added and removed (R5.20).
- **Type.** Matched against `types` without regard to case (R5.21); no match is "no change" with the reason. A type change whose current state is not valid for the new type, and whose row sets no valid state, is rejected (R5.22). Type changes get their own highlighted summary group.

**Modules.** Change `core/plan.lua`, `core/summary.lua`, `core/apply.lua`; add `resolve_identity` and the type field to `nvim/az.lua` and the fake.

**Route check first.** Identity search (PQ4) and type change through `update` (PQ3), on a throwaway item.

**Core tests.** A0001-25, 26, 28, 29, 30; an unknown assignee rejects; clearing the assignee makes one update; the identity lookup runs before the summary is built (0 writes when it rejects).

Route check, 2026-10-12: see the `resolve_identity` and `update_fields` rows in section 4.1. PQ3 and PQ4 hold, through other commands than planned: identity search runs through `az rest` on the people picker, and tag updates through an `az rest` patch, because `work-item update` cannot remove a tag. All three columns ship editable.

What was built differs from the text above in these ways, each low risk:

- The assignee rule: a text equal to one identity's display name, email or mail picks it, even when it also starts other names ("Alex Smith" beside "Alex Smithson"); otherwise exactly one match resolves. A rejection for several matches lists up to 5 of them, so the user can type more. Restating the current assignee is "no change". The write sends the identity's unique name.
- Tags compare as a set without regard to case, so reordering, repeating or recasing them is no change. The summary line reads `#N tags: added 'x'; removed 'y'`.
- A type change and a state edit on the same row are one call (op `set_type`, with the state), because each order of two calls fails when each value is valid only with the other. A state edit with a type outside the set is checked against the current type. Without configured `types`, a type change may use any type in the project's catalog, as new lines may since phase 5 (superseded 2026-10-12 by the owner decision "Projects without types" in section 8).
- The summary group "State and title changes" is now "Field changes" (title, state, assignee, tags). Type changes come before it, in "Type changes: check these, ADO drops fields the new type does not have", highlighted like copies.
- A copied row with an edited type, assignee or tags is rejected, as a state edit on it already was: a copy takes the original's type and tags and no assignee (R5.6). New lines take an assignee and tags.
- R5.13 (a phase 5 gap): the warning that an item will not appear after reload now covers moves, new links, copies and creates as well as field edits, against every filter of the destination view (state, type, assignee and tag) with the item's values after the save. A copy or create is judged in its type's first catalog state, which is the initial state ADO gave every item created in the phase 5 check. For an `@Me` view the plan knows the user's display name only from the rows that view shows: an item arriving with another assignee is warned about when the view shows at least one row, and an unassigned one always.
- The audit log records `state_from` and `state_to` for a type change, and the assignee and tags of a create.

Real-data check, 2026-10-12, through the plugin's views in headless Neovim with the `az` transport and the write guard on (`area` Team A, `deny_types = { "Issue" }`, `title_prefix = "[nvim-ado test]"`), `projects` set to `Example` with the owner's types. The only test item was Task #900058, created for the route check; no other item was written. Identity results were counted, never printed.

| Step | Result |
| --- | --- |
| Area view: assignee column set to the signed-in user's email, `:w`, accept | 1 `update_fields`; read back from ADO's history: rev 12 assigned to the signed-in user |
| Assignee column cleared, `:w`, accept | 1 `update_fields`; rev 13 unassigned |
| Tags column `nvim-ado-p6x; nvim-ado-p6y`, then `nvim-ado-p6y; nvim-ado-p6z` | 1 `update_fields` each; the second summary read `#900058 tags: added 'nvim-ado-p6z'; removed 'nvim-ado-p6x'`; read back `nvim-ado-p6y; nvim-ado-p6z` at rev 15 |
| Type column `user story` | Summary group "Type changes: check these, ...", line `#900058 type: Task -> User Story`; 1 `update_fields`; read back User Story, state New, rev 16 |
| Type column `Epic` | "Nothing to save", listed as no change: "type 'Epic' is not one of the types of project Example (...), so the type stays User Story"; 0 writes; rev unchanged |
| Item view: `type:` line `Task` | 1 `update_fields`; read back Task, state New, rev 17 |

The audit log gained 6 lines, all `result: ok`. The route check also tried a change to `Issue` through the guarded transport: the guard refused it before any call. Afterwards #900058's tags and assignee were cleared and it was set to `Closed`.

**Manual check.** Assign two items to a colleague by partial name, and see a name that matches two people rejected; retag three items and read the added and removed tags in the summary; change a Task in state `Removed` to a Bug and see it rejected, then set the state in the same save and see one type change; try `Epic` and see "no change"; move a closed item into an open-only view and see the warning that it will not appear.

**Exit criteria.** Tests pass; every acceptance behaviour in both RFCs has a named passing test.

## 7. Risks and assumptions

"High" marks an entry that changes scope or can lose data; those need the owner's answer in section 8 before the phase starts.

| ID | Assumption or risk | What goes wrong if wrong | How the plan finds out early | Level | Phase |
| --- | --- | --- | --- | --- | --- |
| Assumption 1 | The UNVERIFIED `az` routes in 4.1 work as written. | A phase stalls, or a route needs `az devops invoke` with a hand-built body. | A route check opens each phase, before any core code depends on the route's output. | Medium; high for PQ3 and PQ4 | 1 to 6 |
| Assumption 2 | The work item types list returns states with categories (RFC 0002 A1). | First load costs one call per type. | Phase 1 route check; the fallback is built and tested either way. | Low | 1 |
| Assumption 3 | Area paths convert cleanly between `\Project\Area\Team`, `Project\Team` and `Project/Team`. | Sub-areas fail to load or area moves write a wrong path. | Phase 2 route check saves a real response as a fixture for `area_path_spec`. | Medium | 2 |
| Assumption 4 | Adding or removing a link bumps the revision of both items. | Without the per-item guard rule, the second op on a link target would fail the guard. | Phase 4 guards once per item and tracks returned revs; the phase 5 route check confirms the behaviour and the fake mirrors it. Changed 2026-10-12: a link changes neither item's `rev` (section 4.1, `add_link`), and the fake now mirrors that. The guard rule in phase 5 still checks a link target before its first write, so it holds either way. | Closed | 4, 5 |
| Assumption 5 | WIQL accepts `[System.Parent]` and `[System.Id] IN (...)`. | Expansion costs 2 calls instead of 1. | Phase 3 route check; fallback in 4.1. | Low | 3 |
| Assumption 6 | The per-type open-state condition stays under ADO's WIQL length limit (32,000 characters, from ADO documentation, not measured here). | Queries fail for projects with many types and states. | A phase 1 test asserts the condition length for the seed, and `nvim/az.lua` writes a warning to `:messages` when a query exceeds 16,000 characters; the condition can be limited to the type filter or the configured `types`. | Low | 1 |
| Risk 1 | A parent change is two calls, `remove_link` then `add_link`. | If the second fails, the item is left without a parent. | R5.15 report and the audit log name the item and its old parent; tested with `fail_on`. PQ2 asks whether that is acceptable. Closed 2026-10-12: a parent change is one patch on the child, so a failure leaves the old parent (owner request "One write per work item", section 8). | Closed | 5 |
| Risk 2 | The revision guard reads then writes, so a change made in ADO between the read and the write is overwritten. The RFC defines the guard this way, and the window is one `az` call. | A concurrent edit in that window is lost. | Accepted as specified. An atomic `test /rev` patch through `az devops invoke` is a later improvement. Closed 2026-10-12 for saves: each save request starts with `test /rev` and tests each relation it removes, so ADO refuses it whole after a remote change (section 4.1, `patch_work_item`). Closed 2026-10-13 for the detail buffer and the picker's state change: each edit is one patch led by `test /rev` (section 8). Comments carry no rev check, since they only append. | Closed | 4 |
| Risk 3 | Undo after an expansion removes the expanded rows, which the plan reads as deleted descendants, so link removals. | A user who undoes past an expansion could remove links. | Link removals are highlighted in the summary and need confirmation (R7.1); a presentation test covers it. | Medium | 5 |
| Risk 4 | Own buffer handling (registry, line parsing, `BufWriteCmd`, expansion into modified buffers) is larger than the spike measured. | Phases 2 to 5 take longer. | Phase 2 builds the read-only half first; its size is the estimate for the rest. | Low | 2 to 5 |
| Risk 5 | Area views cap at the existing `default_query_top` setting in `config.lua` (200 items). | Large areas show partial lists. | The view flags truncation in the window bar; hidden rows are not in the snapshot, so they cannot be deleted (R5.5). The phase 2 check found `Platform` at 470 open items, so a parent area truncates at the default. | Low | 2 |
| Risk 6 | The fake transport behaves differently from ADO. | Tests pass while the plugin fails on real data. | Fixtures under `tests/fixtures/az/` come from real responses; every phase ends with a manual check on ADO. | Medium | all |
| Risk 7 | Type change through `az boards work-item update` is not allowed, or drops fields beyond what R5.22 expects. | R5.21 and R5.22 cannot ship as written. | Phase 6 route check on a throwaway item; PQ3 decides the fallback. Closed 2026-10-12: the route works (section 4.1, `update_fields`). Which fields ADO drops was not measured; the summary warns. | Closed | 6 |
| Risk 8 | No identity search route works with the owner's permissions. | R5.19 cannot resolve partial names. | Phase 6 route check; PQ4 decides the fallback. Closed 2026-10-12: the people picker through `az rest` works (section 4.1, `resolve_identity`). | Closed | 6 |
| Risk 9 | WIQL through `az boards query` covers the whole organisation, while the type catalog covers one project (found in the phase 1 real-data check). | The open search hides other projects' items of types the project lacks, and judges shared type names by this project's categories. The all-states toggle still finds them. | Closed 2026-10-12 by the owner decision "Configured projects" in section 8: lists are limited to the configured projects, and each project has its own catalog (RFC 0002 R1.8, R1.9). Checked on real data the same day (phase 1b below). | Closed | 1 |

Decisions this plan makes, each low risk and reversible: the key bindings in phases 2 and 3; the row line format; session row IDs rather than work item IDs as the concealed prefix; the audit log location and JSON-lines format; copies take ADO's initial state; structural edits are rejected, not ignored, in phase 4; filtering of item view children happens client-side; `area_paths` accepts `/` or `\`.

## 8. Owner decisions

Recorded 2026-10-11.

- **PQ1. ADO access for implementing agents.** Reads: allowed anywhere in the organisation. Writes: allowed only on work items in the area path `Example\Software\Platform\Team A` and its sub-areas, which the owner maintains. The classification node for it is `\Example\Area\Software\Platform\Team A`; the work item field drops the `\Area` segment. Agents MUST NOT create, edit, link or change the type of any work item of type `Issue`, and MUST NOT change any item's type to `Issue`: an organisation may watch that type, so test writes could notify people. Test items are titled `[nvim-ado test] ...`. Every agent-run write MUST go through a guard that wraps the `az` transport and refuses any write that breaks these rules, before the call starts (added to phase 0 below).
- **PQ2. Non-atomic parent change.** Accepted: two calls, with the report and audit log naming any item left without a parent.
- **PQ3. Changing type through `az`.** The owner expects `az` supports it. Verify at the start of phase 6; if it does not, ship the type column read-only on existing rows and defer R5.21 and R5.22.
- **PQ4. Identity search.** The owner expects `az` supports it. Verify at the start of phase 6; if it does not, ship the assignee column read-only and defer R5.19.
- **Default types for new lines.** `Task` in both area views and child lists.

Recorded 2026-10-12.

- **Configured projects (closes risk 9).** Configuration lists the projects to look up, each with its item types: `projects = { { name = "Example", types = { "Task", "User Story", "Feature", "Milestone", "Bug", "Issue" } } }`. "My work items", text search and the area view are limited to those projects with `[System.TeamProject] IN (...)`. Each project's type catalog loads with one call the first time a list needs it, is cached for the session, and judges only that project's items (RFC 0002 R1.8, R1.9). Without `projects`, the one project resolved from `project`, the environment or the picker is the list, with no types; that list also gets the project condition, so risk 9 is closed in that mode too.
  - Interpretation for the owner to confirm or correct: a project's `types` replaces the single global `types` of RFC 0001 R5.21 and R8.6, so it is the set of types rows may be created as or changed to in that project. It does not filter which items a list shows: an Epic in Example still appears in "my work items" and the area view.

Recorded 2026-10-12, after phase 6.

- **Copies of excluded types.** A copy (paste while the original is kept) of an item whose type is not in its project's `types` is rejected, naming the row (RFC 0001 R5.6). Before, a copy kept the original's type unchecked, so copying an Epic created an Epic in a project whose `types` leave Epic out. The project is the copy's, which is the project of the area it is created in.
- **Projects without types.** Any edit that sets a type (a new line, a copy or a type change) in a project with no `types` configured is rejected, naming the row (RFC 0001 R5.18, R5.21, R8.6). The message names the project, shows the `setup()` entry to add, `projects = { { name = "Example", types = { ... } } }`, and lists the types the project's catalog has. This replaces the phase 5 and 6 behaviour, where such projects could use any catalog type. It also covers the single-project mode (`project` without `projects`), whose project has no `types`: new lines, copies and type changes there need `projects` set.
- **Misconfigured types.** When a project's catalog loads and its `types` names a type the catalog does not have (compared without regard to case), the plugin warns once per session in `:messages`, naming the unknown entries and listing the catalog's types. The load does not fail; an unknown entry never matches a row.
- **Accepted `az rest` routes.** The two routes phase 6 runs through `az rest` are accepted: identity search on the people picker (`resolve_identity`) and tag updates as a JSON patch (`update_fields` with tags). Assignee search keeps its prefix matching (R5.19 as built in phase 6).

Recorded 2026-10-12, owner request after phase 6.

- **One write per work item.** All the changes one save makes to one work item are sent together, because ADO rules and alerts may fire on intermediate states, such as an item briefly in a state without its other fields set. Delivered the same day: one JSON Patch per existing item through `az rest` (field changes, relation additions, relation removals by index from the read the revision check makes), led by `test /rev`, and one POST per create with its fields and parent. The `az rest` routes are accepted. A Related link is written once, from one end, and ADO adds the other end; it cannot be atomic with the other item's own changes. Requests on existing items run in the order of their first op, then creates. The write guard checks each request whole. Closes risks 1 and 2 for saves. Route check: section 4.1, `patch_work_item` and `create_work_item`.
- **Quiet save messages.** A save shows progress on one replaced line outside `:messages`, ends in one line in `:messages`, and opens its report in a float when it stops. Delivered the same day (`docs/architecture.md`, "Messages").

Recorded 2026-10-13.

- **Detail and picker edits use the save's write route.** A field edit from the detail buffer (title, state, assignee, tags, iteration, and the description, converted from markdown to HTML with pandoc) and the picker's state change send one JSON Patch per edit through `patch_work_item`, led by `test /rev` at the rev the item was loaded at, instead of reading the rev and then writing through `update_fields`. A failed rev test changes nothing and shows the "changed remotely" warning. A detail assignee edit resolves the typed text as a save does (R5.19) and writes only on exactly one match; `Name <email>` uses the email and an empty text unassigns. Comments (`add_comment`) stay on `az boards work-item update --discussion` without a rev check, because a comment only appends to the discussion. `update_fields` is removed from the transport, the write guard and the fake. Closes risk 2 for detail edits. Delivered the same day (`docs/architecture.md`, "Write requests").

## 9. Dotfiles changes

For `lua/plugins/ado.lua`, described here and not applied. lazy.nvim loads the plugin from `~/src/nvim-ado-workitems` (`dev = true`), so each phase reaches the owner's editor only once it is merged to `main` there.

After phase 1, no change is needed: the filter is the default and the all-states toggle is `<C-a>` inside the search picker.

After phase 1b, add the configured projects. They replace the global `types` that this section used to add after phase 5:

```lua
ado.setup({
  projects = {
    { name = "Example", types = { "Task", "User Story", "Feature", "Milestone", "Bug", "Issue" } },  -- Epic left out (RFC Q7)
  },
})
```

After phase 2, add `area_paths` and the area view key, in the same `setup()` as `projects`:

```lua
ado.setup({
  projects = { --[[ as after phase 1b ]] },
  area_paths = { "Example\\Software\\Platform\\Team A" },  -- owner may add more; "/" also accepted
  -- Defaults, shown for reference; omit to keep them:
  -- open_categories = { "Proposed", "InProgress" },
  -- area_filters = { state = "open" },
})
keymap.set("n", "<leader>wa", ado.area_view, { desc = "Area view", remap = false })
```

After phase 3, add the item view key (and, optionally, the link types):

```lua
-- in setup(): link_types = { "System.LinkTypes.Hierarchy", "System.LinkTypes.Related" },  -- default
keymap.set("n", "<leader>wi", ado.item_view, { desc = "Item view by ID", remap = false })
```

After phase 5, add the default types (the types themselves are in `projects` since phase 1b):

```lua
-- in setup():
default_types = { area = "Task", children = "Task" },  -- owner decision, section 8
```

`<leader>wa` and `<leader>wi` are free in the global `<leader>w` group (`wm`, `ws`, `wo` are taken). In a detail buffer the plugin's buffer-local `<leader>wi` opens the item view for that buffer's item instead of prompting. The `telescope.nvim` and `plenary.nvim` dependencies stay, for the pickers.
