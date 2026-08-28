# War story: msn-7683ac — six-level priority, the widest mission yet

Raw chronicle for a blog post. Everything here is recorded as it happened,
including the failures — especially the failures. Timestamps UTC.

## Why this mission exists

Batch 1 of the BEAM best-practices audit
(`docs/audits/2026-08-28-beam-best-practices-audit.md`) shipped in v0.65.212:
supervision reordering so a Major crash can't kill the ghost fleet, unlinked
task boundaries, five fail-open guards flipped to fail-closed, the Tachikoma
kill budget matched to the validation budget, canonical mission-status
predicates. Doctrine says every factory fix is validated by re-running the
canonical mission unchanged — but the canonical mission's feature
(group-pr-list-by-author, runs 1–8) merged as cora PR #16 on 2026-08-28,
retiring it as a test. The operator chose to replace it with something far
bigger.

## The mission

**msn-7683ac / six-level-priority-1**, sector cora (sec-a0e680), full
pipeline forced. Expand cora's priority scale from 4 levels
(high/normal/low/ignored) to 6 (ignored / unimportant / "if I have time" /
a better-named normal / important / critical), where critical×critical must
*persistently* grab the operator's attention until addressed.

Deliberately harder than anything the factory has completed:

- **Dual-language, generated-bindings**: Rust enums (`models.rs`) → serde →
  ts-rs → `src/bindings/*.ts` → TypeScript consumers. The consolidation
  phase itself must regenerate bindings (`npm run bindings`).
- **Lossless disk-state migration**: existing settings stores contain old
  serialized strings; mapping mandated (high→important, normal→default,
  low→if-I-have-time, ignored→ignored; unimportant/critical opt-in).
- **Behavioral matrix**: alert suppression for unimportant, never-suppress
  for critical, strict total ordering across all sorts and group headers.
- **Open design decisions**: the goal deliberately does NOT choose the wire
  keys, the reworded "normal", or the persistent-attention mechanism — the
  operator's instruction was "shouldn't the factory figure this out?" (with
  a GTD-naming lean). The 3-way design phase owns those calls.
- Run 8 (the last clean run) was `MainApp.tsx +9/−4`, frontend-only,
  ~15 min, zero fix ops. This is 3–5× that scope with a scope fence that
  crosses the IPC boundary on purpose.

## What the factory is running on

v0.65.212 (commit 9f3ce12), deployed ~17:05Z after CI run 33182772333.
First boot under the new supervision order was clean. The box idle-stops;
`gitf wake` is ~60s.

## Chronicle

- **17:23Z** — First `create_mission` attempt fails: `remote factory:
  Connection timed out`. Not a defect — the box idle-stopped between the
  Batch-1 deploy and the mission launch. `gitf wake`, ~60s, retried.
- **17:28:58Z** — Mission created. `start_mission` with `fast: false` →
  `pipeline_mode: "full", pipeline_mode_forced: true`. Triage op op-74cc59
  running under ghost-3892a3 within 4 seconds of start.
- **~17:35Z** — Triage complete; research phase running (2 ops total).
  Watcher attached (2-min polls → `msn-7683ac-timeline.log`).
- **17:29–17:41Z** — The front half of the pipeline was almost absurdly
  smooth: triage 23s, research 76s, requirements 71s, three-way design
  4m17s, review 2m, planning 3m12s.
- **17:41Z** — Planning delivered the largest implementation DAG the
  factory has ever attempted: **13 feature ops, 12 initially blocked** on
  dependencies. Titles show real decomposition: enum expansion with
  legacy-safe parsing, settings/SQLite parsing, ts-rs bindings
  regeneration, priority commands + audit trail, poller gating + a
  persistent critical-alert state engine, CalloutApp persistent-alert UI
  wiring, MainApp sorting/menus/badges, SettingsView tables,
  RepoSettingsDrawer, HistoryDrawer audit labels, an `is_critical`
  activity flag, a shared frontend priority-constants module. The design
  phase answered the deliberately-open questions itself — and invented a
  `persistent_alert.rs` module for the attention engine.
- **17:41–19:19Z** — Implementation ground through the DAG for 98 minutes,
  ops unblocking one by one. Two ghosts died with "reported success but
  produced 0 file changes" (op-834c40/ghost-1a2674 at 18:49, and the
  CalloutApp op op-88f0a6/ghost-08d8ed at 19:19) — both retried
  successfully by replacement ghosts. 13/13 feature ops eventually done.
- **19:19Z** — Implementation → validation. Consolidation merged the
  parallel ghost branches into the canonical worktree… and here the
  mission's fate was sealed.
- **19:22–20:16Z** — Validation's ground-truth run (`npm run typecheck`)
  failed on **committed merge-conflict markers**. Not a few: nested
  `<<<<<<< HEAD` / `>>>>>>> ghost/...` blocks from **at least five
  branches** (ghost-94cae9, -503ee3, -3c3cbf, -ee6d8b, -6c56d9) across
  **15 files in both languages** — `models.rs` alone carried 61 marker
  lines through the enum definitions; `MainApp.tsx` 32; `commands.rs` and
  `store.rs` 22 each; `poller.rs` 18; even the *generated* ts-rs bindings
  contained raw conflict text instead of valid TypeScript unions. Fix
  attempts 1–4 each cleaned part of the mess; each fix ghost's own branch
  merged back through the same union machinery and re-conflicted —
  ghost-ee6d8b, the attempt-4 fix ghost, appears in the marker list of
  the tree it was supposed to clean. Both attempt-4 ops rejected.
- **20:16:34Z** — "Ghost lost in the net — validation failed after 4
  attempts." Mission failed, sealed cleanly. No PR was opened; nothing
  reached GitHub. Box healthy afterward.

## Root cause — a policy that is correct at n=2 and catastrophic at n=5

`GiTF.Git.merge_union/2` (git.ex:605-612), on a content conflict,
deliberately stages the conflicted files **with markers inside** and
commits them. The comment above `consolidate_impl_branches`
(orchestrator.ex) explains why: run 13 aborted conflicted merges, which
silently dropped whole branches from the union; validation reported the
work "missing"; fix ghosts re-implemented it blind and manufactured
duplicate definitions. "Visible markers are strictly better than
invisible absence." True — for one conflicted pair.

At this mission's scale the policy diverges instead of converging:

1. **Nested markers.** Merging branch C onto a tree already carrying
   committed markers from A⊕B produces conflicts *inside* conflicts.
   By branch five, models.rs was 61 marker lines of interleaved enum
   definitions that neither an LLM nor a human can reliably parse.
2. **No dedicated resolution step.** Reconciliation is delegated to the
   generic validation fix loop — one ghost, four attempts, the entire
   15-file two-language mess in context, *plus* any real validation
   issues, all at once.
3. **Fix branches feed back through the same broken funnel.** A fix
   ghost's resolution commits merge back via merge_union and can
   re-conflict with the tree they were derived from — the loop's own
   output re-enters as input.
4. **The planner maximised conflict probability.** 13 parallel ops with
   no file-ownership partitioning, most touching models.rs and
   MainApp.tsx. Conflict on the hot files was a certainty, not a risk.

## What the factory got RIGHT (Batch 1 held)

- ~35 ops, ~20+ ghosts spawned/retired across 2h48m with zero
  supervision incidents — no fleet kill, no orphan OS processes observed,
  no stray PRs, no lockfile churn, nothing pushed to GitHub from a failed
  mission.
- The DAG scheduler drained 12 blocked ops in dependency order flawlessly.
- Ground-truth validation caught the markers precisely (file:line in the
  gaps list) — the verdict was *correct*; the factory failed honestly.
- The fix-attempt cap (4) stopped the burn; the mission sealed terminal
  instead of looping forever. Failing closed worked everywhere it was
  supposed to.

## Scorecard

- Outcome: **failed** (validation, after 4 fix attempts) — consolidation
  conflict-marker divergence.
- Wall clock: 2h 48m (17:29–20:17Z). Front half of pipeline: 12 min.
- Cost: not precisely attributable — the 168h cost-record pruning ran
  mid-mission, so lifetime totals *decreased* during the run
  ($792.62 → $752.40). Rough per-ghost summation suggests ~$40–60.
  (Observability finding: per-mission cost needs the ledger, not
  costs_summary.)
- Fix ops: 7 (4 validation-lane, 3 quality-lane); 2 rejected at the cap.
- Ghost failures: 2× "success but 0 file changes" (both recovered by
  retry).
- Factory defects surfaced (→ next factory work, before rerun):
  1. Consolidation needs **incremental merge-and-resolve**: merge one
     branch, and if conflicted, spawn a focused resolution ghost for
     *that one merge* before merging the next — never stack markers on
     markers. (Supersedes run 13's "conflict-abort→conflict-resolution"
     open item.)
  2. A **conflict-marker gate**: no commit sink may accept files with
     `<<<<<<<`/`>>>>>>>` markers except the explicit
     resolution-in-progress state; validation attempts must not be burned
     on a tree that a `git diff --check` would already reject.
  3. **File-ownership-aware planning**: ops that must touch the same hot
     files should be sequenced (DAG edges) rather than parallel, or the
     planner should carve shared-file changes into a first, blocking op.
  4. Per-mission cost attribution (ledger-backed) so a run's price
     survives pruning.
- Design-phase choices (recovered from op titles; the full design
  artifact is in the mission record): a `persistent_alert.rs` state
  engine + CalloutApp UI + acknowledge command for critical×critical, an
  `is_critical` activity flag, a shared `src/lib/priority.ts` constants
  module, legacy-safe parsing for migration. Wire keys/labels: in the
  design artifact (not yet extracted).

**The blog-post arc:** the factory decomposed a two-language,
six-surface feature better than most human teams would, executed 13
parallel workstreams cleanly, and then drowned in its own merge — because
the one piece of machinery that was never built for n>2 was the piece
that turns parallel work back into one tree. Every safety net around the
failure held. The factory now knows exactly what to build next.

## Interlude: building the consolidation engine (2026-08-28, same day)

Shipped as **v0.65.214** (commit 4f9221e), ~4 hours after the failure:

- **Incremental merge-and-resolve.** `consolidate_impl_branches` now stops
  at the FIRST conflicted merge. The markers for that one merge are still
  committed (run 13's visible-beats-absent lesson survives), but instead
  of merging four more branches on top, the factory spawns a **focused
  resolution op** — a ghost whose entire job is reconciling that single
  merge's marked files, running in the canonical worktree where the merge
  commit sits. When it finishes, the mission re-enters validation,
  `merged?` skips the resolved branch, and the next branch merges. One
  conflicted merge at a time, forever bounded: two attempts per target,
  then the mission fails with a named reason.
- **The marker gate.** `Git.conflict_marker_files/2` — a `git grep` for
  `<<<<<<<`/`|||||||`/`=======`/`>>>>>>>` at line start, scoped to the
  mission's changed files — runs after every consolidation pass. A
  marker-laden tree can no longer reach a validation ghost, so validation
  attempts are never again spent on what a text scan already convicts.
- Resolution ops consume **no validation attempts** (msn-7683ac spent all
  four on marker cleanup) and carry explicit instructions: both sides are
  wanted work; generated files get their *source* resolved and are
  regenerated, never hand-merged; intentional marker-like content is left
  alone.
- Preserved: generated-file regeneration on conflict (run 32),
  unmerged-branch visibility notes (run 21), residue restore, merged?-skip.

2,230 tests green. The rematch: the SAME mission goal, unchanged, on the
new engine.
