# Ministries and the Cabinet — a fleet of Sections, one per client

*Plan of record, 2026-08-31, revised same day after the operator settled the
architecture. Supersedes the first draft's multi-tenant-in-one-box design.
Origin: the inquiry-gate night
(`docs/stories/2026-08-31-inquiry-gate-first-runs.md`) and the need to do
employer (Trajector) work with the employer's Bedrock, git identity and
GitHub account, with zero bleed into personal projects.*

## Decision record (operator, 2026-08-31)

1. **Box per ministry.** Stopping a ministry's box IS the tenancy control:
   off means no polling, no listening, no spend — and GitHub's dropped
   webhooks are already reconciled on wake by the events poller (30-day
   window), so "not listening" loses nothing by design.
2. **All boxes live in the one gitf AWS account** (515020252848). Ministries
   are not separated at the account level; they interact with the outside
   world only through their own GitHub identity, and (where configured) pay
   for their own model usage via their own Bedrock credentials. This kills
   the cross-account-orchestration problem entirely.
3. **GitHub auth per ministry = fine-grained PAT** (no GitHub App — no
   security-team verification circus). Stored only on that ministry's box.
4. **Attribution** (the Co-Authored-By / "generated with" tool credit, NOT
   the author email) becomes a per-box setting: `on | off | custom`.
   Client ministries default off unless decided otherwise.
5. **The Cabinet is a tiny always-on tailnet node, not a serverless app.**
   Phone access means a webpage over tailscale, which any tailnet device
   (phone included) reaches; Claude keeps driving individual ministries
   exactly as today (CLI/MCP → that box's URL). No public endpoint, no
   OAuth layer, no DynamoDB.

## The shape

```
                    Cabinet (t4g.nano, always on, tailnet-only)
                    cabinet.ghostinthefactory.com
                    registry · wake/stop · health · cost rollup · MCP proxy
                        │                │                 │
        factory.ghostinthefactory.com   trajector.ghost…   <next-client>.ghost…
        Section: home-affairs           Section: trajector Section: …
        (today's box, unchanged)        (new box)          (terraform away)
```

- **A ministry IS a box** — a complete Section: own daemon, sectors, Archive,
  dashboard, pollers, idle-stop. Per-ministry config is just that box's
  ordinary global config. No multi-tenant code paths inside the factory.
- **The Cabinet** is a stripped deployment of this same codebase ("cabinet
  mode": no Major, no ghosts, no sectors) reusing three things that already
  exist and were exercised hard tonight: `GiTF.Tailnet` whois auth, the
  HTTP MCP server (`/api/v1/mcp`), and the Archive (the registry is a
  collection). It holds **no mission state**; every Section stays
  authoritative. If the Cabinet is down, every ministry still works — only
  the convenience layer is gone.
- Same-account IAM: the Cabinet's instance role gets
  `ec2:StartInstances/StopInstances/DescribeInstances` scoped by a
  `gitf:ministry` tag, nothing else. No credentials leave the account.

### What the Cabinet does

| Capability | Notes |
|---|---|
| Registry | `:ministries` collection: slug, display name, box URL, instance id, notes. CRUD from the dashboard and MCP. |
| Wake / stop | Start/stop by ministry; shows state + "idle for Nm" from each box's health endpoint. |
| Fleet health | Fan-out `health_check` + version to every awake box; one page, phone-friendly. |
| Cost rollup | Pulls each box's `costs_summary`; per-ministry monthly view (feeds Trajector invoicing later). |
| MCP proxy | Every gitf tool grows an optional `ministry` param; the Cabinet forwards to that box's `/api/v1/mcp`, waking it first when asked. The local CLI/MCP can also keep talking straight to a box — the proxy is convenience, not a chokepoint. |
| Release fan-out | "Install <version> on <ministry>" — the S3+SSM sequence from OPERATING.md §9, per box, same account so the existing tooling works verbatim. |

### What stays per-box (ministry config = box config)

| Concern | Where on the box |
|---|---|
| Git identity | `[git] author_name / author_email` in config.toml → written as repo-local config at sector clone + worktree creation (today hardcoded `gitf`/`gitf@localhost` at `sector.ex:106` — this is the one real factory change). |
| Attribution | `[git] attribution = "on"|"off"|"custom…"` — publish and the commit paths consult it. |
| GitHub PAT | `[github] token` (already exists) — the work box holds the Trajector PAT; pushes use the https remote with that token. |
| LLM routing | The existing `[llm]` block: the work box sets `execution_mode`/Bedrock profile/tiers globally. The Claude CLI on that box runs `CLAUDE_CODE_USE_BEDROCK=1` against the work Bedrock credentials (an AWS profile on that box for the work account's Bedrock — model spend bills to work; the instance itself bills to gitf). No scrub inversion, no per-request credentials: one box, one identity. |
| Backups | Per-ministry S3 bucket, same account, provisioned by the module. Work source residing in the gitf account is accepted by decision 2. |
| Approval posture | `require_human_approval` / autonomy defaults in that box's config — client boxes default stricter. |

### What we no longer need (retired from the first draft)

Per-ministry records inside one factory; the AWS env-scrub inversion;
per-request Bedrock credentials in ProviderManager; sandbox bind narrowing
between ministries (one box holds one ministry — though narrowing the bind
away from `$HOME` is still worthwhile hardening *within* a box, tracked
separately); per-ministry install-cache roots and `CLAUDE_CONFIG_DIR`
juggling. Physical separation made ~70% of the first draft's code
unnecessary.

## Milestones

**M1 — identity becomes config (no new spend, benefits today's box).**
`[git] author_name/author_email/attribution` in config; `Sector.add` and
worktree creation write repo-local git config from it; publish and every
factory-made commit honour attribution. Acceptance: on the current box, set
a test identity, run a trivial mission, and `git log --format='%an %ae %cn %ce'`
plus the PR body show the configured identity and attribution; unset =
today's behaviour.

**M2 — the ministry box module (spend gate #1).** Terraform: parameterize
the existing box provisioning by slug — instance (tagged `gitf:ministry`),
EBS, tailscale join, DNS `slug.ghostinthefactory.com`, backup bucket,
`/etc/gitf` seeding. Bring up `trajector`: work PAT, work git identity,
Bedrock profile for the work account, attribution off, approval strict.
Acceptance: a scratch repo under the work GitHub account onboarded as a
sector; one mission end-to-end; the PR's commits (author AND committer) and
comments all carry `matthew@trajectorservices.com` / the work account; the
`costs` ledger shows only `bedrock:*` models; the home box untouched.

**M3 — the Cabinet (spend gate #2).** Cabinet mode in the app (compile-time
or config flag disabling Major/ghost supervision); registry collection +
CRUD; wake/stop via tag-scoped instance role; fleet health + cost pages
(phone-usable over tailnet); `cabinet.ghostinthefactory.com`. Acceptance:
from a phone browser on the tailnet, wake trajector, watch it come healthy,
stop it.

**M4 — routing + fan-out.** `ministry` param on the MCP tools via the
Cabinet proxy; CLI `-m <slug>`; release install fan-out; OPERATING.md
§"Ministries and the Cabinet"; GLOSSARY entries (Ministry, Cabinet).

Order matters: M1 is pure code and can ship now. M2 and M3 each raise a
real (small) bill — a t4g box + EBS each, order of $5–30/mo depending on
idle-stop discipline — and are **not to be provisioned without explicit
operator approval, per standing rule**. M2 before M3 is fine (two boxes are
manageable with direct URLs); M3 before M2 also works (Cabinet managing a
fleet of one).

## Edges that still bite (kept from the first draft, restated for the fleet)

- **Every commit-maker needs the identity**, not just ghosts: consolidation
  merges, sync, residue-scrub commits, publish. Repo-local git config at
  clone/worktree creation covers all of them; that's why M1 is at that seam.
- **The PAT is read in four places** (publish REST, review intake, events
  poller, outcomes tracker) — on a one-ministry box they all read the same
  `[github] token`, so this collapses to "config, not env". Verify the env
  var (`GITHUB_TOKEN`) doesn't shadow it on the work box.
- **Claude CLI state is per-box now** (`~/.claude` on the work box only ever
  sees work code) — the side-channel concern dissolves, but the work box
  must be *logged into nothing personal*: no personal Anthropic login, no
  personal gh keyring. Provisioning checklist item.
- **Idle-stop is the cost model.** A ministry box that wakes on demand
  (Cabinet button, `gitf -m … wake`, or a morning cron) and reconciles via
  the events poller costs hours-used. The Cabinet nano is the only always-on
  spend.
- **Shared release, divergent config**: all boxes run the same tarball;
  config differences are data. Resist per-ministry forks.

## Open questions (none block M1)

- Cabinet build: same repo behind a flag (preferred — one CI artifact) vs a
  separate mix release target.
- Whether the Cabinet should also be the webhook ingress hostname for
  stopped ministries later (park: the events poller already covers the gap).
- Within-box sandbox hardening (don't bind all of `$HOME`) — still worth
  doing for defence in depth; tracked outside this plan.
