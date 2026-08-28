# BEAM Best-Practices Audit — 2026-08-28

Six parallel reviewers audited the factory at `de52b39` (v0.65.210), one per
discipline: supervision architecture, GenServer discipline, concurrency/race
safety, error-handling philosophy, resource management, and idioms/contracts.
Every finding below was verified against source by the reviewer that filed it
(file:line references are to `de52b39`). ~66 findings survived; ~31 HIGH.

## Verdict

The architectural core is genuinely strong — the Archive's lock-free-read /
partitioned-writer design, the ghost worker lifecycle, scratch-worktree
merges, and timer discipline are all patterns worth showing off. The gaps are
not architectural; they are six recurring **discipline failures**, each
repeated across many sites, and each with at least one in-repo example of the
correct pattern to copy. The factory's biggest systemic risk today is that a
single crash in (or linked to) the Major cascades into killing every
in-flight ghost — and several independent HIGH findings feed that one drain.

## Theme A — Supervision wiring turns one crash into a fleet kill

1. **HIGH `application.ex:174-199` — `:rest_for_one` child order is inverted.**
   `SectorSupervisor` (ghosts) sits *after* `Major`, but ghosts don't depend
   on Major's pid (links go via PubSub and are replayed). A Major crash —
   or a crash in `RateLimiter`, child #1 — tears down every ghost; each
   worker's `terminate/2` then calls `Ops.fail/1`, marking the whole
   in-flight fleet failed. Fix: move `SectorSupervisor`/`MissionSupervisor`/
   `RateLimiter` before `Major`, or split into a `:one_for_one` infra
   supervisor + `:rest_for_one` Major group. **Must ship with A2.**
2. **HIGH `major.ex:121,1773-1798` — Major never rebuilds `active_ghosts`
   or monitors after restart.** Fixing A1 alone converts a fleet kill into a
   fleet *duplication*: restarted Major sees 0 active ghosts and over-spawns.
   Fix: on `handle_continue(:resume_active_quests)`, walk the Registry's
   `{:ghost, _}` entries, re-monitor, reseed the map.
3. **HIGH `major.ex:2043` — the API-mode agent loop runs under linked
   `Task.async` and Major does not trap exits.** Any raise in the loop kills
   Major (then A1 fires). Every other site in the file uses
   `Task.Supervisor.async_nolink` — this one missed. Result is also never
   awaited.
4. **HIGH `sync/queue.ex:313,195` — Sync.Queue uses linked `Task.async`,
   doesn't trap exits, and `Process.exit(task, :kill)` on merge timeout
   kills the queue itself**, losing `state.pending`; the `{:DOWN, ...}`
   crash handler at `:162` is unreachable dead code. Fix: `async_nolink`.
5. **HIGH `exfil.ex` + `application.ex:437` — graceful shutdown needs ~16s
   but the child spec allows 5s.** The drain sleeps 5s alone
   (`exfil.ex:129`); idle-stop SIGTERM brutal-kills Exfil mid-sleep and
   `stop_ghosts`/`stop_major` never run. Fix: `shutdown: 60_000` +
   deadline-aware drain. Related: **`archive.ex` terminate flush also has
   only 5s** (`application.ex:151`) — raise to 30s (flush is already
   tmp+rename, verified).
6. **MED-HIGH `application.ex:150-151` — a `TableHeir` crash silently
   disarms the ETS heir for every table** (heir reverts to `none`; nothing
   re-arms). Fix: `:rest_for_one` for the TableHeir/Archive/Writers triple,
   or re-arm via monitor + `:ets.setopts`.
7. **HIGH `mcp_server/socket_listener.ex:97` — accept loop and every MCP
   connection handler run under unsupervised `Task.start`;** a raise leaks
   the client socket (never closed) and nothing observes it. Fix:
   `Task.Supervisor.start_child` + `try/after :gen_tcp.close`.
8. **MED `plugin/mcp_client.ex:34-66,99-105`, `lsp/client.ex:448-469` —
   port-opening in `init/1` (raises → 3-strikes → supervisor cascade for all
   MCP clients), and both `terminate/2`s only `Port.close`, leaking the OS
   process** (the repo itself documents at `worker.ex:684` that close ≠
   kill). Fix: `handle_continue`, `restart: :transient`, `OsProc.terminate_async`.
9. **MED `application.ex:192` — `Ingestion.Watchdog` gets `File.cwd!()`
   instead of the resolved `gitf_root`, and its `init` uses `mkdir_p!`** — a
   read-only or wrong cwd aborts the entire daemon boot for an inbox watcher.
10. **LOW-MED grab bag:** `SocketListener` `:permanent` + `{:stop, :already_running}`
    restart-loops the Interface tree; channels `:permanent` under default
    3/5s DynamicSupervisor budget; `Exfil.do_shutdown` sets
    `Logger.configure(level: :none)` globally with no restore and
    `initiate/0` is publicly callable; `sector_supervisor.ex:29` doc says
    `:temporary` while code correctly uses `:transient`.

## Theme B — Singletons doing external work inline (the "Major blocked 15 min" class)

1. **HIGH `major.ex:775-838` — the merge-conflict link handler runs
   `git rebase` + the sector validation command (up to 30 min) + an LLM
   review + `sync_back` synchronously inside Major's `handle_info`.** While
   blocked, the Janitor's stall probe times out and maps to "ok" — the one
   watchdog that would notice is disabled by the stall itself. Fix: move to
   `async_nolink` keyed by shell_id (template already at `major.ex:699-713`).
2. **HIGH `major/orchestrator.ex` — `advance_quest/1` executes inside
   Major:** branch consolidation, `npm run bindings`, and
   `run_exec_validation` under a `:global` sector lock acquired with
   **`:infinity`** — Major can block indefinitely behind Tachikoma's audit.
   Fix: split decision (in Major) from effects (in a supervised task);
   bound the lock wait.
3. **HIGH `tachikoma.ex:301-354` — the 30s patrol calls `Audit.verify_job`
   inline** (sector lock + full validation run per op, sequential). The same
   module does it right at `:172-193`. Fix: fan out per-op via
   `Task.Supervisor.start_child` + in-flight MapSet.
4. **HIGH `runtime/gemini_cache_manager.ex:44-106` — synchronous `Req.post`
   inside `handle_call` behind the caller's default 5s timeout**: cache-miss
   >5s makes every caller exit while ghosts serialize behind a singleton on
   the LLM hot path. Fix: reply-later + task + in-flight dedup.
5. **MED `major/janitor.ex:141,480-504` — advances every live mission
   inline+serially every 3 min** (each can trigger B2's full chain); its
   `check_debriefs` neighbor already fans out correctly.
6. **MED `major.ex:1366-1502` — every 15s spawn tick shells `df` +
   `git status` + probe-file write inline, no timeouts** (Tachikoma wraps
   the identical `df` in `Task.yield`). Fix: cached verdict refreshed by a
   background task.
7. **MED `budget/watchdog.ex:37-165` — 10s timer folds the entire costs
   collection once per mission** (O(missions × costs) forever) and stops
   ghosts serially with 2s calls. Fix: cost index/roll-up, task fan-out,
   longer interval.
8. **MED `major.ex:68,2027` — `launch/0` runs sparse-checkout git commands
   inside `handle_call`** with the caller's 5s default → split-brain when
   setup exceeds it.
9. **LOW `outcomes/tracker.ex:101-110` — tick blocks on
   `Task.async_stream |> Stream.run()`** (fine today, ~8 min at 200 open
   outcomes); `archive.ex:407` init loads the full store + migrations before
   the supervisor proceeds (move to `handle_continue`).

## Theme C — The sector lock is fragmented; run-7's corruption class is still open through three doors

1. **HIGH `tachikoma.ex:314-318` — the audit task is killed at
   `Task.yield(60_000)` while the sector validation budget is 120s-30min.**
   The kill releases the `:global` lock (dies with holder) but not the
   `npm ci` OS child (only the inner `timeout -k` reaps it, up to 115s
   later) — the next lock holder starts a second `npm ci` in the same tree.
   This is exactly run-7's corruption, re-enabled. Fix: kill budget >
   validation budget, or move lock ownership out of the killable task.
2. **HIGH `debrief.ex:74` — regression checks build in the shared clone
   with no lock at all** (the Resolver's comment names this exact race; only
   the resolver side was fixed). False "regressions" spawn follow-up
   missions and trust penalties.
3. **HIGH two disjoint lock namespaces guard the same trees:**
   `WorktreeLock` (`:global`) vs `{:sync_lock, sector_id}` (Registry,
   `sync.ex:331`, `resolver.ex:644`) — holders are mutually invisible; and
   `validator.ex:32` `validate/1` takes neither. Fix: one lock; route
   Sync/Resolver/Validator/Debrief through `WorktreeLock`.
4. **LOW-MED `worktree_lock.ex` moduledoc is wrong about nesting:** nested
   `:global.trans` with the same key doesn't deadlock — the inner release
   **silently drops the lock** while the outer body continues unprotected.
   Add a reentrancy depth counter before Theme-C fixes make nesting likely.
   Also `resolver.ex:643` retries once/500ms then gives up
   (`:sync_lock_contention`) while `sync.ex:335` loops properly.

## Theme D — Guards that fail open on exception (rescue disarms the safety)

Baseline: 685 rescues in lib/; 363 are blind `rescue _ ->`; only ~11% name
an exception type; 37 log at `:debug`.

1. **HIGH `quality/security.ex:95-178` + `quality.ex:54` — every dependency
   scanner returns `[]` on crash or missing tool, and `[]` scores 100.**
   There is no path by which scanner failure produces a non-clean verdict.
   Fix: propagate `available: false` (static analysis already does);
   `audit.ex:387` treats unavailable as inconclusive.
2. **HIGH `major/orchestrator.ex:301-322` — the mission cost-cap snapshot
   rescues to `{20.0, 0.0}`;** spent=0 means one malformed cost record
   permanently disarms `over_budget?` for **all** missions. Fail closed.
3. **HIGH `major.ex:1366-1426` — spawn preflight health/git checks rescue
   to healthy** with zero logging (the fail-closed counterexample is 100
   lines away at `:1473`).
4. **HIGH `observability/health.ex:62-83,139-141` — the zombie-liveness
   probe returns `true` (alive) when the probe raises**; disk check same
   shape. The repo's own correct pattern is `tachikoma.ex:530-536`.
5. **HIGH `tachikoma.ex:273-384` — budget/merge-conflict/verification
   patrol checks return `[]` (all clear) on any raise;** one bad record
   blinds the whole check for all missions. Per-item try + error finding.
6. **HIGH `workflow/advancer.ex:152-199` — a raised phase-`verdict/2`
   silently falls back to the generic verdict computation** (no log): a
   tournament-handler bug reroutes mission advancement on stale artifacts,
   invisibly. Log + `:wait`.
7. **HIGH `ghost/worker.ex:2185-2239` — model-fallback failures log at
   `:debug` and the Archive.update result is a dead statement** (fallback
   respawns with wrong `assigned_model` attribution on update failure).
8. **MED:** Major link handlers `rescue _ -> state` with no log
   (`major.ex:936,952,1024` — a dropped clarification timer strands a ghost
   forever); credentials-load failure logs at `:debug` (`runtime/keys.ex:62`);
   `Ops.reset` discards `Shell.remove`/update results and returns `:ok`
   regardless (`ops.ex:278-294`); `run_exec_validation` returns `nil` for
   both "not configured" and "crashed" (`orchestrator.ex:1194-1200`) so the
   infra guard it feeds never sees the crash; provider resolution silently
   defaults to `"google"` (`model_resolver.ex:89,134`, `medic.ex:196`), and
   `validate_config/0` itself ends `rescue _ -> :ok` (`application.ex:557`).

## Theme E — Read-modify-write races and Archive internals

1. **HIGH `archive.ex:299-306` — `route_write`'s `catch :exit, _` fallback
   double-applies writes on timeout:** the writer still has the message
   queued; the inline apply runs concurrently outside serialization
   (counters jump by 2, index bags go stale). Fix: rescue only
   `{:noproc,_}`/`{:shutdown,_}`; let `:timeout` propagate.
2. **HIGH `archive.ex:884-926` — the heir does not preserve data:**
   `init_store` claims tables then deletes them and reloads from ≤1s-stale
   disk; concurrent lock-free inserts land in tables being wiped. Moduledoc
   claim ("keeps data alive across restart") is false. Fix: use claimed
   tables as source of truth, gate writers during re-init, fix the doc.
3. **MED-HIGH `ghost_id.ex:41-66` — model reputation counters are
   get→put** (lost increments under parallel ghosts; dup rows from
   `find_one`→`insert`). Convert to `Archive.update/3`.
4. **MED-HIGH `audit.ex:179-281` — verification writers `Archive.put` an
   op snapshot taken before a 30-min validation run**, reverting concurrent
   `Ops.reset` transitions (resurrects ghost_id, corrupts status index).
   Same shape at `resilience.ex:212`, `intel/retry.ex:247`,
   `sync/queue.ex:340`, `trust.ex:143`, `ops.ex:786`, `ghosts.ex:486,790`,
   `runtime/context_monitor.ex:56`, `run.ex:203`.
5. **MED `archive.ex:386-388`, `indexes.ex:107-108` — index updated after
   main table, delete-old before insert-new:** lock-free readers can see a
   record in neither status bucket. Insert-new-first.
6. **MED `archive.ex:869-874` — collection registry is a persistent_term
   get→put race on the insert hot path** (also a global-heap-scan latency
   cliff per put).
7. **MED snapshot sweeps `put` stale records over concurrent writers:**
   `sector.ex:411-425`, `shell.ex:196-218`, `exfil.ex:98-105`,
   `override.ex:243-265` — convert to per-record `Archive.update` deriving
   from `current`.
8. **MED-HIGH `archive.ex:211-216` — `filter/find_one/count` TOCTOU:**
   table deleted between `whereis` and `foldl` (every Archive restart)
   raises ArgumentError in arbitrary caller processes; `all/get` are
   protected, these aren't.

## Theme F — Resource management and hot-path scans

1. **HIGH `archive.ex:446-536` — the 1s flush re-serializes the ENTIRE
   dirty collection** (tab2list → Map → term_to_binary → whole-file write);
   `:ops`/`:missions` are never pruned, so cost is O(history) per second.
2. **HIGH `tui/app.ex:104-1149` — the TUI materializes every ghost's full
   log file (no rotation, can be 100s of MB) twice per 500ms tick.** True
   tail + mtime cache.
3. **HIGH `report.ex:125`, `api_controller.ex:879` — whole-log
   `File.read` per op in report/HTTP paths.**
4. **HIGH `ghost/worker.ex:757-779` — the event-cap re-measures
   `:erlang.external_size` over up to 2000 events on every port chunk**;
   carry running byte count instead.
5. **HIGH `budget.ex:176,277,377` — `Archive.all(:costs) |> filter` on the
   pre-spawn check and the 10s watchdog** — the documented 1.3GB
   anti-pattern, on the hot path. Use `Archive.filter/2`/indexes.
6. **HIGH `major.ex:1836-1838` — spawn cycle copies `:missions`, `:ops`,
   `:op_dependencies` in full every 15s** into Major's heap (no hibernate);
   the `:status` index already exists and is ignored. Similar unindexed
   scans: `Link.list` full-table sort in Major every 30s
   (`major.ex:1991`, `link.ex:57-83`); `Ghosts.list` full sort per 2s spawn
   stagger (`ghosts.ex:250`, `:ghosts` never pruned); mission-source dedup
   linear scan per webhook (`aramaki/intake.ex:84`); `event_store.ex`
   list/replay/timeline.
7. **MED-HIGH `major/janitor.ex:117` + `infra/cache_lifecycle.ex:119,143` —
   bare `System.cmd` `du`/`npm cache verify` (minutes on a 7GB tree) block
   the Janitor.** Other untimed `System.cmd`: `loadout.ex:402` (`gh` — an
   agent tool, network), `github.ex:549`, `github/cli.ex:256`,
   `ollama.ex:33`, `tui/app.ex:1068`.
8. **MED-HIGH `skills/embedding.ex:114-143` — query-embedding ETS cache
   has no eviction** and caches *queries*, not just documents.
9. **MED `web/rate_limit_plug.ex:36-42` — rate-limit ETS keys include
   `window_start` and are never deleted** — unbounded growth on public
   endpoints.
10. **MED `runtime/agent_loop.ex:224-262` + `worker.ex:446-449` —
    heartbeats on every yield-timeout reset `last_activity_at`, so the 120s
    stale watchdog can never fire during a hung LLM/tool call**; only the
    1h wallclock backstop remains. Add absolute deadlines.
11. **MED `runtime/os_proc.ex:130-141` — `pkill -P` kills direct children
    only; grandchildren (MCP servers, node subagents) survive when the
    sandbox is unavailable** (which fails open by default). Janitor also
    uses blocking `terminate/2` instead of `terminate_async` and forks ~20
    procs per kill. Use setsid/process-group kill.
12. **LOW:** metrics eviction does a full `select_count` per insert
    (`observability/metrics.ex:262`); watchdog `escalation_count` map never
    pruned; `quality/performance.ex:51` user benchmark has no OS-level
    `timeout -k`; sub-binary slices stored to ETS without `:binary.copy`
    (`debrief.ex:111`, `validation.ex:566`, `sync.ex:299`,
    `publish.ex:418` — worker.ex does it right).

## Theme G — Contracts, duplication drift, and atom safety

1. **HIGH `major.ex:1778-1779` — `resume_active_quests` hand-rolls the
   finished-status list, omitting `paused_budget`/`closed`/`killed`:
   restarts resurrect budget-paused missions and spend past their caps.**
   Use `Missions.active?/finished?` (the canonical list at `missions.ex:32`).
2. **HIGH — Dialyzer is not configured at all** (no dialyxir, no CI step);
   several specs are provably wrong and nothing catches them.
3. **HIGH `github.ex` (11 specs) — reference `GiTF.Schema.Sector.t()`,
   which does not exist; all `GiTF.Schema.*` structs are dead code**
   (zero construction sites). Either delete the schemas or make Archive
   hydrate through them — not both worlds.
4. **MED-HIGH atom-table DoS:** `provider_manager.ex:491,508`,
   `provider_circuit.ex:490` call `String.to_atom` on MCP tool arguments /
   model-spec prefixes; `workflow/schema.ex:385-393` mints atoms from
   dashboard-editable YAML handler names. `GiTF.SafeAtom` exists for
   exactly this and is used once.
5. **MED terminal-phase list drift:** `handlers.ex:12` is missing
   `"failed"` (permanently-red `stuck_count` in factory_status);
   `missions.ex:506` uses a `"terminal"` phase no writer sets; moduledoc
   documents the drift but the MCP copy was never migrated.
6. **MED `project.ex:206-209` — the only strict-match `Archive.update` call
   site of 69** raises MatchError on `{:error, :not_found}` in the
   mission-terminal path; `sync.ex:562` hard-matches `get_head/1` inside
   the sector lock (unborn HEAD / git timeout → MatchError instead of the
   documented error tuple).
7. **MED `config/runtime.exs:7,120,124` — boot raises on `LOG_LEVEL=INFO`,
   non-numeric `GITF_PORT`, or `GITF_HOST=localhost`** with config-provider
   stacktraces instead of named errors.
8. **MED string/atom dual-key defensive reads (`phase_collector.ex`,
   `lsp/edits.ex`, `review_intake.ex`, `loadout.ex`)** hide producer-shape
   divergence — `session_complete?` matches string keys only, so an
   atom-keyed plugin event hangs the ghost while the collector happily
   reads it. Normalize once at the boundary.
9. **LOW:** three live `:timeouts` keys undocumented in config.exs
   (`stuck_mission_threshold_ms`, `events_poll_interval_ms`,
   `cache_maintenance_interval_ms`); `Git.safe_cmd/2` (most-called function)
   has no spec.

## What is already exemplary (preserve; use as templates)

- **Archive reads**: lock-free ETS `get/all/filter/fold`, `find_one` with
  early throw, and the moduledoc explaining the 1.3GB lesson
  (`archive.ex:148-264`); dirty-mark ordering + tmp/rename persistence
  (`:501-536`); conditional hibernate after real flushes (`:437-455`);
  partitioned per-collection writers (`:299-306`).
- **Ghost.Worker lifecycle**: trap_exit with incident rationale, instant
  init → `handle_continue(:provision)`, send_after backoff instead of
  sleep, `safe_git_cmd` bounding every shell-out, output caps with
  `binary_part` + `:binary.copy` (`worker.ex:163-218,728-743,1792-1810`).
- **`async_nolink` discipline** nearly everywhere, with reasoning written
  down (`major.ex:695-713`, `worker.ex:1789`, `janitor.ex:433`,
  `github/cli.ex:130-200`).
- **Scratch-worktree merges**: shared clone only advances by `--ff-only`;
  kills strand only disposable dirs (`resolver.ex:139-165,290-345`).
- **Ops state machine** under `Archive.update` with `validate_transition`
  (`ops.ex:147-274`); atomic counters via `update_matching`
  (`run.ex:92-119`).
- **`timeout -k` inside the sandboxed command** because Task.shutdown can't
  kill OS children (`validator.ex:149-162`); bubblewrap `--die-with-parent`;
  `OsProc` SIGTERM→grace→SIGKILL with an async variant.
- **`GiTF.Phase` behaviour** with optional callbacks, documented verdict
  type, and conformance-checked dispatch; **`GiTF.SafeAtom`**;
  **config via `:persistent_term`** with zero hot-path file reads; the
  data-driven boolean-flags table in runtime.exs; honest irregular specs in
  `git.ex` (31/32 coverage).
- **Timer discipline**: reschedule-after-work everywhere; cancel-before-
  replace for clarification timers; no duplicated-timer defects found.
- **Correctly-narrow rescues**: `archive.ex` ArgumentError-only rescues +
  the documented decision NOT to rescue fold predicates;
  `resolver.ex:635-641` fail-closed with the incident recorded;
  `audit_log.ex:37-45` rescue+catch-exit fire-and-forget with rationale.

## Recommended fix order

- **Batch 1 — crash-cascade + money/safety fail-open (highest leverage):**
  A1+A2 together, A3, A4, G1, D1, D2, D3, D4, C1. Small diffs, each
  independently testable; re-run group-pr-list-by-author as acceptance.
- **Batch 2 — lock unification + Archive integrity:** C2, C3, C4, E1, E2,
  E3, E4 (top sites), A5, A6.
- **Batch 3 — singleton offloading:** B1, B2, B3, B4 (the Major/Tachikoma/
  GeminiCache refactors; larger, need care).
- **Batch 4 — hot-path scans + growth:** F1, F2, F4, F5, F6, F8, F9;
  add `:links`/`:ghosts`/`:costs` indexes and prune `:ghosts`.
- **Batch 5 — contracts:** G2 (dialyxir + CI), G3, G4, G5, G7; delete or
  adopt the Schema structs.
