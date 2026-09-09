# Post-mortem: the wire-baseline day on cora — 2026-09-08

One mission goal, `group-header-redesign-wire-baseline` on sector `sec-a0e680`
(cora), run repeatedly through the day as the flag-off baseline for Wire
(`specs/WIRE.md`) — and, per the doctrine, as the test after every factory fix.
Nothing below was a model-capability failure. Every defect is infrastructure
or plumbing; each was fixed the same day and the mission re-run unchanged.
Box: `i-0593ef62313cab7a1`; versions 0.65.277 → 0.65.298.

## Defects, in the order they surfaced

1. **The box did not sleep for ~9 hours** — a held mission (`awaiting_input`)
   counted as "running", tripping the zombie detector (503 on `/health`) and
   keeping idle-stop off. *Fixed:* `Missions.running?/1` excludes
   `held_for_human?`; `Health.probe/1` splits liveness from verdict;
   `zombie?/1` is pure (c28e401, a5ee596, 316b3b6).

2. **The box powered off 15 s after a question was raised** — idle-stop
   measured a streak across 5-minute samples and carried a *previous* held
   mission's quiet through a kill, a deploy and four minutes of ghosts.
   *Fixed:* event-driven `Observability.Activity.idle_since`; `/health`
   reports it; the timer measures from it (12e75e5).

3. **`%h` in the systemd unit's PATH resolved to root's home** — the
   `claude` installer under `/var/lib/gitf/.local/bin` was invisible after the
   box replacement. *Fixed:* literal path (5801408); installer-location
   fallback warns instead of crashing.

4. **An orphan question from a deleted mission held the queue for 8 days.**
   *Fixed:* kill withdraws the mission's questions; the Janitor sweeps orphans
   (97163e3).

5. **The Catwalk had no idea the factory was asleep** — every click was a
   timeout. *Built:* heartbeat probe (timer + tab visibility), sleep overlay
   with a wake button, countdown banner with keep-awake; then a second fix
   because inline `display:flex` beat the `hidden` attribute and the overlay
   showed on a healthy page (4fc0bd2, e296ba6, 0617552).

6. **Fix ghosts rewrote `Cargo.toml` chasing a build failure that was on
   `main`** — validation had no baseline, so a sector defect became the
   mission's, and the fix loop edited outside the plan's manifest. *Fixed:*
   `GroundTruth.baseline_verdict` at merge-base (`pre_existing` verdict,
   `sector_baseline_broken` alert); manifest fence on fix ghosts with
   revert-and-fail; phantom-branch skip in topology (f8c8402). Cora itself was
   fixed by the operator (08a5758).

7. **No way to say "none of these."** The operator hated all three
   treatments. *Built:* reject-all with per-option votes and free-text
   direction; the phase re-runs with a `REJECTED PROPOSALS` block naming
   options by number; budget of three redesigns per mission (2bf6170 …
   eacf500, fdbd40a).

8. **The redesign round re-asked the rejected options.** The Janitor's
   periodic advance fired 18 s before the re-run ghost finished; the gate
   found only the moved-aside `requirements_asked` artifact — in the key
   family by spelling and askable again now that its key was rejected — and
   asked it verbatim. The fresh artifact (three new mockups) landed unasked.
   *Fixed:* `_asked` artifacts are history, never questions (5a0550c). The
   test pins both halves: mid-re-run the gate is clear; once the fresh
   artifact lands, its question is the one asked.

## What the baseline said about Wire

With the flag off, artifacts and prompts were measured on this mission:
artifacts −12 % (vs compact JSON) / −23 % (vs pretty JSON); prompts −15 %
total, of which the `@brief` views contribute −6 points independent of the
flag. The flag-on A/B (`specs/WIRE.md` §8) has not been run.

## Still open

- `cost_spike` alert re-fires every five minutes (needs a dedup key).
- A Lambda "waking…" page for navigating to a sleeping box (terraform; spend
  question, ask first).
- Discord integration is planned, not built: `docs/plans/discord.md`.
- The Janitor's periodic advance still runs the inquiry gate before asking
  whether the phase's op is finished. Harmless now that history is excluded,
  but the order is backwards.

## Addendum, 2026-09-09 — the sweep

After defect 8 came two more in the same family, then a four-lens sweep for
every other instance of the classes the day exposed. All fixed and deployed in
0.65.298–309; the resumed mission msn-e56adf → cora PR #22 is the acceptance
test for the first three.

9. **A withdrawn question blocked re-asking its key** — `existing/3` returned
   it, `ask/2` had no arm for it, and the gate's never-raises guard swallowed
   the crash and walked into design. Withdrawn is invisible to a re-ask; the
   gate now stalls in place on a failure (`input_gate_failed`, critical).
10. **The chosen option's rationale never reached the re-run** — only the
    label did, so "Refined tinted band (no hatch)" was built without the
    sealed-drawer geometry its description promised. The rationale is part
    of the decision now. Found by rejecting apr-1319fa; verified by resuming.
11. **No way to resume without re-asking** — `resume_mission` gained
    `from_phase: "requirements"`: inherits triage, research and every
    operator answer, no tree, and the requirements prompt carries the
    decisions before any phase runs. The registers do not cross (the child
    reuses FR-n ids for new text); source identity, workflow and the approval
    rejection reasons do.

The sweep (commits 8fbe75d, 6da9792, 58e1f07), by class:

| Class | Instances fixed |
|---|---|
| History read as live | `_asked` artifacts inherited across a resume; fed the accepted-requirements ratchet and reset the validation respawn budget; preview cache served the rejected round's mockup for a reused option id; design promotion fell back to an unreviewed strategy; design completion counted the previous round's ops |
| Missing status arms / fail-open | answer/reject on withdrawn; GATE 1 blind to killed/cancelled/paused (budget-paused missions re-advanced every 3 min); Janitor sweep list missing triage/publish; unknown approval state read as "not required"; gate rescue cleared; provider preflight, gh auth probe, autonomy meter admitted on error |
| Decisions losing substance | text answers cut to 60 chars; rejected options without rationale; inherited rejections materialized as answers; review dissent/fingerprint read from fields the card lacks (every rejection fingerprinted identical → redesign budget 0); acceptance criteria never rendered (list vs binary guard); impl and fix ghosts saw no criteria and no operator decisions; planning lost the reviewer's coverage gaps; Wire budgets on mechanically-read fields |
| Sweeps racing live work | gate holding on the first tournament variant; halts sealing missions without stopping ghosts; assigned-op timeout under a live worker; stale-phase respawn guard blind to pending; watchdog pausing held missions and auto-failing without archiving |

Deferred, with reasons: workflow-mode `before_advance` results are ignored by
contract (a missing selected variant still plans on the aggregate design);
dashboard "Reject & Redesign" collects no reason; simplify ghosts run without
requirements or decisions; PR-review intake caps inline comments at 25; the
Janitor still runs the gate before asking whether the phase op is finished
(harmless now, backwards); `list_outcomes` was empty for the resumed child.
