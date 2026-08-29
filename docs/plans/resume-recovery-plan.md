# Resume recovery plan — everything found in the 2026-08-29 session

PLAN ONLY. Nothing here is implemented. Ordered by dependency, not size.
Tree state when written: no active missions; box on 0.65.229 with a
persistent `memory: warning`; the 15/16-requirements tree is preserved at
`archive/msn-398fa4` with ONE known code gap (FR-5: MainApp.tsx
between-group sort for org/type uses `Math.min` of member weights instead
of the groupPull weighting). Full incident detail in session memory
(project_run_msn7683ac_postmortem).

## P0 — Unblock resume (three linked defects, this order)

**P0.1 Exit-127 in resume-seeded worktrees (the blocker).**
Both post-storm resumes died the same way: the sector validation command
(`npm ci && …`) exits 127 (command-not-found class) when run in a
worktree seeded from an archive branch — while identical resumes worked
hours earlier. Reproduce BY HAND first (SSM, one script): create a
worktree from `archive/msn-398fa4` exactly as `Missions.resume` does, run
the sector validation command as the gitf user, capture PATH / `which
npm` / the wrapper (`Validator.run_custom_validation` builds a
sandbox+timeout shell). Hypotheses, most→least likely: (a) daemon PATH
changed across the 0.65.229 systemd restart (env not reloaded the same);
(b) the Validator wrapper resolves tools differently in the new worktree
location; (c) memory pressure interfering with process spawn (would
usually be 137, but verify). Fix what the reproduction shows; add a
regression test that runs a trivial command inside a freshly seeded
worktree.

**P0.2 The spawn-abort + wait-with-no-waiter pair (one fix, two halves).**
(a) PhaseLauncher's validation dispatch must not let a ground-truth
infra failure abort the ghost spawn — store the infra verdict, still
spawn (the validation ghost + infra guard already handle infra verdicts
correctly), or transition to an explicit infra-hold with an alert. Never
"transitioned but unspawned".
(b) Phases.Validation verdict self-heal: when the phase is "validation",
no validation op is in flight, and no fresh artifact exists, the verdict
must trigger a respawn (bounded, e.g. 3, then alert + hold) instead of
returning `{:wait, "validation"}` forever. The Janitor advances every
3 minutes — give it something that acts.

**P0.3 The memory warning (investigate BEFORE fixing).**
Health has flagged `memory: warning` (>1GB BEAM) since the duplicate
storm; plausibly upstream of the slow synchronous resumes that caused it.
First: one `gitf-console rpc` snapshot of the top-10 processes by heap +
`:erlang.memory()` breakdown — do NOT guess. Known suspects from the BEAM
audit: the 1s whole-collection Archive flush (F1) against a 194k-row
events collection and a >1GB .gitf store; Major heap growth from
full-collection copies (F6). Likely cheap first moves once measured:
shorten events retention / prune the events collection; size-scaled
flush interval; hibernate after the known heavy sweeps. The full F1
journal rewrite stays a scheduled item, not an emergency patch.

## P1 — resume_mission hardening (before anyone calls it again)

- **Idempotency**: reject (or return the existing child of) a resume when
  an active mission already has `resumed_from == parent` — the timeout
  storm created four duplicates from two calls.
- **Async**: the handler currently seeds the worktree and advances
  synchronously (>60s under load → client timeout → server continues).
  Return the mission id immediately; run seeding+advance in a supervised
  Task; expose progress via show_mission.
- Docs: parameter is `id` (matches show_mission), not `mission_id`;
  note the timeout behavior; escript schema on next CLI release.

## P2 — Fix-loop economics (why runs die at the cap)

- **Validation ratchet**: persist accepted requirement ids on the mission
  record; each round's validator prompt pins them ("FR-1..4,6..13 are
  ACCEPTED — do not re-litigate; verify only the open set + typecheck/
  build always"). The last two runs died re-proving settled requirements.
- **.gitf-probe residue**: probe screenshots (boot.png/final.png) are
  committed by every fix op — same class as the lockfile leak. Write
  probe artifacts outside the worktree (or gitignore + residue-guard
  them). Side effect of the bug: churns the tree fingerprint, silently
  defeating the exec-validation verdict cache every round.
- Revisit attempt budget once the ratchet exists (4 may be right when
  rounds stop re-litigating).

## P3 — Deliver the feature (after P0, as the acceptance test)

Resume the lineage from `archive/msn-398fa4` (per doctrine, the fix
deploy IS the test). Entry state: validation, one known gap (FR-5 sort
weighting). No outcome promised; six failed runs say the next failure
mode is the unnamed one.

## P4 — Standing queue (unchanged priorities)

1. major.ex retry paths (~1105, ~1153) call plain Ghosts.spawn/4,
   bypassing predecessor_shell — the second route to sibling worktrees;
   didn't fire in observed runs but is live.
2. MCP socket listener unsupervised tasks (BEAM audit #5).
3. skills_enabled for cora — OPERATOR DECISION: turns the saga's lessons
   into future ghosts' starting instructions (cross-mission learning is
   built and off; within-mission FixContext already works).
4. War-story chronicle: acts 4–6 (runs 4, 5, the resume arc, the
   adoption trace) exist only in memory — writing pass pending.
5. Efficiency plan phases 2–3, BEAM audit batches 2–5 — unchanged.

## Ground rules carried forward

Deploy only with no active missions. Full re-run for orchestrator/
scheduler changes; resume for endgame/validation-lane changes; doubt
about inherited state ⇒ fresh run. Every fix lands with the test that
would have caught it. No optimism in reports — mechanisms with evidence,
or "unproven".
