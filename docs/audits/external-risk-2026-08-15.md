# External-Risk Audit — 2026-08-15

First execution of `/external-risk-audit` (see `.claude/commands/external-risk-audit.md`).
Five read-only agents, one per boundary; every finding verified at file:line.
Severity = likelihood × silence × blast radius; a **lie** (reported success that
didn't happen) outranks a loud failure. Items already fixed before this audit
(origin-based worktrees, bedrock fallback, exfil ghost_id, alert severity map,
validation_command wiring) are excluded.

## Headline clusters (cross-boundary synthesis)

### C1 — The wake-storm: the box's own sleep corrupts every wall-clock deadline (CRITICAL)
Idle-stop makes multi-hour wall-clock gaps routine. On the first tick after wake:
- `approval.ex:200` + `phases/awaiting_approval.ex:80` — non-critical approvals **auto-approve and merge** after a nominal 1h window the human never saw (box was off). Highest blast in the audit: it merges code.
- `approval.ex:235` — critical approvals auto-**reject and terminally fail** after a 24h wall-clock window; one idle weekend kills every pending critical mission.
- `orchestrator.ex:289-305` — `quest_timed_out?` force-completes every non-terminal mission older than max age, with plausible-looking timeout telemetry.
- `orchestrator.ex:1180` — phase "stall" detection re-dispatches every mid-flight phase: duplicate ghosts, spend, commits.
- `shell.ex:209` — 24h "stale branch" cleanup **deletes branches of in-flight missions** after a sleep.
- Storm tier: `tachikoma.ex:1111` retry cooldowns, `idle_sweeper.ex:130` janitor cooldowns, `alerts.ex:203/218` + `health.ex:154` false stuck-alert storms, `debrief.ex:29` review windows, `rollback.ex:135` revert window silently closing, `budget.ex:70-81` rolling spend window sliding over the sleep.

**Fix pattern (one mechanism):** a `GiTF.Clock` with `awake_elapsed/1` backed by a persisted heartbeat tick; on boot, a detected gap is subtracted from every age computation; plus a post-boot quiet period during which nothing auto-approves, auto-fails, auto-deletes, or auto-alerts. Effort M for the module, S per call site.

### C2 — Delivery lies: outward git/GitHub side effects are never verified (CRITICAL)
- `publish.ex:326` — `git push` result **discarded**; a rejected push still reports the mission delivered, "verified" against a stale PR that lacks the work.
- `github.ex:33-34` — PR-create accepts 200; a renamed repo 301s, Req demotes POST→GET, returns a PR *list*, and `{:ok, nil}` is logged as "PR created:".
- `rollback.ex:167-227` — failed revert pushes still stamp `reverted_at`; `guard_not_reverted` then permanently blocks retries while origin still carries the bad merge.
- `sync.ex:474-501` — `-X theirs` on any merge failure can silently discard **origin-side commits by other people** into a PR (local main never fast-forwarded).
- `sync.ex:139-150` — push failure explicitly downgraded to `:ok` ("branch might already be pushed").
- `sync.ex:505-516` — `ensure_local_branches` ignores fetch failures; merges against stale branches.
- `github/cli.ex:79-88` + `outcomes/alerts.ex:104` — CI polling hardcodes `--branch main`; master-repos read as eternally green, and the red-CI downgrade races CI completion (one-shot, structurally no-op).
- `report.ex:87,374` — reads `pr_url` from the `sync` artifact; publish writes it to the `publish` artifact — the report's PR link is always empty on the PR workflow.

**Fix pattern:** verify-then-use at every boundary write — assert push exit + compare `rev-parse` local vs origin; accept 201 only with `redirect: false`; never stamp state flags on unverified side effects.

### C3 — Auth death spirals: expiry is a certainty, treated as an anomaly (HIGH)
- `keys.ex:134-140,231-241` + `bedrock_direct.ex:336-345` — env AWS creds are never refreshed and **shadow the working IMDS path forever**; expired SSO creds read as a provider outage.
- `github/cli.ex:166-177` + `outcomes/tracker.ex:173-174` — an expired PAT makes GitHub 404 private repos; classified `:permanent` → `stop_tracking`, **irreversibly** killing the outcome/learning loop with no alert.
- `bedrock_direct.ex:361-401` — IMDS cache never invalidated on 403; unparseable Expiration invents +1h validity.
- `github.ex:346-347` — nil token silently yields an *anonymous* client: private-repo reads become 404-lies ("issue not found"), writes burn the 60/hr IP budget.
- `telegram.ex:198-215` — poll loop swallows 401 (revoked token) and 409 (second instance stealing updates) forever, silently.

### C4 — Resume/version-skew: the factory's past self is an untrusted writer (HIGH)
- `workflow/advancer.ex:44-53` — a phase id renamed/removed by a deploy **rewinds every in-flight mission to phase 1** (re-pays the whole pipeline; can re-implement over merged work). Largest money blast found.
- `backup.ex:44,119-125` — checkpoint `:seq` (`unique_integer`) is not comparable across VM boots; pre-restart checkpoints can outrank newer ones → ghosts resume from older progress.
- `archive.ex:500-514,644-690` — an undecodable primary collection file is silently **overwritten from a `.bak` generation** (up to ~15 min of missions/ops reverted, unrecoverable); `read_manifest` lacks the unsafe-fallback the main path has.
- `migrations.ex:11-24` — forward-only, one-shot, no downgrade guard; a rollback deploy strands records without backfilled fields → `KeyError` crash loops in drift/model-routing readers (`drift.ex:155+`, `ghosts.ex:403`).
- `missions.ex:1002` + `orchestrator.ex:577,1165,1237` — a compacted artifact stub (`%{"compacted" => true}`) passes `artifact_failed?` and reads as a real phase output → complexity nil → full pipeline re-run.
- `togusa/fix_context.ex:105-140` — shape drift decodes to nil → fix-attempt budget silently resets to 0 → unbounded fix ghosts against the budget cap.
- `api_controller.ex:876-894` + `priority.ex:74` — REST serialization changes types (atoms→strings); CLI shows `critical (effective: normal)`; serializer silently drops newer fields; no version negotiation on the wire (daemon publishes `version`; Client never reads it).
- `api_controller.ex:569-596` — sector PUT silently discards unknown fields and 200s (newer CLI vs older daemon = applied-but-not lie).
- `ops.ex:27-49` — legacy `"killed"` status unknown to the transition table: those records are un-resettable forever.
- `missions.ex:812` — `@pipeline_phases` is a 6-entry hand copy of the 13-phase workflow YAML; drift re-enables premature `completed`.

### C5 — Silent config/store corruption (HIGH)
- `config/provider.ex:174` — unparseable config.toml → `%{}` with **no log**; daemon boots "healthy" on pure defaults.
- `config.ex:196-241` — `encode_toml` is not a real TOML encoder (DateTime structs mangle, nil crashes); `gitf use` and `gitf login` round-trip the whole file through it; `medic.ex:503` `doctor --fix` overwrites project config with defaults.
- `archive.ex:530` + `gitf.ex:62-67` — missing store file → empty collection, and store root resolved by cwd-walk: a wrong cwd silently selects/creates a different store and overwrites on first flush.
- `install-systemd.sh:19-23` — documented S3 restore leaves root-owned files; daemon reads them but every flush EACCES-fails forever → factory runs from ETS only, loses everything at next restart.
- No disk-space check exists anywhere; ENOSPC = silent store/disk divergence.
- `socket_listener.ex:130-183` — PID file on persistent storage + PID reuse after reboot → daemon refuses to boot ("already running") after any unclean stop.
- `archive.ex:876` + `safe_atom.ex:32` — un-internable .etf filenames silently skipped and then dropped from the manifest.

### C6 — Toolchain pins without renewal stories (MEDIUM, systemic)
- `quality/security.ex:73-125` — `rescue` cannot catch the linked task's `:enoent` exit (box has no mix/cargo/pip-audit → crash misattributed to gitf); npm 11 JSON reshape → security gate silently green. (static_analysis.ex:28 shows the correct pattern.)
- `validator.ex:69-92` — missing npm = exit 127 blamed on the ghost's code; classify 126/127 as `:tool_missing`.
- `user_data.sh.tpl:56-76` — four unverified curl-pipes under `set -e`; first failure silently truncates provisioning (possibly no tailscale → unreachable box); no post-install assertions.
- `rel/gitf-backup.sh` — no `aws` presence check, no OnFailure, no freshness alarm: backups can fail hourly forever, discovered at restore time.
- `ci.yml:24` — `ubuntu-24.04-arm` runner label is a single point for the whole distribution path, no documented fallback; `@v2/@v4` mutable action tags; `action-gh-release` silently **updates assets on an existing tag** (self-update compares version strings, no digest → replaced binaries invisible).
- `ci.yml:120-122` — missing `TAP_GITHUB_TOKEN` skips the formula bump with `exit 0`; brew users diverge unboundedly. `version` sed lacks the `grep -q` assertion its siblings have.
- `git.ex:503` — `safe_cmd`'s `:git_not_found` error is unreachable (raises in task instead); `github/cli.ex:142` bare `gh` without find_executable; `publish.ex:371-377` missing `{:exit,_}` clause = CaseClauseError on absent gh.
- `mix.exs:71` — `~> 0.5` req floor doesn't encode the CVE fix (0.5.17); `loadout.ex:392` follows model-supplied redirects. OTP skew: escript is OTP27 bytecode with no minimum-OTP assertion at entry. `Dockerfile:61` unpinned `npm -g claude-code` with `|| echo WARN`.
- Gemini/misc: `gemini_cache_manager.ex:39` cache keyed on content hash without model (cross-model 400 loops for the TTL); `llm_client.ex:181-218` Gemini finishReason/blockReason unchecked → empty success + nil usage poisons cost accounting; `llm_client.ex:81` key in URL query (leaks in logs) on v1beta; `model_resolver.ex:111-118` `String.split(":") |> List.last()` → every Bedrock model's trust bucket is literally `"0"`; no GitHub rate-limit awareness anywhere (8-concurrent poller + no Retry-After handling); `provider_manager.ex:31-78` fallback tier tables contain retired/never-valid vendor model IDs (groq/together/fireworks/mistral) — the fallback chain is partly decorative.

## Status (updated same day)

**APPLIED** (three commits following the audit): all of C1 (GiTF.Clock +
awake-time deadlines + boot grace); C2 delivery verification (publish push
assert + SHA compare, 201-only PR create with redirect:false, revert-flag
honesty + :critical alert, sync push verify, -X theirs alert, fetch-failure
logging, report pr_url source, default-branch CI polling, gh URL regex
extraction, {:exit,_} clause); C3 auth (AWS env-cred expiry + IMDS 403
cache-drop + no-invented-validity, auth-aware gh :permanent classification
+ alert, no anonymous GitHub client, Telegram 400-retry/401/409 logging);
C4 (workflow-drift hold, checkpoint ordering, .corrupt preservation,
manifest unsafe fallback, downgrade guard, compacted-artifact rejection,
FixContext attempt preservation, killed-status reset, string priorities,
sector PUT 422); C5 (loud toml parse errors, TOML encoder struct/nil
handling, doctor --fix preservation, upgrade chown repair, boot-id
pidfiles, uninternable-etf logging); C6 (security-audit tool gating,
validator 126/127 tool-missing, backup.sh aws check, CI assertions +
tap-token failure + runner-label note, git 127 shape, normalize_key
bedrock fix, Gemini cache {content,model} key + blocked-response errors,
req >= 0.5.17 floor).

**DEFERRED** (structural, tracked in the triage memory): per-record `_v`
versioning; CLI↔daemon wire version negotiation; disk-space monitoring
(:disksup); action SHA pins + Dependabot; self-update content digest;
vendor fallback model-ID catalog refresh; @pipeline_phases derivation
from workflow YAML; Dockerfile claude-code pin; GitHub rate-limit
awareness; outcome delayed re-check before terminal seal; events-store
count/byte cap; external dead-man heartbeat; approval Telegram commands;
budget-cap unification; PrivateTmp docs; store cwd-walk hardening.

## Recommended fix order
1. **C1 wake-clock** (GiTF.Clock + quiet period) — it merges/destroys work and fires on every wake.
2. **C2 delivery verification** — publish push assert + PR-create 201/redirect:false + revert-flag honesty (all S).
3. **C3 auth spirals** — cred expiry handling + auth-probe before `:permanent` classification.
4. **C4 top two**: workflow-drift hold-don't-rewind + checkpoint seq ordering.
5. **C5 config/store**: toml parse failure loud + restore chown + downgrade guard.
6. **C6** as dogfood-mission fodder once gitf-as-sector exists (most are S and single-concern).

## Structural gaps behind most findings
- No record/artifact versioning (`_v`) — "what did the writer assume" is unanswerable at read time.
- No version negotiation on the CLI↔daemon wire — skew detected as wrong values, not wrong versions.
- Outward side effects (push, PR, label, revert, message-send) systematically unverified.
- Wall-clock arithmetic across a machine that sleeps daily.
- Pins without a named mutator + renewal trigger (the hexpm image comment is the in-repo gold standard; apply its shape everywhere).
