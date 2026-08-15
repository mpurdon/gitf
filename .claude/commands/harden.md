---
description: Audit Elixir/OTP code for concurrency bugs, race conditions, supervision gaps, and reliability/resilience issues
argument-hint: "[file paths or 'diff' — defaults to git diff]"
---

# Harden: Elixir/OTP Reliability & Resilience Audit

Review the codebase for concurrency bugs, race conditions, resilience gaps, and reliability issues using Elixir/OTP best practices.

## Phase 1: Identify Scope

Run `git diff` to find changed files, or review files specified by the user. If no scope is given, focus on the core pipeline: ghost/worker.ex, major.ex, orchestrator.ex, ops.ex, missions.ex, archive.ex, tachikoma.ex, sync.ex.

## Phase 2: Launch Audit Agents in Parallel

**MANDATORY: Launch ALL 12 agents below in a single message with parallel Agent tool calls. Do not skip any agent, even if it seems unlikely to apply (e.g., LiveView/Phoenix on a non-web change). Skipping is the user's call, not yours — agents that find nothing simply report "N/A" and cost nothing meaningful. Token cost is irrelevant; coverage is the point.**

Pass the diff or file list to each. Each agent must report findings classified CRITICAL/HIGH/MEDIUM/LOW with file:line citations, or explicitly state "N/A — no relevant surface in scope."

### Agent 1: Shared State & Concurrency

Search for read-modify-write patterns on Archive (ETS-backed store) and shared state issues:

1. **Non-atomic RMW**: `Archive.get` followed by `Archive.put` in the same function — should use `Archive.update/3` instead
2. **Cross-process writes**: Multiple GenServers writing to the same Archive record (ops, missions, shells) — identify which process should own each record
3. **Status derivation TOCTOU**: Reading a collection, computing derived state, then writing back — the collection may have changed between read and write
4. **Last-write-wins**: Two processes both read the same record, modify different fields, and put back — second writer overwrites first writer's changes
5. **Enum on stale data**: Iterating a collection while another process modifies it — ETS snapshots are consistent per-read, but multi-step logic may see different snapshots
6. **Deadlocks**: Nested locks (MissionLock inside Archive lock, or two processes each holding one lock waiting for the other)
7. **Lock contention patterns**: `:skip` on contention silently drops work — should it `:queue` or retry?

### Agent 2: Process Lifecycle & Supervision

Review OTP patterns:

1. **Linked processes**: `Task.async` (linked) vs `Task.async_nolink` (monitored) — linked tasks crash the caller on failure. Check all Task usage for appropriate choice
2. **Process registration races**: Two processes trying to register the same name in Registry
3. **GenServer mailbox ordering**: Messages from multiple sources arriving in unpredictable order — are there implicit ordering assumptions?
4. **Supervisor restart cascading**: A child crash that triggers sibling restarts — check `:one_for_one` vs `:rest_for_one` vs `:one_for_all` choices
5. **State recovery after restart**: GenServers that rebuild from Archive on init — is the rebuild correct after a mid-operation crash?
6. **Stale process references**: PIDs stored in ETS/Archive that become invalid after process restart
7. **GenServer bottlenecks**: Single GenServer handling too many concurrent requests — should it delegate to Task.Supervisor?
8. **init/1 side effects**: Blocking calls in GenServer init that delay supervision tree startup — use `handle_continue` for async initialization
9. **Terminate cleanup**: Resources that need cleanup (ports, files, worktrees) — is `terminate/2` implemented and called?
10. **Hot code reload safety**: State shape changes between deploys — does the GenServer handle old state formats?

### Agent 3: Message Delivery & Consistency

Review PubSub and inter-process communication:

1. **Fire-and-forget without fallback**: PubSub.broadcast with no durable backup — if the subscriber is down, the message is lost
2. **Duplicate delivery**: Same event delivered via multiple paths (PubSub + GenServer.cast + Link) — are handlers idempotent?
3. **Ordering guarantees**: Code that assumes message A arrives before message B — PubSub doesn't guarantee ordering
4. **Silent failures**: `rescue _ -> :ok` that swallow errors without logging — every rescue should log at minimum
5. **Timeout handling**: `Task.yield` / `Task.shutdown` — what happens to in-flight work when a timeout fires?
6. **Backpressure**: Producers sending faster than consumers can process — are there mailbox size limits or flow control?
7. **Message pattern exhaustiveness**: `handle_info` catch-all clauses — do they log unhandled messages for debugging?
8. **Cast vs Call**: `GenServer.cast` for operations that should confirm success — use `call` when the caller needs to know the result

### Agent 4: Data Integrity & Error Handling

Review error paths:

1. **Partial writes**: A multi-step operation that fails midway — is there rollback or is data left inconsistent?
2. **Nil propagation**: Functions that return nil on error instead of {:error, reason} — callers may not handle nil
3. **String.to_existing_atom**: Safe, but only if the atom was previously loaded — check all uses
4. **Unbounded growth**: ETS tables, Archive collections, or process mailboxes that grow without pruning
5. **Error atoms**: `:not_found` vs `:error` vs `nil` — inconsistent error signaling across modules
6. **with-chain error handling**: `with` clauses that fall through to `else` but don't pattern match all error shapes — missing error cases silently return the raw error tuple
7. **DateTime comparison**: Using `>` or `<` on DateTimes instead of `DateTime.compare/2` — struct comparison doesn't work as expected
8. **Map.get vs pattern match**: Using `Map.get(m, :field)` when `m.field` would crash on missing keys — choose deliberately between safe access and fail-fast
9. **Float arithmetic**: Accumulated floating point errors in cost calculations — use `Decimal` or `Float.round` at boundaries

### Agent 5: External System Resilience

Review interactions with external systems (git, GitHub API, LLM providers, filesystem):

1. **Timeout on external calls**: Every `System.cmd`, `Req.get/post`, and `gh` CLI call should have a timeout — check for missing timeouts
2. **Retry with backoff**: Transient failures (network, rate limits) should retry with exponential backoff, not fail immediately
3. **Circuit breaking**: Repeated failures to the same external system should trigger a circuit breaker, not keep hammering
4. **Resource cleanup on failure**: If a git worktree is created but the subsequent operation fails, is the worktree cleaned up?
5. **Filesystem atomicity**: Writing files via `File.write` is not atomic — use write-to-temp + rename for critical files
6. **Git lock contention**: Multiple processes running git commands in the same repo — is there coordination?
7. **API rate limiting**: Are LLM API calls, GitHub API calls, and git operations rate-limited to prevent throttling?
8. **Credential handling**: Are API keys read from config at call time (not cached at compile time)? Do they rotate safely?

### Agent 6: Observability & Debuggability

Review whether failures are visible and diagnosable:

1. **Silent success/failure**: Operations that succeed or fail without any log, telemetry event, or state change visible to the operator
2. **Log levels**: Errors logged at `:debug` or `:info` instead of `:warning` or `:error`
3. **Structured logging**: Log messages that include the entity ID (mission_id, op_id, ghost_id) for correlation
4. **Telemetry coverage**: Key operations (phase transitions, ghost spawn/complete, sync attempts, PR creation) should emit telemetry events
5. **Timeline gaps**: Operations that don't record EventStore entries — are there phases or decisions invisible in the mission timeline?
6. **Health check coverage**: Does the health endpoint detect all failure modes? (stuck missions, hung ghosts, exhausted resources, stale data)
7. **Error context**: When an error is logged, does it include enough context to reproduce? (inputs, state, stack trace)
8. **Metric cardinality**: Metrics with unbounded label values (e.g., per-ghost-id metrics) — these explode time series databases

### Agent 7: BEAM-Specific Memory & Performance

Review for BEAM VM-level pitfalls:

1. **Binary reference leaks**: Pattern matching or slicing a small piece of a large binary keeps the entire parent alive — use `:binary.copy/1` to release the reference
2. **Large state in GenServer**: GenServer state is copied on every `handle_call` reply — move large data to ETS, keep GenServer state small
3. **Large messages between processes**: Inter-process messages are deep-copied (except large binaries) — send ETS keys instead of full data
4. **God GenServer bottleneck**: Single GenServer handling all traffic serializes concurrency — decompose or use `PartitionSupervisor`
5. **GenServer used for code organization**: No mutable state, no concurrency need — should be a plain module with functions
6. **Task.await inside GenServer callback**: Blocks the GenServer for the task duration — use async task + `handle_info` for the result
7. **Synchronous call cascades**: GenServer A calls B calls C — tail latency compounds, risk of deadlock if cycles exist
8. **`:persistent_term` for frequently-updated data**: Updates trigger GC across ALL processes that read the old value — use ETS instead
9. **String concatenation in hot loops**: `<>` allocates a new binary each time (O(n^2)) — use IO lists and `IO.iodata_to_binary/1`
10. **`Enum` pipeline on large collections**: Multiple `Enum.map |> Enum.filter` creates intermediate lists — use `Stream` for large/lazy processing
11. **Dynamic atom creation**: `String.to_atom/1` on unbounded input exhausts the atom table (never GC'd) — use `String.to_existing_atom/1` or keep as strings

### Agent 8: Supervision & Application Lifecycle

Review supervision tree design and application startup:

1. **Flat supervision tree**: All GenServers under one supervisor — unrelated crashes share restart intensity budget. Group by failure domain.
2. **Default restart intensity**: `max_restarts: 3, max_seconds: 5` is rarely appropriate — tune per supervisor based on expected failure mode
3. **No recovery strategy design**: Supervisor added without answering "what happens when this child restarts with blank state?"
4. **ETS table ownership death**: Process that created the ETS table dies → table deleted → readers crash. Use a dedicated table-owner process or `heir` option.
5. **Long-running work in Application.start**: HTTP calls, migrations, or cache warming in app start — blocks boot, fails the release. Use async Task under supervision.
6. **Compile-time vs runtime config**: `Application.get_env/2` in module attributes captures at compile time — use inside functions for runtime config
7. **Hardcoded timeouts**: Magic numbers (`5_000`, `30_000`, `:infinity`) scattered throughout — define as module attributes or config, make tunable
8. **Unlinked/unsupervised processes**: `spawn/1` or `Task.start/1` for fire-and-forget — crashes are invisible. Use `Task.Supervisor.start_child/2`.
9. **Process.sleep for coordination**: Fixed-time waits for another process — use monitors, messages, or Registry lookups with retries instead
10. **Spawned processes that leak resources**: Processes holding file handles/ports without `terminate/2` cleanup — resources leak on crash

### Agent 9: Phoenix LiveView Patterns (if applicable)

Review LiveView-specific patterns:

1. **Fat assigns**: Large data in socket assigns — increases memory per connection and diff computation. Use temporary assigns for lists.
2. **Blocking handle_event**: DB queries or API calls in handle_event freeze the UI — delegate to async Task, return loading state immediately
3. **PubSub thundering herd**: Broadcast causes all LiveViews to query DB simultaneously — include data in the broadcast payload instead
4. **Double-mount subscription**: Subscribing in mount without `connected?/1` guard — creates orphaned subscription on static render
5. **N+1 in streams**: Processing stream items individually with per-item queries — batch and preload

### Agent 10: Phoenix Framework & Endpoint Hardening

Review Phoenix-specific production patterns:

1. **Secret key base**: Hardcoded or committed `secret_key_base` — must be generated per environment via `mix phx.gen.secret`
2. **CSRF protection gaps**: Custom forms or API endpoints missing CSRF tokens — check `:protect_from_forgery` plug and `csrf_meta_tag`
3. **Endpoint configuration**: `check_origin` disabled or overly permissive — allows WebSocket hijacking in production
4. **Static asset cache headers**: Missing cache-control headers on static files — causes repeat downloads. Phoenix sets these by default but custom static paths may miss them
5. **JSON serialization of large payloads**: Returning unbounded lists from API endpoints — always paginate or limit
6. **Router pipeline composition**: Plugs in the wrong pipeline (e.g., session plug in API pipeline, or missing auth plug)
7. **WebSocket connection limits**: No per-IP connection limiting on LiveView WebSocket — one client can open thousands
8. **Error view information leakage**: Development error pages showing stack traces in production — ensure `debug_errors: false`
9. **Body read limits**: Missing `:length` option on `Plug.Parsers` — allows arbitrarily large request bodies
10. **Endpoint drain on shutdown**: `drainer` option not configured — kills active connections on deploy instead of graceful drain
11. **Cookie security**: Missing `secure: true`, `same_site: "Lax"`, or `http_only: true` on session cookies in production
12. **Rate limiting on endpoints**: No rate limiting on API or form submission endpoints — vulnerable to abuse
13. **Plug.Static path traversal**: Custom static paths that don't restrict to specific directories — can leak filesystem contents
14. **LiveView token expiry**: Default token max_age for LiveView sessions — if too long, stale sessions accumulate; if too short, users get disconnected

### Agent 11: Platform & Deployment (macOS vs Linux)

Review for platform-specific issues that cause "works on my Mac, breaks in production":

1. **File path case sensitivity**: macOS HFS+ is case-insensitive by default, Linux ext4 is case-sensitive. A module `MyApp.HTTPClient` in file `http_client.ex` works on macOS but fails on Linux if there's a case mismatch.
2. **File descriptor limits**: macOS default `ulimit -n` is 256, Linux is typically 1024+. A system spawning many ports/sockets hits macOS limits first. Production should set `ulimit -n 65536`.
3. **System.cmd availability**: `git`, `gh`, `claude` CLI tools assumed to be on PATH — verify they exist before calling, or fail with a clear error message
4. **Filesystem watching**: `fs` (inotify on Linux, FSEvents on macOS) behaves differently. Linux has a per-user inotify watch limit (`/proc/sys/fs/inotify/max_user_watches`).
5. **Port/socket binding**: macOS allows binding to the same port from different processes in some cases. Linux does not. Test with `SO_REUSEADDR`/`SO_REUSEPORT` explicitly.
6. **Path separators and temp dirs**: `System.tmp_dir/0` returns different paths. Code using hardcoded `/tmp` breaks on non-standard setups.
7. **Signal handling**: `System.cmd` + signals work differently. `Port.close` sends `SIGHUP` on some platforms, `SIGTERM` on others. The ghost kill_handle behavior may vary.
8. **DNS resolution**: macOS uses mDNS (.local), Linux uses /etc/hosts then DNS. Hostname resolution timing differs — affects any code with connect timeouts.
9. **Memory limits**: macOS has no cgroups. Linux production with Docker/systemd may have memory limits that trigger OOM killer on the BEAM. Set `+MBas aobf` (abort on BEAM alloc failure) or use `memsup` from `:os_mon`.
10. **Time resolution**: `System.monotonic_time` resolution differs between macOS (microsecond) and Linux (nanosecond). Code using monotonic time for ordering/uniqueness may behave differently.
11. **Git behavior differences**: Git on macOS (Apple Git) vs Linux (upstream Git) have subtle differences in default behavior (e.g., credential helpers, line endings, symlink handling).
12. **Locale and encoding**: macOS defaults to UTF-8 everywhere, some Linux distros default to ASCII. `System.cmd` output encoding may differ. Always set `LC_ALL=en_US.UTF-8`.
13. **Native dependency compilation**: NIFs and ports compiled on macOS (arm64/x86_64) don't work on Linux. Releases must be built on the target architecture or use cross-compilation.
14. **Firewall and network**: macOS has app-level firewall prompts that block port binding silently. Linux has iptables/nftables. Docker on macOS runs in a Linux VM with port forwarding.

### Agent 12: Release & Production Readiness

Review for release and deployment readiness:

1. **Mix vs Release**: Running `mix phx.server` in production — should use `mix release` for self-contained deployments with no compilation step
2. **Runtime configuration**: `config/runtime.exs` not used — environment variables read at compile time via `config/prod.exs` are baked into the release
3. **Health check endpoint**: No `/health` or `/ready` endpoint for load balancer probes — the system is invisible to infrastructure
4. **Graceful shutdown**: No `SIGTERM` handler or connection draining — deploys drop active requests. Use `Plug.Cowboy.Drainer`
5. **Log level configuration**: Hardcoded `Logger.level` — should be configurable at runtime for production debugging without redeploy
6. **BEAM VM flags**: Missing production-tuned flags: `+sbwt none` (scheduler busy wait), `+P 1000000` (process limit), `+Q 1000000` (port limit)
7. **Crash dump location**: Default crash dump goes to cwd which may not be writable in production — set `ERL_CRASH_DUMP` env var
8. **Observer/remote console access**: No way to attach to running node for debugging — configure `--remsh` or `IEx.configure(inspect: [limit: :infinity])`
9. **Hot upgrade path**: Code that assumes fresh state on deploy — processes keep old state across hot code reloads unless explicitly handled
10. **Dependency audit**: `mix hex.audit` not run — published CVEs in dependencies go unnoticed
11. **Dialyzer in CI**: `@spec` annotations without Dialyzer enforcement — types are documentation only, not verified
12. **Database connection pool sizing**: Pool size not tuned for expected concurrency — too small causes timeouts, too large wastes connections

## Phase 3: Fix Issues

Wait for all agents to complete. For each finding:
- Classify as CRITICAL (data loss/corruption), HIGH (stalling/deadlock), MEDIUM (inconsistency), LOW (cosmetic)
- Fix CRITICAL and HIGH issues directly
- Note MEDIUM and LOW for future passes
- For each fix, explain why it's the idiomatic Elixir solution

## Elixir-Idiomatic Solutions Reference

| Anti-pattern | Idiomatic Fix |
|---|---|
| Read-modify-write on ETS | `Archive.update/3` (atomic under file lock) |
| Multiple writers to same record | Single-owner GenServer or atomic update |
| Fire-and-forget messaging | Durable Link + periodic recovery sweep |
| Duplicate message handling | Idempotent handlers (check if already processed) |
| Process crash loses state | Checkpoint to Archive, rebuild on init |
| Linked Task crash kills caller | `Task.async_nolink` + `{:DOWN, ...}` handler |
| Silent error swallowing | `rescue e -> Logger.warning(...)` at minimum |
| Blocking init/1 | `{:ok, state, {:continue, :async_init}}` pattern |
| Unbounded mailbox growth | `Process.info(self(), :message_queue_len)` monitoring |
| No backpressure | `GenStage` or manual demand with `send_after` throttling |
| External call without timeout | `Task.async_nolink` + `Task.yield(timeout)` + `Task.shutdown` |
| Non-atomic file writes | Write to `.tmp` + `File.rename` (atomic on same filesystem) |
| Nested try/rescue | `with` chains + tagged error tuples for structured error handling |
| DateTime comparison with operators | Always use `DateTime.compare/2` — struct comparison is lexicographic |
| Float accumulation errors | `Float.round/2` at boundaries, or use `Decimal` for money |
| Stale ETS cache | `Archive.update/3` reads inside lock, not from cache |
| Binary reference leak | `:binary.copy/1` on small slices of large binaries |
| Large GenServer state | Move hot/large data to ETS, keep GenServer state small (refs only) |
| Large inter-process messages | Write to ETS, send only the key |
| God GenServer | Decompose by responsibility, or use `PartitionSupervisor` |
| String concat in loops | IO lists: `[part1, part2]` → `IO.iodata_to_binary/1` |
| Dynamic atom creation | `String.to_existing_atom/1` or keep as strings |
| Task.await in GenServer | Async task + `handle_info({ref, result})` pattern |
| GenServer call cascades | Flatten chains, use cast+reply, or mediator process |
| PubSub thundering herd | Include data in broadcast payload, not just a "refresh" signal |
| ETS table ownership death | Dedicated table-owner process or `heir` option |
| Flat supervision tree | Group by failure domain under intermediate supervisors |
| Compile-time config capture | Call `Application.get_env/2` inside functions, not module attributes |
| Secret key base committed | `mix phx.gen.secret` per environment, never in source control |
| No endpoint drain | `Plug.Cowboy.Drainer` for graceful shutdown on deploy |
| Missing CSRF on custom forms | `:protect_from_forgery` plug + `csrf_meta_tag` in layout |
| WebSocket origin not checked | `check_origin: true` in endpoint config for production |
| No rate limiting | `Hammer` or custom `Plug` with token bucket per IP |
| Case-sensitive path mismatch | Match module name casing to filename exactly — test on Linux |
| File descriptor exhaustion | `ulimit -n 65536` in production, monitor with `:os_mon` |
| System.cmd without existence check | `System.find_executable/1` before `System.cmd/3` |
| Running mix in production | `mix release` for self-contained deployments |
| Hardcoded `/tmp` paths | `System.tmp_dir/0` for cross-platform compatibility |
| NIF compiled on wrong arch | Build releases on target architecture or cross-compile |
| No crash dump location set | `ERL_CRASH_DUMP=/var/log/app/crash.dump` env var |
| No remote console access | Configure `--remsh` node name for production debugging |
