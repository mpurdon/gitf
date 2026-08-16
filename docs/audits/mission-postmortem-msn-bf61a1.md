# Post-mortem: msn-bf61a1 (cora approve-messages) — 2026-08-16

First execution of the mission-failure doctrine: the mission is never rescued;
the factory is diagnosed, fixed, and the same mission re-run unchanged as the
test. Mission sealed `failed` at 16:33 UTC with 11/21 ops failed. **Zero of the
five root causes were model-capability failures.** The planned work largely
shipped before infrastructure ate the mission: design, plan, Rust settings
schema, TS bindings, SettingsView + RepoSettingsDrawer all completed.

## The five defects (in causal order)

1. **Ubuntu AppArmor userns restriction broke bwrap** — every sandboxed
   validation died at `bwrap: setting up uid map: Permission denied` since
   deployment; this mission was the first to run enough validations to surface
   it. *Fixed:* AppArmor profile granting bwrap `userns` (live on box +
   install-systemd.sh), pattern Ubuntu ships for browsers.

2. **Sandbox availability was a lie** — `Bubblewrap.available?` checked only
   binary presence, so infra failures were reported to ghosts as code failures
   ("try a different implementation approach"). *Fixed:* real execution probe
   through the production flag set, cached 60s, `:sandbox_broken` critical
   alert on breakage (v0.65.71).

3. **Compile-time google catalog overrode bedrock mode** — `configured_models`
   merged the api-mode `default_models` (google) last, so `fast` and every
   legacy alias resolved to `google:gemini-2.5-flash` on a box whose google
   key was never configured. Every fix-op retry died in seconds. *Fixed:*
   app-env catalog applies in api/cli modes only.

4. **Fallback selected an uncallable bedrock form, poisoning the shared
   circuit** — `tier_models("bedrock")` returned the catalog model-id, which
   routes through ReqLLM's bedrock provider (requires explicit env keys; blind
   to instance roles). Its guaranteed failures opened the one "bedrock"
   circuit, taking the healthy inference-profile-ARN path (BedrockDirect,
   IMDS) down with it. *Fixed:* `tier_models("bedrock")` overlays
   `[llm.bedrock_models]`; box config gained `[llm.providers.bedrock]` ARNs;
   `provider_priority` defaults follow execution mode; keyless bedrock now
   qualifies as a circuit-fallback candidate.

5. **Misclassification kept the wound open** — ReqLLM's "credentials required"
   ArgumentError classified as a transient (2-min probes that can never pass)
   instead of `:auth_error` (15-min, operator-facing). *Fixed:* classified.

## Aggravators (not yet fixed — tracked)

- **API errors at iteration 0 consume implementation attempts.** Three retries
  died on provider errors having done zero work; the op paid with its life.
  Attempt accounting should not decrement on infra/API-class failures.
- **Phase state has no infra-failure awareness**: the validation phase sealed
  the mission from failures that were 100% environmental.
- **No hot config reload path on the box**: `bin/gitf rpc` fails with
  `:noconnection` (distribution/cookie issue unresolved — investigate; the
  operator requirement is fast, mess-free restarts AND a live console; BEAM
  hot-reload is table stakes). Two mid-mission restarts were needed where a
  reload should have sufficed.
- `bedrock_status` can't see instance-role credentials (reports
  `:unconfigured` on the box that runs bedrock all day).

## Timeline (UTC)

15:18 created → 15:23 planning done, 4-way parallel implementation →
15:26–15:38 fix-op retry chain dies (defects 1+3) → 15:36 AppArmor fixed on
box → 16:08 respawns still misrouting (defect 3 is compile-time) → 16:11
restart #1 applies `provider_priority=["bedrock"]` → fallback now selects
uncallable model-id (defect 4), circuit poisoned, mass failures → 16:31
restart #2 applies ARN tier table — too late: op-402da8 resumed with 2/3
retries pre-burned, sealed instantly → 16:33 validation phase failed → mission
failed. Cost: ~$14 ledger total for the day.

## Verdict

The factory's planning and implementation layers performed at spec on a
multi-surface feature. Its execution substrate — sandbox, provider routing,
circuit breakers, retry accounting — failed compound. All five root causes
fixed same-day; re-run of the identical mission is the acceptance test.
