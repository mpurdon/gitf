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
  is audit-logged (`:audit_log`) with the real tailnet actor.
- **Oversized results**: `mission_diagnosis` and unfiltered `list_*`
  calls can exceed client token limits; clients should save-to-file and
  query structurally. Prefer the narrow tool (`show_artifact`,
  `show_op`) over the bundle when you know what you want.
- **Read cadence**: reads are cheap (ETS-backed, no LLM); polling every
  60–120s is fine. `list_missions` defaults to active-only; pass
  `all: true` deliberately.

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
