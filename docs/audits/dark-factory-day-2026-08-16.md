# The Dark Factory Day — 2026-08-16

Five runs of one identical mission (cora: configurable PR approve messages —
global default + per-repo overrides in a settings slide-out + per-repo review
instructions). Fourteen findings, fourteen same-day responses. **No run failed
the same way twice** — each died (or survived) exactly one layer deeper than
its predecessor, which is what a working harness-engineering ratchet looks
like. Doctrine: the mission is never rescued; the factory is diagnosed, fixed,
and the identical mission re-runs as the acceptance test.

## The runs

| Run | Mission | Died in | Killed by | Depth gained |
|---|---|---|---|---|
| 1 | msn-bf61a1 | validation | broken sandbox + keyless-provider retry routing + circuit poisoning (findings 1–5) | planning + 3/4 impl parts completed |
| 2 | msn-8933dc | implementation | stall watchdog executing healthy build ghosts; fix-loop with no convergence cap (7, 8); plus account faults (6) | first full planning on quota-degraded Haiku |
| 3 | msn-e631cb | implementation | zero-diff honesty check executing a *correct* read-only Recon ghost (9) | best plan yet (recon-gated DAG) |
| 4 | msn-c480cf | implementation→seal | parallel builds starved the 2-vCPU box → mass watchdog deaths in a 4s window → phase sealed over live retries (12) | crux bindings op passed for the first time |
| 5 | msn-027c14 | implementation | none of the above — Haiku genuinely couldn't land thinking-tier Rust logic after quota degradation (13) | every phase + crux + 11 fix cycles clean; failure was honest |

## The fourteen findings

1. **AppArmor userns broke bwrap** since deployment (Ubuntu hardening) → bwrap
   userns profile, shipped in installer.
2. **Sandbox availability was binary-presence only** → real execution probe +
   `:sandbox_broken` critical alert.
3. **Compile-time google catalog overrode bedrock mode** for fast/alias tiers →
   api/cli-only merge.
4. **Bedrock fallback selected the credential-blind model-id form**, poisoning
   the shared circuit that the healthy ARN path used → `tier_models("bedrock")`
   overlays `[llm.bedrock_models]`; keyless bedrock became a fallback candidate.
5. **"Credentials required" classified as transient** → `:auth_error`.
6. **Account faults**: Haiku's Bedrock agreement never activated (self-healed on
   first invocation); Sonnet 4.6 daily quota = 10.8M tokens, non-adjustable.
7. **Stall watchdog killed healthy ghosts running long silent builds** (ts-rs =
   minutes of rustc) → tool execution heartbeats like LLM calls; threshold
   env-tunable (`GITF_STALE_THRESHOLD_SECONDS`), box at 300s.
8. **Fix-loop convergence counter reset every cycle** (context persisted only
   to fix ops, never the origin) → persisted on origin; capped at 3.
9. **Zero-diff honesty check executed honest analysis-only ghosts** →
   `skip_verification` ops exempt.
10. **No Bedrock prompt caching at all** — while the cost system faithfully
    tracked cache fields that were always zero → cachePoint blocks (system,
    tools, conversation tail), wire-verified (4401-token prefix: write then
    100% read). Kill-switch flag. Bookkeeping-without-capability became the
    "capability parity" lens in /external-risk-audit.
11. **Ledger zeroed the cache breakdown** (ReqLLM plugin hardcoded 0) → reads
    the real split; cost formula bills cache reads at ~10% instead of
    double-charging.
12. **Concurrency vs box capacity**: max_ghosts=5 × cargo builds on 2 vCPU/4GB
    → simultaneous watchdog deaths → phase sealed over live retries →
    max_ghosts=2 live-tuned; resource-aware admission queued as roadmap work.
13. **Tier-degradation policy** (open): when the thinking-tier model is
    quota-dead, hard ops degrade to a weaker model and burn the mission.
    Alternative: token-hibernation — park quota-starved ops until reset (the
    factory already hibernates for compute; tokens are the same shape).
14. **Fix-cycle counter still shows "attempt 1" in production** (open): the
    gate-failure-on-completed-op loop shape doesn't route through the fixed
    persist path. Needs a trace.

## The infrastructure wins beyond the findings

- **Live console restored** (`gitf-console`): three compounding breaks —
  vm.args shipped literal `${RELEASE_COOKIE}`/`${RELEASE_NODE}` (node silently
  used the cookie FILE), hostname resolved IPv6-only under Tailscale while
  distribution listened on IPv4, and no documented recipe. All fixed; config
  changes are now edit + `GiTF.Config.Provider.reload()` — no restart. Proven
  by live-tuning max_ghosts and the watchdog threshold mid-incident.
- **Runtime `[features]` config table** — flags flip on config reload.
- **Prompt caching** cuts the dominant mission cost (repeated context) ~4–5x
  on the AWS bill. Cache reads still count against the daily token quota —
  caching is a money lever, not a quota lever.
- Day's spend: ~$22 ledger (overstated pre-fix-11) for 5 multi-surface mission
  attempts, 13M+ input tokens, and 14 diagnosed-and-fixed factory defects.

## Policy conclusions for the roadmap

1. **Token-budget hibernation** (finding 13) is now the highest-leverage
   scheduler feature: quota is a hard daily resource; missions should park and
   resume like they already do for compute sleep.
2. **Resource-aware spawn admission** (finding 12): max_ghosts must reflect
   what the box can build concurrently, not just orchestrate.
3. **Run 6 protocol**: identical mission, post-quota-reset (00:00 UTC), Sonnet
   on thinking-tier ops, all fixes deployed — the clean acceptance test.
