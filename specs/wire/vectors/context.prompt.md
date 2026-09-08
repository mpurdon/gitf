## Files

```wire
%wire 1 files
F1 src/windows/MainApp.tsx
F2 src/windows/MainApp.css
```

## Technical Design

```wire
%wire 1 design
C1 F1 | GroupMode type & group-by select
  desc Extends the GroupMode union with "author" and adds the corresponding <option> to the group-by <select>, so the mode is selectable and type-checked end to end.
  if type GroupMode = "org" | "repo" | "reason" | "type" | "author" (line ~78)
  if <option value="author">Author</option> inside the group-by <select> (~line 2016-2025)
C2 F1 | Grouping key/label resolution (grouped useMemo)
  desc Adds the author branch to the key/label ternary chain inside the existing grouped useMemo (~lines 1690-1698), producing one bucket per pr.author. No change to the pull/groupPull/entries.sort machinery — the new mode falls through to the existing default (else) sort branch that already does groupPull-desc then label-asc.
  if const [key, label] = groupMode === "author" ? [pr.author, pr.author] : ...(existing chain)
C3 F1,F2 | Group header priority badge
  desc Generalizes the repo-only `repoPrio` lookup into a groupMode-aware `groupPrio` (repoPrio for "repo", authorPrioOf(group.key) for "author", null otherwise) and renders the existing prio-tag badge off that value. The repo-only cycle-click flag button and context menu stay scoped to groupMode === "repo" — the requirement only asks for badge parity, not the click-to-cycle affordance.
  if const repoPrio = groupMode === "repo" ? prioOf(group.key) : null;
  if const authorPrio = groupMode === "author" ? authorPrioOf(group.key) : null;
  if const groupPrio = repoPrio ?? authorPrio;
  if {groupPrio && groupPrio !== "normal" && <span className={`prio-tag ${groupPrio}`}>{groupPrio}</span>}
M R1 C1 | Append | "author" to the GroupMode union at line 78. TypeScript then forces every exhaustive switch/ternary on GroupMode (the grouping ternary) to be updated, which is exactly where the next component's edit lands — the compiler is the check that nothing was missed.
M R2 C1 | Add <option value="author">Author</option> as a new line after the existing four <option> elements in the group-by <select> (~line 2024), leaving the existing four untouched in order and label.
M R3 C2 | Add a fourth ternary arm: groupMode === "author" ? [pr.author, pr.author] : ... . pr.author is used verbatim as both key and label, matching how author logins already render elsewhere in the rail (plain text, no decoration) — there is no separate author-display helper to reuse or diverge from.
M R4 C2 | No new code path: the sorted array (line 1682-1687, priority-then-SORTERS[sortMode]) is computed once, before grouping, independent of groupMode, and each group's prs array is simply a filtered slice of that already-sorted array. Author mode inherits this for free.
M R5 C2 | The entries.sort branching (lines 1719-1733) only special-cases "reason" and "type"; every other groupMode (org, repo, and now author) already falls into the else branch: entries.sort((a,b) => groupPull(b) - groupPull(a) || a.label.localeCompare(b.label)). No change to that branch or to groupPull/pull — author mode uses the same formula that already folds in authorPrioOf via PRIORITY_WEIGHT.
M R6 C2 | Already enforced upstream: the `unignored` filter (lines 1660-1666) drops any PR whose authorPrioOf is "ignored" before grouping ever runs, for every groupMode. An ignored author therefore contributes zero PRs to `sorted`, so no author-keyed bucket is ever created for them — no author-mode-specific filter needed.
M R7 C3 | Replace the repo-only repoPrio-gated badge with the groupPrio union described above; the JSX for the <span className={`prio-tag ${...}`}> block itself is unchanged, only its input value generalizes. Verified there is no other author-priority badge pattern elsewhere to conflict with (the PR-row context menu at line 2388 sets author priority per-PR, unrelated to this header badge).
M R8 C2 | No code change — verification only. Collapse keys are `${groupMode}:${group.key}`; since group.key for author mode is pr.author (a string, same shape as org/repo keys) and groupMode is now literally "author", the composite key is automatically distinct from an org/repo/reason/type key of the same raw string. Confirmed by reading toggleGroup/collapsed usage (lines 1478-1479, 2141, 2148) — it only ever consumes the pre-namespaced string, never branches on groupMode itself.
M R9 C2 | Both edits are additive (`else if` grows to a new ternary arm; repoPrio becomes one of two null-able inputs to groupPrio, still null-unless-groupMode-matches). No existing branch's condition or output changes for org/repo/reason/type, so their rendering and ordering are provably identical to pre-change behavior — confirm by diff review, not new logic.
D C3 C2
D C1 C2
D C1 C3
K Label literal mismatch risk: the acceptance criteria (FR-2) specify the literal <option value="author">Author</option>, capitalized, while every existing option uses a lowercase "by X" convention ("by org", "by repo", "by type", "by reason"). Implementing the literal spec introduces a visible inconsistency in the select's label casing. Recommend flagging this to the client/user before implementation and defaulting to "by author" for visual consistency unless the literal wording is a hard requirement — this is a one-line decision, not a design fork, but worth a single confirming question since it's client-facing UI copy.
K Silent badge-condition coupling: because groupPrio is now `repoPrio ?? authorPrio`, any future third mode that also wants a badge must extend this pattern explicitly — leave a short inline comment only if the ternary chain grows past two cases, per the codebase's existing comment density (comments are used sparingly here for non-obvious invariants, e.g. lines 1673-1677, 1704-1708).
K Behavioral note (not a code risk, a UX one): the groupPull scoring is a *sum* across a group's PRs, floored by its best single PR (lines 1704-1718). For authors, group size varies far more than for repos/orgs in practice (a prolific author may have 10+ open PRs vs. a repo group's typical handful), so an author with many normal-priority PRs could out-rank an author with one high-priority PR purely on volume, before the floor kicks in. This is explicitly the existing, intended formula (NFR-1 forbids changing it), but it's worth surfacing to the user as an observation during review of the acceptance walkthrough — if it produces a counter-intuitive ordering with real data, that's a signal for a future, separate change request, not something to silently patch in this task.
K Verification-only items (FR-8, and the ignored-author filter for FR-6) carry a false-negative risk if skipped: the plan relies on reading the current key-composition and filter code rather than assuming it "just works." Both were traced above; implementation should still eyeball collapsed-state persistence and an ignored-author case manually against the acceptance criteria before calling the task done, since it's cheap insurance against a wrong assumption.
```
