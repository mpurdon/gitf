# Operating the Factory

How to drive the running GiTF factory from a Claude Code session. This is the
runbook for *operating*, not for *building* — for architecture see
[`specs/ARCHITECTURE.md`](../specs/ARCHITECTURE.md), for provisioning see
[`docs/deploy-aws.md`](deploy-aws.md).

Live facts in this doc were verified against the running box on **2026-08-24**
at v0.65.175. Anything marked *(verify)* changes on its own and should be
re-checked, not trusted.

---

## 1. The single most important thing

**This repo is the source code. The factory is somewhere else.**

The factory runs on one EC2 box (`ghost-in-the-factory`, Graviton, us-east-1),
reachable only over the tailnet at **https://factory.ghostinthefactory.com**.

Your local `gitf` CLI is in **remote mode** — `[server] url` is set in
`~/.config/gitf/config.toml`, so *every* `gitf` command you run transparently
drives that box. It does not start a local factory. The `gitf` MCP server
proxies to the same box.

Consequences that trip people up:

- Editing code in this repo changes **nothing** about the running factory until
  a release is built and installed on the box (§9).
- `~/Projects/gitf/.gitf/` is a stale local workspace. The real store is
  `/var/lib/gitf/.gitf/store` on the box.
- Sectors are registered on the box, at `/var/lib/gitf/sectors/<name>`, not on
  your Mac.

## 2. Reach for the MCP first

**Default to `mcp__gitf__*`. Shelling into the box is the last resort, not the
diagnostic starting point.**

Two reasons, and the second is the one that gets forgotten. The MCP tools return
structured factory state that a shell command has to be assembled to
approximate. And the operator watches the session — an MCP call shows exactly
what was asked and what came back, where a `curl | grep | sed` pipeline or an
SSM round-trip is opaque from outside.

The reflex to break: reaching for SSM to answer a question the factory already
answers about itself. The running version, whether the daemon is up, how much
memory or disk it is using, why a provider is failing — all of these have tools.

| Question | Use this | Not this |
|---|---|---|
| Is it up? What version? | `factory_status`, `health_check` | `systemctl is-active`, `/opt/gitf/bin/gitf version` |
| Memory, CPU, uptime | `host_stats` | `free -m`, `uptime` |
| Disk, per-mission worktrees | `disk_usage` | `df -h`, `du` |
| What is a ghost doing? | `ghost_output`, `list_ops` | tailing worktrees |
| Why did it fail? | `mission_diagnosis`, `mission_report` | `journalctl` |
| Is the provider broken? | `test_provider`, `circuit_status` | reading env files |
| Let the box stay awake | `idle_stop_override` | `touch /etc/gitf/idle-stop-disabled` |
| Flip a feature flag | `/dashboard/settings` (live reload) | editing `/etc/gitf/gitf.env` + restart |

What genuinely needs the box, because it has no MCP surface:

- **Installing a release** — the one unavoidable case (§9).
- **Boot-time env** in `/etc/gitf/gitf.env`: secrets, `GITF_EXECUTION_MODE`,
  tailnet auth. Runtime feature flags do *not* belong here (§10).
- **systemd, tailscale, Caddy** — unit state, certs, serve config.
- **AWS-side work** — EC2, SSM, Bedrock, Route53, S3. No MCP coverage; the AWS
  CLI is correct there.

When you do need the box, prefer one scripted `aws ssm send-command` over an
interactive session, and get everything in a single round-trip rather than
logging in repeatedly to ask one more thing.

## 3. Cold start — do this at the beginning of every session

The box powers itself off when idle. A sleeping box looks exactly like a broken
one, so check in this order:

```sh
tailscale status | grep ghost      # "offline, last seen ..." = asleep, not broken
gitf wake                          # ~60s; prints "Factory is up: https://..."
```

The tell-tale from the MCP side is `MCP error -32000: remote factory:
Connection timed out.` on **every** tool. That is the asleep signature. Wake
first, diagnose second.

Then confirm before you act:

```
mcp__gitf__health_check     → status "healthy", 10 subsystem checks
mcp__gitf__factory_status   → active missions/ghosts, spend, recent failures
```

`gitf wake` reads `[server] wake_url` from the global config and hits a public
Lambda function URL (token-guarded). If that ever 403s, see the wake-URL
landmine in [`deploy-aws.md`](deploy-aws.md) §5.

**Waking is cheap and self-reversing** — the box idles back off after
`GITF_IDLE_STOP_MINUTES` (30, with a 15-minute grace). You do not need to ask
before waking. You *do* need to ask before anything that raises a real bill in
a way that does not undo itself (instance resize, EBS growth — EBS cannot
shrink).

**A running mission keeps the box awake by itself.** `rel/gitf-idle-stop.sh`
polls `/api/v1/health` and only counts the box idle when there are *no active
ghosts and no non-terminal missions*. You do not need an override to protect a
mission that is actually running — only to survive long gaps *between* work
(waiting on a human approval, a slow external job).

For that case, use the `idle_stop_override` MCP tool — it requires both a new threshold and a duration
(e.g. `idle_minutes: 60, duration_minutes: 240`) and always expires. There is
no permanent hold. On the box itself the manual escape hatch is
`sudo touch /etc/gitf/idle-stop-disabled`.

## 4. Sectors — the repos the factory can work on

*(verify with `mcp__gitf__list_sectors`)*

| id | name | path on box | sync strategy |
|---|---|---|---|
| `sec-a0e680` | **cora** | `/var/lib/gitf/sectors/cora` | `pr_branch` |
| `sec-d6bcd9` | hello-factory | `/var/lib/gitf/sectors/hello-factory` | `manual` |

`sync_strategy: pr_branch` is what makes cora missions end in a **pull request
on `mpurdon/cora`** rather than a local merge. That is the delivery mechanism —
a mission "succeeding" means a PR exists and CI is green, not that anything
landed on `main`.

cora is a **Tauri** app (Rust backend in `src-tauri/`, React/TS frontend in
`src/`), which matters because verifying it requires driving the real app, not
just running tests (see the verification track in project memory).

To add a repo: `gitf sector add <path> --name <name>`, run against the box.

## 5. Creating and running a mission

### The two-step that bites

`create_mission` **does not start the mission.** It creates it in `pending`.
Nothing happens until you call `start_mission`. Both require `confirm: true`.

```
mcp__gitf__create_mission
  goal:        "<the whole spec — see §6>"
  sector_id:   "sec-a0e680"
  name:        "short-kebab-name"
  review_plan: false          # true = pause at planning for dashboard review
  confirm:     true
→ returns { id: "msn-xxxxxx", status: "pending" }

mcp__gitf__start_mission
  id: "msn-xxxxxx"
  confirm: true
→ returns { status: "active", phase: "triage" }
```

`start_mission` also takes `fast: true` (force the streamlined path) or
`full: true` (force the whole pipeline). Omit both and triage decides.

### The pipeline

```
triage → research → requirements → design → review → planning →
implementation → validation → awaiting_approval → sync → simplify →
publish → scoring
```

Declared in `priv/workflows/standard.yaml`, not hardcoded. Triage sets skip
flags, so a trivial change legitimately jumps straight to `implementation`.
Eight workflow templates ship in `priv/workflows/`.

### Projects vs missions

A **mission** is one objective. A **project** (Aramaki) is a DAG of missions
with a roadmap: `create_project` → `approve_project` → Aramaki emits missions
in dependency order. Use a project only when there genuinely are dependent
stages; a single feature is a mission.

## 6. Writing a mission goal that actually lands

The goal text *is* the spec — there is no follow-up conversation once a ghost is
running. Every cora mission that completed shares the same shape. From the
verified history:

> *"Sort the user list case-insensitively. Currently usernames are sorted
> case-sensitively so uppercase letters sort before lowercase (e.g. @Ayan189
> appears before @adamwhitmore-trajector). Fix the sort so ordering ignores
> case: @adamwhitmore-trajector should come before @Ayan189. Keep the change
> minimal."* — `msn-b17b1d`, completed

> *"In src/windows/SettingsView.tsx, show the total number of users in the
> UsersPane heading, e.g. 'Users (12)', updating automatically with the
> list"* — `msn-56e353`, completed

What those have in common — treat it as the checklist:

1. **Name the file(s).** `src/windows/MainApp.tsx`, not "the PR list".
2. **State current behaviour concretely**, with a real example value.
3. **State expected behaviour**, with the same example resolved.
4. **Give the acceptance test in the goal** — what you'd look at to call it done.
5. **Bound the scope** — "keep the change minimal", or name what *not* to touch.
6. **Reuse the codebase's own vocabulary.** cora already has `GroupMode`,
   `authorPriorities`, `prioOf` — a goal that names them produces a change that
   fits; a goal that invents new nouns produces a parallel system.

Anti-pattern: multi-surface features (Rust command + TS binding + UI panel) in
one goal. They are the deliberate frontier and they fail more often — run 13's
postmortem is exactly this. Split them or accept the risk knowingly.

## 7. Watching a run

| Want | Tool |
|---|---|
| Phase + progress | `mcp__gitf__show_mission`, `mission_timeline` |
| The work units | `list_ops`, `show_op` |
| What a ghost actually did | `list_ghosts`, `ghost_output` |
| Why it went wrong | `mission_diagnosis`, `mission_report` |
| Money | `costs_summary`, `ledger_stats` |
| Everything at once | `https://factory.ghostinthefactory.com/dashboard` |

Dashboard sections worth knowing: `/dashboard/approvals` (gates waiting on
you), `/dashboard/studio` (planning studio), `/dashboard/settings` (live flag
and config editing), `/dashboard/workflows`.

`list_missions` with `all: true` returns ~300KB and blows the tool limit. It
gets saved to a file — query it with `jq` rather than re-reading:

```sh
jq -r '.[] | "\(.id)\t\(.status)\t\(.name)"' <saved-file>
```

## 8. When a mission fails

**The doctrine: never rescue the mission.** Root-cause the *factory* defect,
fix that, then re-run the same mission unchanged — the re-run is the test that
the fix worked. Hand-finishing a mission teaches the factory nothing and hides
the defect.

Postmortems live in [`docs/audits/`](audits/). Read the relevant one before
re-diagnosing something already understood.

### Current reliability signal *(2026-08-24 — verify)*

- 7-day failure classes: `no_changes` 23, `unclassified` 89, `unknown` 13.
- **`no_changes`** — "Ghost reported success but produced 0 file changes" — is
  the recurring, actionable one. It is the failure mode of a model returning an
  empty completion while claiming success.
- Model decay alerts firing for the `sonnet` (failing) and `fast` (degraded)
  tiers. Check `mcp__gitf__test_provider` and `circuit_status` before blaming a
  mission for what is a provider problem.
- Lifetime spend $932.65 across 35 missions and 4,365 ghosts.

## 9. Getting into the box

**SSH is not set up for this Mac user** — `ssh ghost-in-the-factory` fails with
`Permission denied (publickey)`. The documented path is SSM, which needs a live
SSO session first:

```sh
aws sso login --profile gitf            # the session expires regularly
aws ssm start-session --target <instance-id>
```

Only the `aws sso login` is interactive. Everything after it is scriptable —
prefer `aws ssm send-command --document-name AWS-RunShellScript` over an
interactive session when the work is a known sequence (installing a release,
reading an env file, restarting a unit).

*(2026-08-24)* The fallback `gitf-prod` profile is **broken** — it references
`source_profile = "org"`, which does not exist in the local AWS config. `gitf`
is the only working profile, so an expired SSO session is a hard stop for box
access rather than something the second profile covers.

Once in:

| Thing | Where |
|---|---|
| Release | `/opt/gitf` |
| Operator env | `/etc/gitf/gitf.env` (secrets, 0600) and `/etc/gitf/aws.env` |
| State, store, sectors | `/var/lib/gitf` (the data volume — survives instance replacement) |
| Factory user's config | `/var/lib/gitf/.config/gitf/config.toml` |
| Logs | `journalctl -u gitf -f` (JSON) |
| Units | `gitf.service`, `gitf-idle-stop.timer`, `gitf-backup.timer` |

**Prefer hot-reload to restarts.** A restart kills in-flight missions. Config
changes apply via `Config.Provider.reload()` — editing the file alone is *not*
enough, the daemon caches at boot.

Upgrades: CI builds an arm64 tarball on every `main` push; install with
`sudo rel/install-systemd.sh <tarball>`. State is untouched.

## 10. Feature flags

Most of the differentiating intelligence layer ships **default-off**. The
factory as it boots is a plain pipeline. Do not assume skills, outcomes,
knowledge injection, LSP validation, workflow inference, tournaments or Aramaki
are running — they are each a flag.

Flags live in a `[features]` table in the config TOML, apply on every config
reload (no restart), and **beat** the `GITF_*_ENABLED` boot env var. Only the
whitelist in `lib/gitf/flags.ex` applies; unknown keys are logged and skipped.
All flags are logged at boot, so `journalctl -u gitf | grep "feature flag"`
is the ground truth for what is actually on.

Confirmed off *(2026-08-24)*: outcome autonomy tiers — `autonomy_tier` for cora
returns `reason: "feature_disabled"`, effective tier `normal`.

## 11. Guards you should not route around

- **Daily spend ceiling** — factory-wide, rolling 24h, **fail-closed**. Breach
  pauses the factory rather than burning on. Per-mission budget on top.
- **Sandbox** — the box runs `GITF_SANDBOX_REQUIRED=1`, so a degraded sandbox
  means *refused*, not silently unsandboxed.
- **Non-destructive failure** — mission failure and `gitf rollback` use
  `git revert`. Never `reset --hard` a repo that may hold human work.
- **Tailnet is the trust boundary.** Dashboard auth resolves the peer IP to a
  person via `tailscale whois` (`GITF_TAILNET_AUTH=required`,
  `GITF_TAILNET_ADMINS`). There is no real SSO yet, so nothing goes beyond the
  tailnet.

## 12. Landmines

- **Two `gitf` binaries.** `~/.local/bin/gitf` is 0.65.175 (self-updated);
  Homebrew's `/opt/homebrew/bin/gitf` is 0.65.47. PATH order decides which you
  get. Check with `gitf version` when behaviour looks wrong.
- **`.mcp.json` has a dead `cwd`** — `/Users/mp/Projects/gitf-workspace/` does
  not exist. It works anyway because remote mode ignores it, but it will
  mislead you when debugging MCP.
- **`gitf login` pings the *previously* configured server before storing the new
  URL.** If the old endpoint is dead, edit `[server] url` in
  `~/.config/gitf/config.toml` by hand.
- **Bedrock model specs must be full ARNs.** `arn:aws:bedrock:...` routes
  through the SigV4 path; an `amazon_bedrock:<id>` spec falls through to
  ReqLLM's registry and returns `{:api_error, :not_found}`.
- **Org SCP denies unencrypted S3 PutObject** — every manual `aws s3 cp/sync`
  into the account needs `--sse AES256`.
- **A commit hook auto-bumps the version** and `git add`s `mix.exs`. You cannot
  hold `mix.exs` out of a commit.
- **Never set `GITF_PATH`.** Use `gitf -w <path>` to target a workspace.
- **Never test in this source repo.** Use `~/Projects/gitf-test`.

## 13. The factory's own wiki is a different thing

`gitf knowledge` / `knowledge_search` / `knowledge_ingest_url` manage the
**knowledge engine** — a wiki compiled from mission debriefs and injected into
*ghost* context (gated by `knowledge_context_enabled`). It is for the agents
doing the work, not for the agent operating the factory. This document is the
latter. Don't confuse the two when someone asks to "write it down".
