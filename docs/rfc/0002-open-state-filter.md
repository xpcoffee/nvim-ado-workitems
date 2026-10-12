# RFC 0002: Open-state filter

- Status: Draft, for review before implementation planning
- Date: 2026-10-11
- Scope: `nvim-ado-workitems` (loaded by the dotfiles spec `lua/plugins/ado.lua`)

The key words MUST, SHOULD and MAY follow RFC 2119: MUST is required for the first release, SHOULD is expected unless planning finds a reason against it, MAY is optional.

## 1. Summary

Work item lists in the plugin should show only items that are still open or pending. This changes "my work items" and text search, and gives the views in [RFC 0001](0001-workitem-navigator.md) one shared definition of "open" to use.

## 2. Problem

Both "my work items" and text search exclude only the `Closed` state (`lua/ado/wiql.lua`, in `my_items` and `text_search`). Items in other finished states, such as `Resolved`, `Done` or `Discarded`, still appear, so the lists mix finished work with live work.

## 3. Goals and non-goals

### Goals

- G1. Lists show live work by default, using one definition of "open" across the plugin.

### Non-goals

- Filters other than state, such as assignee, type or tag. RFC 0001 covers those for the area view.

## 4. Concepts

- **State category.** Azure DevOps (ADO) assigns every state of every work item type to one of five categories: `Proposed`, `InProgress`, `Resolved`, `Completed`, `Removed`. A `Bug` might have `New` (Proposed), `Active` (InProgress), `Resolved` (Resolved) and `Closed` (Completed); a custom type might add `Discarded` (Removed).
- **Open state.** A state whose category is `Proposed` or `InProgress`. Defining "open" by category rather than by state name means custom states such as `Discarded` are handled without a hard-coded list. R1.5 says how the plugin turns this into a query.

## 5. Requirements

- R1.1 "My work items" MUST show only items in an open state.
- R1.2 The open-state definition MUST be shared by every list in the plugin: "my work items", text search, and the views in RFC 0001.
- R1.3 The set of categories that count as open SHOULD be configurable through `setup()`, defaulting to `Proposed` and `InProgress`.
- R1.4 Text search MUST show only open items by default, which is a change from today's behaviour of hiding only `Closed`. It SHOULD offer a toggle that includes items in every state, because searching for finished work is a normal use.
- R1.5 WIQL, the ADO query language, filters on state names and has no state-category condition. The plugin MUST therefore fetch every work item type in the project with its states and their categories (per project, R1.9), in one call to the work item types endpoint, cache the result for the session, and build the state condition per type, for example `([System.WorkItemType] = 'Bug' AND [System.State] IN ('New', 'Active')) OR (...)`. A single list of open state names across all types is not enough, because the same state name can be open in one type and finished in another.
- R1.6 The existing per-type state lookup (`client.states` in `lua/ado/client.lua`, cached by `config.cache_states`) keeps only state names and discards categories. It MUST be changed to keep the category, or be replaced by the lookup in R1.5.
- R1.7 The query building and the type-to-category lookup SHOULD live in code with no Neovim dependency, matching the core and presentation split in RFC 0001 (R6), so the navigator work can reuse it unchanged.
- R1.8 Lists MUST cover only the projects named in the `projects` setting, through the WIQL condition `[System.TeamProject] IN (...)`. `az boards query --project P` searches the whole organisation, so without the condition an open-only search returns items from projects whose types the plugin has not loaded. When `projects` is not set, the one project resolved from `project`, the environment or the first-use picker is the list, with no configured types.
- R1.9 The lookup in R1.5 MUST run once per configured project, the first time a list needs that project's states, and be cached per project for the session. Each item MUST be judged open by the categories of its own project, because two projects can define the same type name with different categories. The open condition therefore pairs each project with its own per-type condition: `([System.TeamProject] = 'A' AND (...A's types...)) OR ([System.TeamProject] = 'B' AND (...))`.

Decision 2026-10-12 (owner): R1.8 and R1.9 resolve risk 9 in [plan 0001](../plan/0001-implementation-plan.md), which the phase 1 check on real data found: 523 of 1,162 all-states results for "bug" came from projects other than the configured one.

## 6. Assumptions to review

- A1. **The state-category lookup costs one call per session.** R1.5 fetches every work item type in the project at once, so the plugin does not need to know which types a query will return before building it. `az devops invoke` can call that endpoint, as `client.states` already does for the per-type states endpoint. Risk if wrong: if the endpoint does not return categories, the fallback is one call per type, which needs the type list first.

## 7. Acceptance behaviours

1. Given items in states `Active`, `Resolved` and `Discarded`, where `Discarded` belongs to the `Removed` category, "my work items" returns only the `Active` item.
2. Given a state name that is open for type A and finished for type B, the open filter returns the type A item and not the type B item.
3. Text search returns only open items by default, and every matching item with the include-all toggle on.
4. Given configured projects A and B, where type `Bug` has state `Resolved` in an open category in A and in a finished category in B, "my work items" returns A's `Resolved` bug and not B's, and returns no item from an unconfigured project C. The first list loads one catalog for A and one for B; the second loads none.
