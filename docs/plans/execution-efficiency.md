# Execution efficiency: worktrees + BEAM

Drafted 2026-08-28 while msn-6be1ba ran, from two runs' worth of hard data
(msn-7683ac, msn-6be1ba) and the BEAM audit
(`docs/audits/2026-08-28-beam-best-practices-audit.md`). Status: PLAN —
nothing here is built except where noted.

## The observation that frames everything

Both six-level-priority runs show `running=1` for the entire 98-minute
implementation phase: the planner chains ops via dependencies, so the
"parallel" 13-op DAG executes **sequentially**. Yet every op's worktree
branches from a **common base**, so those sequential ghosts still produce
13 independent branches all editing `models.rs` — which is what made
consolidation a five-way collision. The factory currently pays
**parallel-merge costs without parallel-execution speedups**. Every
change below attacks one side of that inequality.

## A. Worktree topology

### A1. Chain worktrees when execution is sequential (high leverage, small diff)
When an op spawns and nothing else is running (today: always), branch its
worktree from the **current consolidated tip** (canonical branch), not the
mission base. Sequential work becomes cumulative; merges become
fast-forwards; the consolidation crunch disappears for the common case.
Mechanism already half-exists: `spawn_for_op`'s `base_branch` hint — make
it track the tip after every merge instead of "first completed op".

### A2. Merge-as-you-go (high leverage, uses the new engine)
Move consolidation from a validation-time batch to an **op-completion
increment**: when an op finishes, union-merge its branch into the canonical
tip immediately. A conflict is then detected minutes after it was created,
scoped to ONE merge, and the focused resolution op (built in v0.65.214)
fires while the context is small. Validation starts on an
already-consolidated tree; its consolidation pass becomes a verification
no-op. This also spreads the sector-lock load instead of spiking it.

### A3. File-ownership-aware parallelism (the real speedup)
Ops already declare `target_files`. A planner post-pass adds dependency
edges between ops whose declared sets intersect (plus the sector profile's
known hot files); everything else is allowed to run **concurrently**.
Parallel *editing* is safe — it's parallel *building* that corrupts, and
builds are already serialized by WorktreeLock in the arena (A4). With A2,
each completion merges immediately, so even mispredicted overlaps surface
as one small conflict, not an end-of-phase pileup. Target: 3 concurrent
impl ghosts on a mission like six-level-priority ⇒ implementation ~40 min
instead of ~98.

Prereq: Major must spawn multiple ready ops per cycle (today: one per 2s
stagger, capacity-gated) — see B1.

### A4. Lightweight ghost worktrees, one build arena
Formalize what is already half-true: ghosts EDIT in their worktrees; all
toolchain runs (installs, typecheck, tests) happen in the canonical
arena under the sector lock. Ghost worktrees then never need
`node_modules`/`target` (faster spawn, less disk, and install-residue
commits become structurally impossible — the whole worktree-hygiene bug
class dies). Shared caches stay: per-sector `CARGO_TARGET_DIR` (exists),
npm cache (exists). Enforcement: ghost loadout drops install permissions;
the validation/exec path owns them.

## B. BEAM side

### B1. Unblock the scheduler (audit Theme B — batch 3)
The Major cannot exploit A3 while its own callbacks run git rebases,
30-minute validations behind an `:infinity` global lock, and per-tick
`df`/`git status` shell-outs. Move `advance_quest` effects, the
merge-conflict handler, and preflight probes onto supervised tasks
(template: `major.ex:699-713`), then raise the spawn loop from
one-op-per-2s to "spawn every ready op whose file-set is clear, up to
capacity".

### B2. Index the hot paths (audit F5/F6 — small diffs, immediate)
`:costs` by mission (or an incremental per-mission spend counter updated
at insert — kills the every-10s full-table fold in Budget/Watchdog),
`:links` by `{to, read}` (Major's 30s recovery sweep), `:ghosts` by
status (per-spawn capacity check), `:missions` source-key (webhook dedup).
Add `:ghosts` to the prune sweep — it currently grows forever.

### B3. Archive flush → per-record journal (audit F1)
Today every dirty collection is fully re-serialized to disk every second
(`tab2list → term_to_binary → whole-file write`) — O(history) I/O per
second on a small EBS volume, and the dominant background load during a
mission. Replace with an append-only journal per collection (record-level
dirty set already exists in the writers) + periodic compaction; or at
minimum a size-scaled flush interval.

### B4. Don't re-verify unchanged trees
Exec validation re-runs `npm ci && typecheck && build` even when the tree
hash hasn't moved since the last verdict. Key the exec_validation verdict
by `HEAD` sha + dirty-status hash; identical tree ⇒ reuse verdict. Same
for the audit lane. On a mission with 4 validation rounds this saves
3 × (install + build) of sector-lock time — and sector-lock time is
exactly what A2 spends more of.

### B5. Cost/latency guardrails that fell out of the runs
Per-mission cost must survive pruning (ledger-backed attribution — the
168h sweep ran mid-msn-7683ac and lifetime totals went *down*); watcher
observation: `active_ghost_count` now real after Batch 1, use it instead
of `Ghosts.list` sorts in the spawn gate.

## Sequencing

1. **Now-ish (small, independent):** A1 + A2 (the engine primitive
   exists), B2 indexes, B4 verdict caching.
2. **Next:** B1 Major offloading (audit batch 3), then A3 parallelism +
   multi-spawn — parallelism without B1 just queues behind a blocked
   scheduler.
3. **Then:** A4 arena formalization, B3 journal.

Acceptance per doctrine: the same six-level-priority mission, again,
after each phase — wall-clock and conflict-count are the metrics.
Baselines: run 1 = 2h48m/failed (marker divergence); run 2 = TBD
(first engine test, sequential); phase-1 target < 90 min; phase-2
target < 60 min.

## Naming: "the endgame" (operator-adopted 2026-08-29)

The post-consolidation convergence stage — everything between "all impl
branches merged" and "validation's verdict accepted": the full-tree marker
scan, worktree-target resolutions, and scan-vs-ghost adjudication. It has
killed more runs than any named phase yet has no name in the code.
Roadmap: introduce `endgame` as the official term (log prefixes, the
extracted module when the resolution engine leaves the orchestrator, the
dashboard's phase strip between implementation and validation).
