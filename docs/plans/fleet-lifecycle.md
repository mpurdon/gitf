# Fleet lifecycle — commanded shutdown and self-upgrade

Status: **Phase 1 and Phase 2 built (0.65.369+, not yet deployed). Self-upgrade is installed but OFF until a version pointer is promoted.**

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

## Phase 2 — upgrade on wake (built, off by default)

The chosen mechanism: **a box checks for a newer release at boot and installs it
before it accepts anything.** "Upgrade yourself" therefore = *drain, sleep, wake*
— which is why this is one feature with Phase 1 and not two.

Why not a live in-place upgrade: the daemon would be restarting the process
serving the upgrade request, so the reply dies with it, and the box serves
requests half-upgraded. Ministries already sleep to $0 and wake on demand, so
the boot path is a free, verified upgrade window — and the Cabinet's existing
`/health` poll (which already reports `version`) observes the outcome with no
new machinery.

**No Terraform change was needed.** An earlier draft of this plan said the work
was blocked on granting the instance role `s3:GetObject`. That was wrong: the
role has had `s3:GetObject` and `s3:ListBucket` on the backup bucket since it
was written (`infra/aws/iam.tf`, `sid = "BackupBucket"`), and `artifacts/` is
already the documented CI hand-off prefix in that same bucket. The bucket is
SSE-S3 (`AES256`), so no KMS grant is involved either. The AWS side was ready
before the feature was.

### What it is

- `rel/gitf-upgrade.sh` → `/usr/local/bin/gitf-upgrade`, run by
  `gitf-upgrade.service`: `Type=oneshot`, `Before=gitf.service`,
  `After=network-online.target`, root.
- It compares `/opt/gitf/releases/start_erl.data` (written by the release, so it
  cannot drift from what will boot) against `artifacts/current`, and on a
  difference downloads `gitf-<v>.tar.gz` **and the matching
  `gitf-installer-<v>.tar.gz`** — the box has no checkout, so it needs `rel/`
  and `bin/` to install anything, and it needs the installer that *matches*.
- `bin/publish-release <ci-run-id> [--promote]` uploads both and, only with the
  second flag, rewrites the pointer.

### The properties that matter

- **Fail-open, everywhere.** Every failure path exits 0 and boots the version on
  disk: no bucket, no aws CLI, no pointer, a non-version string, a missing or
  truncated tarball, an installer that will not unpack, a failed install. A box
  that cannot upgrade needs a look; a box that cannot boot is an outage, and one
  bad pointer must not be able to cause one across the fleet at once. Both
  tarballs are validated with `tar tzf` before anything is touched.
- **Two brakes, both outranking the pointer.** `/etc/gitf/upgrade-disabled`
  (never upgrade — the same shape as idle-stop's) and `/etc/gitf/pin-version`
  (hold at a version). The pin is the rollback that does not need a republish.
- **Upload ≠ promote.** Uploading is inert. Promoting is a fleet-wide,
  unattended action and takes its own flag.
- **The deadlock that would otherwise eat the boot.** `install-systemd.sh` ends
  in `systemctl enable --now gitf`. Called from a unit ordered
  `Before=gitf.service`, that blocks on a unit systemd has ordered *after* the
  one doing the blocking, and the boot dies at `TimeoutStartSec` having started
  nothing. The installer now honours `GITF_INSTALL_NO_START=1`: enable, and let
  systemd do the start when the oneshot returns.

### Still to decide

- **The Cabinet keeps the SSM install path**, and `install-systemd.sh` now
  *disables* `gitf-upgrade.service` there rather than leaving it enabled (found
  by auditing the Cabinet after the first deploy — the installer enabled it
  unconditionally while correctly gating the other two timers). Two reasons,
  the second being the real one: it is always-on, so it never gets the
  boot-time window the mechanism depends on; and it is the control plane —
  pinning, rolling back and stopping the fleet all run from it, so if a bad
  release is promoted the Cabinet must be the box that did not take it.
- Nothing publishes the pointer automatically. Wiring `--promote` into CI would
  need an OIDC role in Terraform, and would make every `main` push a fleet-wide
  deploy. Deliberately not done.
- A wake now carries a network fetch on the critical path (bounded:
  `TimeoutStartSec=300`, and it fails open).

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
inevitably, the drain that would have made installing it graceful, and the
upgrade unit that would have installed it unattended. The first deploy of this
feature is a force stop and a hand-driven SSM install. Every one after it is
`bin/publish-release <run> --promote` plus a sleep and a wake.
