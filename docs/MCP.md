# The gitf MCP — coverage, access patterns, implementation

The MCP is the **primary control surface** for the running factory
(CLAUDE.md: "Use the MCP, not the box"). This document is the contract:
what every factory-management use case maps to, how the access patterns
behave, and how the server is implemented. If a management task is not
answerable through a tool below, that is a coverage bug — file it against
this document rather than normalizing an SSM workaround.

## Coverage map: use case → tool

| Use case | Tool(s) | Notes |
|---|---|---|
| Is the factory up / what version | `health_check`, `factory_status` | `factory_status` adds recent failures + reliability_7d |
| Wake the box | *(none — CLI)* | `gitf wake`; MCP timeouts mean *asleep*, not broken |
| Create / start a mission | `create_mission`, `start_mission` | **Two steps, both `confirm: true`.** `start_mission fast: false` forces the full pipeline |
| Watch a mission | `show_mission`, `mission_timeline`, `list_ops` | `show_mission` includes ops, pipeline mode, provenance, and (since 0.65.226) `failure_reason` |
| Post-mortem a failure | `mission_diagnosis`, `show_artifact`, `show_op`, `ghost_output` | Diagnosis bundles artifacts + transitions; `show_artifact` reads a single phase artifact (incl. `exec_validation`, `conflict_markers`) |
| Kill / close / delete | `kill_mission`, `close_mission`, `delete_mission` | All `confirm: true`; killed missions notify the requester before deletion |
| Re-run a failure without re-running the pipeline | `resume_mission` | Param is **`id`** (the failed parent — same name as `show_mission`), not `mission_id`. **`confirm: true`, and resume IMPLIES start — no `start_mission` after.** Needs `archive/<parent_id>` in the sector clone (`fail_quest`/`kill` create it). v1 only re-enters at `from_phase: "validation"`. **Returns immediately**: the worktree is cut from the archive branch in the background, so the child comes back `status: "pending"` with `resume_seeding: true` — poll `show_mission` until it goes `active`. One live resume per parent: a repeat call returns the existing child with `already_resumed: true` and creates nothing |
| Decide a held approval | `show_approval`, `approve_mission`, `reject_mission` | Param is **`id`** (the mission). `show_approval` is read-only and answers for pending/approved/rejected alike; the writes are `confirm: true` and act only on a **pending** approval — an already-decided one comes back `decided: false` with its `approval_status`, not an error. `reject_mission` also requires a non-empty **`reason`**. Both attribute to **`approved_by`/`rejected_by: "mcp_operator"`** — the MCP has no person-level identity (see Auth below), and the name deliberately avoids the `auto*` prefix so `Override.approve/2` treats it as a human decision and clears the phase gate. **Rejection is not a feedback loop:** it records the reason and terminal-fails the mission on the next advance sweep (tree survives as `archive/<id>`), but no ghost consumes the reason today |
| Know whether to approve | `show_approval` | Returns the same `GiTF.Approval.Triage` output the Catwalk's approval panel renders — `fails` / `concerns` / `oks`, each item with `status`, `kind`, `title`, `detail`, `rebuttal`, and the requirement it is about (`req_id`, `requirement` text, `priority`, `acceptance_criteria`, joined from the mission's `requirements` artifact — a bare `FR-1 met` is a citation, not information) — plus a `tally`, a `coverage` block (`reported` / `total` / `line`, or `known: false` when there is no requirements artifact) and the timeout state (`hours_configured`, awake `hours_elapsed`, `auto_approve_possible`). One module, two surfaces, so they cannot disagree. A requirement the validator never mentioned is a `kind: "unreported"` **fail** — silence is not a pass. `approve_mission` over any `fails` still succeeds but the receipt carries `warning` + `approved_over_fails` naming them |
| Approval timeout | `set_approval_timeout` | **`hours`** (>0, ≤720) + `confirm: true`. Factory-wide config (`[approvals] timeout_hours`), **not** per-sector like `set_validation_timeout` — persisted to the gitf root's `.gitf/config.toml` and `Provider.reload()`ed, so no restart and it survives one. Refuses when no gitf root resolves or the config file does not parse, rather than writing a file you did not name. The receipt's `timeout_hours` is **re-read after the reload**, not echoed, and carries a `warning` if a `HIVE_*` env var outranks the file |
| Read the requirement registers | `show_mission` | `contested_requirements` (fail-closed, sticky — what the next validator must argue against) and `accepted_requirements` (the monotonic ratchet). Added after a console probe over SSM was needed to read them |
| Op surgery | `show_op`, `reset_op`, `kill_op` | `show_op` carries `depends_on`, retry fields, audit_result, changed_files |
| Ghost inspection | `list_ghosts`, `ghost_output`, `stop_ghost` | `ghost_output` requires `op_id` |
| Money | `costs_summary`, `ledger_stats` | **Known gap:** per-mission cost attribution does not survive the 168h cost-record pruning (efficiency plan B5) |
| Outcomes / post-publish | `list_outcomes`, `outcomes_stats` | The Tracker + EventsPoller feed these |
| Sector / config | `list_sectors`, `set_sync_strategy`, `autonomy_tier`, `set_autonomy_tier` | |
| Providers | `test_provider`, `circuit_status`, `circuit_reset` | |
| Knowledge / skills / projects | `knowledge_*`, `*_skill*`, `*_project*` | Intelligence layer — most of it default-off |

## What is deliberately NOT on the MCP

Three box-level operations, per `docs/OPERATING.md` §2 — these are the
only legitimate SSM/SSH uses:

1. **Release installs** (`rel/install-systemd.sh` — restarts the daemon,
   which kills in-flight missions; never deploy mid-run).
2. **Boot-time env** (`/etc/gitf/gitf.env`) and systemd/tailscale.
3. **`gitf-console rpc`** — live BEAM probes for state no tool exposes
   yet. Every console probe is a coverage signal: if it recurs, promote
   it to a tool. (The `failure_reason` field was added after two nights
   of console probes for exactly it.)

## Access patterns

- **Transport**: JSON-RPC 2.0 over stdio via the `gitf-mcp` escript,
  which in remote mode proxies to the box over the tailnet
  (`https://factory.ghostinthefactory.com`). The session MCP client and
  any background watcher speak the *same* protocol to the same endpoint —
  a polling script shells out to the escript because session-bound tools
  can't be invoked from a detached loop.
- **The box sleeps**: every tool failing with `remote factory:
  Connection timed out` means idle-stop fired. `gitf wake` (~60s), retry.
  Long-running watchers must treat timeouts as transient.
- **Writes are gated**: every mutating tool requires `confirm: true` and
  is audit-logged (`:audit_log`). The actor recorded is the **surface**,
  not the human: tailnet identity is resolved at the HTTP edge and is not
  plumbed down to tool handlers (the local socket listener has no peer
  identity at all), so handler writes log `"mcp"` and approve/reject
  attribute to `"mcp_operator"`. Person-level attribution over MCP is an
  open gap — the dashboard, which does resolve it, is the surface to use
  when who-decided matters.
- **Oversized results**: `mission_diagnosis` and unfiltered `list_*`
  calls can exceed client token limits; clients should save-to-file and
  query structurally. Prefer the narrow tool (`show_artifact`,
  `show_op`) over the bundle when you know what you want.
- **Read cadence**: reads are cheap (ETS-backed, no LLM); polling every
  60–120s is fine. `list_missions` defaults to active-only; pass
  `all: true` deliberately.
- **Resume is not a retry, and it is not free of the parent**:
  `resume_mission` inherits the failed run's artifacts and its *tree*, so
  everything before `from_phase` was authored by a run that did not
  succeed. Read `resumed_from` / `resumed_at_phase` on any mission before
  post-morteming it — a resumed run's design and plan are a suspect in its
  failure, and `mission_timeline` marks the replayed legs
  `inherited from <parent_id>` to keep them apart from real ones. If a
  resumed run fails in a way that could implicate inherited state, the
  answer is a fresh full run, not a second resume.
- **A resume response is a receipt, not a finished job**: the call
  returns as soon as the mission record and its inherited provenance
  exist. Worktree seeding (and the first `advance_quest`) run in a
  supervised task behind it, which is why the response carries
  `seeding: true` and the mission starts at `status: "pending"`. If
  seeding fails, the mission is FAILED with a `failure_reason` naming
  it — never left pending. Do not retry on a slow response: retries are
  answered from the existing child (`already_resumed: true`), because two
  timed-out calls once produced four missions racing for one archive
  branch.

## Implementation

- **Handlers**: `lib/gitf/mcp_server/handlers.ex` — one `call/2` clause
  per tool; responses built by `serialize_*` helpers. Adding a tool =
  handler clause + (for the CLI escript) schema entry; keep responses
  built from `Map.take`/explicit keys so Archive-internal fields don't
  leak by accident.
- **Socket listener**: `lib/gitf/mcp_server/socket_listener.ex` accepts
  local connections (the escript side); the daemon's HTTP surface serves
  remote mode. (Audit finding #5: the accept/handler tasks are
  unsupervised `Task.start` — fix queued.)
- **Auth**: tailnet identity (`GiTF.Tailnet`, `tailscale whois`), with
  `GITF_TAILNET_ADMINS` gating write tools.
- **Serialization discipline**: `serialize_mission/1` documents each
  field addition with the incident that motivated it (provenance,
  failure_reason). Follow that pattern — every field should say why an
  operator needs it.
- **Terminal-phase membership** comes from `GiTF.Missions` — never a
  local list (the MCP's own drifted copy once reported permanently-stuck
  missions; audit G5).

## Change protocol

When factory work exposes a state you had to fetch via console/SSM:
1. Add the field/tool to `handlers.ex` with a motivating comment.
2. Update the coverage map above.
3. The escript schema follows on the next CLI release (`gitf self-update`).
