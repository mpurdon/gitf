# Fleet lifecycle — commanded shutdown and self-upgrade

Status: **Phase 1 built (0.65.369, not yet deployed). Phase 2 designed, blocked on an IAM change.**

The Cabinet could stop a ministry exactly one way: `ec2 stop-instances`, whose
own tool description admitted *"In-flight missions die with it — check first"*
while nothing checked. There was no way to say "wind down when you're done",
and no box had any idea a newer release existed.

This is the two OS-shutdown verbs, and an upgrade path that composes with them
instead of sitting beside them.

## The insight this is built on

Three of the four pieces already existed, wired to levers the Cabinet could not
pull:

| Piece | Where it lives | What it does |
|---|---|---|
| Ordered teardown | `GiTF.Exfil` | On SIGTERM: demote running ops so they resume, checkpoint ghosts, flush Archive, SIGTERM the Claude ports, stop Major |
| "Am I busy?" | `Health.idle_state/0` | One definition, shared by `/health` and `IdleStop.Warning` — no active ghosts, no RUNNING missions; **held missions don't count** |
| Wait-then-halt | `rel/gitf-idle-stop.sh` (root timer) | Polls `/health`, powers off after `GITF_IDLE_STOP_MINUTES` of quiet |
| **Stop admitting work** | **missing** | — |

Only the fourth was missing, and its absence is what made a graceful stop
impossible: a webhook, an Aramaki tick or an operator could start a mission on
a box thirty seconds from stopping, so any wait-for-quiet chased a moving
target.

Note also what the daemon *cannot* do: it runs as `gitf`, not root, so it can
never halt the machine. Stopping is always either the Cabinet's
`ec2 stop-instances` or the root idle-stop timer. Any design where the BEAM
powers itself off is wrong on its face.

## Phase 1 — commanded shutdown (built)

**`GiTF.Drain`** — the missing gate. `begin/1`, `cancel/0`, `state/0`,
`preflight/0`.

- **One door.** `Major.Orchestrator.start_quest/2` is where the webhook,
  Aramaki, the CLI, the HTTP API, the dashboard LiveViews, the idle sweeper and
  MCP all converge. The gate is one preflight there, beside the budget and
  provider ones. A gate on any one caller would be a gate on none of the others.
- **Not durable, on purpose.** State lives in `:persistent_term` and dies with
  the BEAM. A box that wakes for a webhook must wake *ready to work*; a drain
  that survived a reboot would be a box that quietly refuses every mission until
  someone remembers why. The failure direction is "accepts work".
- **Expires on its own** (≤240 min). An operator who drains a box and gets
  distracted has a box that starts working again.
- Visible on `/health` as `draining`, so the Cabinet can watch: `draining` says
  the door is shut, `idle` says the room is empty. Both true = safe to stop.

**`Fleet.drain_and_stop/2`** — the symmetric partner to `wake_and_await/2`.
Drain → wait for quiet (bounded, default 45s) → `ec2 stop-instances`.

Two honest outcomes, both successes:

- `{:ok, :stopped}` — quiet, instance stopping.
- `{:ok, :draining}` — still finishing. It accepts nothing new, and its **own
  root idle-stop timer sleeps it** when it goes quiet. The drain is precisely
  what makes that terminate.

A drain that cannot be delivered stops nothing and says so. Silently falling
back to a hard stop would make "graceful" a word that sometimes means its
opposite, on the one path where the operator asked for care.

**Tools.** Section-side `drain_factory` (so `ministry_call` reaches it);
Cabinet-side `stop_ministry` gains `mode: "graceful" | "force"`, graceful being
the default. Force is unchanged — and less brutal than it reads, since EC2 stop
is an ACPI shutdown that runs `Exfil` via `systemctl stop` (`TimeoutStopSec=45`).

### Deliberate non-goals

- A drain does not pause running work, answer held questions, or power anything
  off.
- **Held missions do not hold a drain open.** Same rule idle-stop has always
  used; a drain waiting on an approval nobody is watching would never end.
- No Discord button yet. The Cabinet's `stop_ministry` is the surface.

## Phase 2 — upgrade on wake (designed, blocked)

The chosen mechanism: **a box checks for a newer release at boot and installs it
before it accepts anything.** "Upgrade yourself" therefore = *drain, sleep, wake*
— which is why this is one feature with Phase 1 and not two.

Why not a live in-place upgrade: the daemon would be restarting the process
serving the upgrade request, so the reply dies with it, and the box serves
requests half-upgraded. Ministries already sleep to $0 and wake on demand, so
the boot path is a free, verified upgrade window — and the Cabinet's existing
`/health` poll (which already reports `version`) observes the outcome with no
new machinery.

Shape:

1. `gitf-upgrade.service` — `Type=oneshot`, `Before=gitf.service`, root.
2. Reads a version pointer from S3 (`artifacts/current`), compares to the
   installed `/opt/gitf` version, and on a difference downloads the tarball and
   runs the existing `rel/install-systemd.sh`.
3. Fails **open**: any failure (no network, bad pointer, failed install) logs and
   boots the version already on disk. A box that cannot upgrade must still come
   up, or an S3 typo bricks the fleet's boot path.
4. CI already builds the arm64 tarball on every `main` push; publishing the
   pointer is one `s3 cp` at the end of the existing deploy.

**Blocked on:** the instance role needs `s3:GetObject` on the artifacts prefix.
That is a Terraform change to the AWS account, and per standing instruction
nothing that touches the AWS account or the bill gets applied without reading
the full plan and asking first. Not started.

**Risks to weigh before building:**

- It puts a network fetch on the critical boot path of every wake. Mitigated by
  fail-open and a short timeout, but a wake gets slower.
- A bad release now propagates on the next wake of every box, unattended. Wants
  a pinned-version escape hatch (`/etc/gitf/pin-version`) before the fleet grows.
- The Cabinet upgrades the same way, but it is always-on and never wakes — so it
  keeps the SSM install path. The orchestrator cannot be upgraded by the
  mechanism it orchestrates.

## Acceptance test

Phase 1, on a real box, in this order — the drain is the thing being tested, so
don't do it by hand through another channel:

1. `stop_ministry slug: <m>, mode: "graceful", confirm: true` on an idle box →
   `status: "stopping"`, and the instance stops.
2. Same, on a box with a mission running → `status: "draining"`, `/health` shows
   `draining: true`, and `start_mission` on it is refused with `:draining`.
   The running mission finishes; the box sleeps itself.
3. Wake it → it accepts missions again with nothing cleared by hand.

## Bootstrapping note

None of this exists on any box until 0.65.369+ is installed there — including,
inevitably, the drain that would have made installing it graceful. The first
deploy of this feature is a force stop.
