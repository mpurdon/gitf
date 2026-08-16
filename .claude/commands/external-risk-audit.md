---
description: Find stale-mirror and external-dependency risks — anywhere the factory caches, assumes, or mirrors state owned by a system it doesn't control (git remotes, provider APIs, AWS, clock, filesystem, toolchains)
argument-hint: "[boundary name to audit just one, e.g. 'providers' — defaults to all]"
---

# External-Risk Audit

Every bug in this class has the same anatomy: **the factory holds a copy of,
or an assumption about, state that something else can mutate — with no
defined refresh point and no divergence detection.** Past confirmed
instances: local git clone vs origin (squash-merges diverged it), pinned
`assigned_model` vs provider config, wall-clock grace timers vs box uptime,
`op.ghost_id` vs process liveness, deployed Lambda permissions vs
terraform's belief, hexpm's rotating image tags, AWS changing function-URL
permission semantics (Oct 2025).

You are hunting for the *next* members of this family. Do not re-report the
fixed ones above; use them to calibrate what a hit looks like.

## Boundary taxonomy

Audit each boundary (or only the one passed as an argument):

1. **Mirrored remote state** — git remotes, GitHub PRs/issues/branches,
   S3 objects, the tap repo formula. What we copy locally and act on.
2. **Service APIs with baked-in assumptions** — LLM providers (model IDs,
   quotas, auth modes, response shapes), GitHub API (token scope/expiry,
   rate limits), AWS APIs (IAM/SCP semantics, service behavior changes),
   Tailscale. Includes *contract drift*: the vendor changing rules under us.
3. **Ambient runtime** — wall clock vs monotonic vs box uptime (idle-stop
   means wall-clock gaps!), filesystem paths that reboots wipe (/tmp),
   DNS, TLS cert renewal, process table, disk space.
4. **Toolchain & platform drift** — apt/npm/hex packages, pinned versions
   and images (do the pins have a renewal story?), GitHub Actions runners,
   OTP/Elixir version skew between box, CI, and dev Macs.
5. **The factory's own past self** — anything written by an older version
   and read by a newer one across restarts: store records with stale
   schemas, config files rewritten at boot, tokens/keys with expiry.

## How to hunt (per boundary)

Inventory the integration points mechanically first — grep for:
`System.cmd`, `Req.` / HTTP clients, `System.get_env`, hardcoded paths and
URLs, fields cached in Archive records (IDs, SHAs, model specs, tokens,
timestamps), terraform resources, systemd/cron assets in `rel/`.

Then interrogate **every cached datum and assumption** with five questions:

1. **Mutation**: who else can change the source — the vendor, the user,
   time, another tool, a reboot? ("Nobody" is almost never true.)
2. **Assumption**: what exactly does our code believe about it —
   existence, shape, semantics, freshness, auth validity?
3. **Refresh**: when is the belief re-checked — at use, at boot, once at
   setup, or never?
4. **Detection**: if the belief breaks, do we get a loud typed error, a
   silent misbehavior, or worst of all a *lie* (reported success that
   didn't happen)?
5. **Blast radius & recovery**: what breaks downstream, how would an
   unattended operator find out, and what is the manual fix?

Severity = (likelihood the external side changes) × (silence of the
failure) × (blast radius). A likely change that fails *loudly* is low
severity; an unlikely change that produces a *lie* is high.

## Capability parity (the absence lens)

Defect hunts only find what's present and wrong. For each external
platform, ALSO enumerate what it **offers that we don't use** — read the
vendor's current feature list, not our integration code — and force every
absence to be a deliberate decision or a finding. Classic categories:
cost levers (prompt/result caching, batch APIs, cheaper service tiers,
compression), reliability levers (idempotency keys, checksums, webhooks
vs polling), and limit levers (pagination, streaming, quota headroom
APIs).

Warning from the finding that created this section: **accounting code is
not capability code.** GiTF tracked `cache_read_tokens` with configured
prices through every cost summary — all faithfully recording zeros —
while the Bedrock request path sent no cachePoint blocks at all. A
reviewer who greps for the feature and finds its *bookkeeping* will
wrongly conclude the feature exists. Verify at the wire: does the
request/response actually carry the capability's fields, and is its
metric ever nonzero in production? A metric that has never been nonzero
is a red flag, not reassurance.

## Fix patterns (name one per finding)

- **Re-derive at use** — fetch the source of truth at the point of
  consumption instead of trusting the copy (preferred when cheap).
- **Verify-then-use** — keep the cache but validate it against the source
  before acting; fall back loudly.
- **Divergence alarm** — when re-deriving is too expensive, detect and
  alert (dispatch_webhook) instead of silently proceeding.
- **Pin + renewal story** — for deliberate pins (versions, images, model
  IDs): document what breaks the pin and add a check that notices.
- **Uptime-aware time** — never compare wall-clock timestamps across
  possible box stops; count uptime or re-anchor at boot.

## Execution

For a full audit, launch one read-only Explore agent per boundary (all in
one message, concurrently), each given: this file's anatomy + its boundary
scope + the five questions + the requirement to return findings as
`file:line — belief — mutator — refresh — detection — severity — fix
pattern — effort (S/M/L)`. Findings must be verified in code, not
speculated. Then dedup, rank by severity, and write the register to
`docs/audits/external-risk-<date>.md` plus the top items into the
reliability triage memory. Do NOT fix during the audit — the register is
the deliverable; fixes are follow-up work.
