# Ministries and the Cabinet — a fleet of sleeping Sections behind one front door

*Plan of record, 2026-08-31, third revision (operator-driven, same day).
v1 was multi-tenant-in-one-box (retired). v2 was box-per-ministry + a
convenience Cabinet. v3 promotes the Cabinet to the fleet's always-on front
door: webhook ingress + an activation ruleset that decides when a Section is
worth waking. Origin: `docs/stories/2026-08-31-inquiry-gate-first-runs.md`
and the Trajector requirement (work Bedrock, work identity, zero bleed).*

## Decision record (operator, 2026-08-31)

1. **Box per ministry.** A Ministry (client) is a complete Section on its own
   EC2 box. Stopping the box is the tenancy control. Per-ministry config is
   that box's ordinary global config — no multi-tenant code inside the
   factory.
2. **All boxes in the one gitf AWS account** (515020252848). Ministries face
   the world only through their own GitHub identity; work model spend bills
   to work via a Bedrock profile on the work box.
3. **GitHub auth per ministry = fine-grained PAT**, stored only on that
   ministry's box. No GitHub App.
4. **Attribution** (tool-credit trailers, not author email) is a per-box
   setting `on | off | custom`; client ministries default off. Author email
   per box (e.g. `matthew@trajectorservices.com`).
5. **The Cabinet is the one always-on node** — a t4g.micro (~$10.4/mo
   all-in; see costs) on the tailnet, running this codebase in cabinet mode.
   It is the *entire* always-on cost of the fleet: every Section sleeps to
   $0, exactly as today. LLM calls dominate the bill anyway.
6. **The Cabinet is the webhook ingress and the activation gate.** All
   ministries' GitHub webhooks point at the Cabinet. A per-ministry
   **ruleset** (editable in the dashboard) decides, per event, whether to
   wake the Section, queue for the operator, or drop. **Modes** make the
   vacation scenario first-class: on vacation, bugs get worked
   autonomously; features queue until the operator explicitly tells the
   Cabinet to start them.

## The shape

```
                         GitHub (all ministries' repos)
                                   │ webhooks
                                   ▼
              ┌─────────────────────────────────────────────┐
              │  CABINET  t4g.micro · always on · tailnet   │
              │  cabinet.ghostinthefactory.com              │
              │  registry · ingress · ruleset · modes       │
              │  wake/stop · fleet health · cost rollup     │
              │  feature inbox · MCP proxy · release fanout │
              └───────┬──────────────┬──────────────┬───────┘
             wake+forward       wake+forward     (queued: waiting
                      ▼              ▼            for the operator)
        factory.ghost…      trajector.ghost…      <next-client>.ghost…
        Section: home-affairs  Section: trajector  (terraform away)
        sleeps to $0           sleeps to $0
```

Division of authority, deliberately strict:

- **Sections stay authoritative** for everything about the work: missions,
  ghosts, artifacts, PATs, model credentials. The Cabinet holds **no mission
  state, no PATs, no model credentials** — only the registry, per-ministry
  *webhook secrets* (needed to verify ingress signatures), the ruleset, the
  queued-event inbox, and cached health/cost snapshots.
- If the Cabinet is down: Sections still work when driven directly, and each
  Section's **events poller remains the backstop** — on wake it reconciles
  up to 30 days of missed GitHub events. The Cabinet makes reaction *timely*;
  it is never the only path.
- Same-account IAM: the Cabinet's instance role gets
  `ec2:StartInstances/StopInstances/DescribeInstances` scoped by the
  `gitf:ministry` tag. Nothing else.

### Ingress → ruleset → activation

1. GitHub delivers an event to `cabinet…/hooks/<ministry>/<repo>`; signature
   verified against that ministry's webhook secret.
2. The event is classified: `bug` (issue opened/labeled bug), `feature`
   (issue/feature-request), `pr_review` (review or review-comment on a
   factory PR — the review-intake flow), `ci`, `noise`.
3. The ministry's ruleset, under the current **mode**, maps class → action:

   | | normal | vacation | off |
   |---|---|---|---|
   | bug | wake → forward (Section creates+starts a mission per its own config) | wake → forward, **cost-capped** | queue |
   | pr_review | wake → forward (amend-in-place intake) | wake → forward | queue |
   | feature | queue in the **feature inbox**; operator starts it explicitly | queue | queue |
   | ci / noise | drop (poller will see it anyway) | drop | drop |

   Rules are per-ministry, editable in the Cabinet dashboard (the "visual
   ruleset" — start as a simple matrix page, not a rule engine), with
   per-ministry **monthly cost caps** enforced before any wake: a ministry
   over cap queues instead of waking, and the queue page says so.
4. "Wake → forward": start the instance (no-op if awake), wait healthy,
   POST the event to the Section's existing webhook endpoint. The Section
   does what it does today; the Cabinet never creates missions itself.
5. Everything queued lands in the inbox with a one-tap "start this" that
   wakes the Section and forwards — that is how a feature gets worked while
   on vacation: only because the operator said so, from a phone browser on
   the tailnet.

### What stays per-box (unchanged from v2)

Git identity + attribution (config, written as repo-local git config at
clone/worktree creation — replacing the hardcoded `gitf`/`gitf@localhost` at
`sector.ex:106`); `[github] token` (the PAT); the `[llm]` block (the work
box: `CLAUDE_CODE_USE_BEDROCK=1` + work Bedrock profile); per-ministry
backup bucket; approval/autonomy posture (client boxes stricter). Work box
provisioning checklist: logged into nothing personal; `GITHUB_TOKEN` env
must not shadow the box PAT.

## Costs (honest, us-east-1, on-demand)

| Item | Monthly |
|---|---|
| Cabinet t4g.micro (1 GiB — nano's 0.5 GiB is too tight for BEAM + tailscaled headroom) | ~$6.10 |
| EBS gp3 8 GB | ~$0.65 |
| Public IPv4 (required for egress without a NAT gateway) | ~$3.65 |
| **Cabinet total — the fleet's entire always-on cost** | **~$10.40** |
| Each ministry Section | $0 while stopped; hours-used + EBS (~$1–3/mo) + IPv4 while running |

A 1-yr savings plan roughly halves the compute line later; not worth doing
until the Cabinet is proven.

## Milestones

**M1 — identity becomes config** (pure code, no spend, improves today's box:
every cora commit tonight was authored by `gitf@localhost`). `[git]`
author/email/attribution; repo-local git config at clone + worktree
creation; publish honours attribution. Acceptance: configured identity and
attribution appear on a trivial mission's commits (author AND committer) and
PR body; unset = today's behaviour.

**M2 — cabinet-mode build + Cabinet core** (code now; **provisioning
spend-gated**). A config/flag that starts the app without Major/ghost/sector
supervision; `:ministries` registry + CRUD; wake/stop via tag-scoped role;
fleet health + cost rollup pages (phone-friendly, tailnet). Acceptance
(post-provision): from a phone browser, wake a Section, watch it come
healthy, stop it.

**M3 — ingress + ruleset + modes.** Webhook endpoint per ministry/repo with
signature verification; event classifier; the mode/ruleset matrix + editor;
feature inbox with start-this; per-ministry cost caps gating wakes;
repointing GitHub webhooks from boxes to the Cabinet (poller stays as
backstop). Acceptance: with every Section stopped — a bug issue on a cora
repo wakes home-affairs and a mission appears; a feature issue queues and
does NOT wake anything; tapping it in the inbox does; in `off` mode nothing
wakes.

**M4 — the trajector box** (**spend-gated**). Terraform ministry module
(instance tagged `gitf:ministry`, EBS, tailscale, DNS slug, backup bucket,
`/etc/gitf` seed); bring up trajector with work PAT/identity/Bedrock/strict
posture. Acceptance: scratch work-account repo, one mission end-to-end, PR
commits + comments all carry the work identity, `costs` shows only
`bedrock:*` models, home box untouched.

**M5 — routing + fan-out + docs.** `ministry` param on MCP tools via the
Cabinet proxy; CLI `-m <slug>`; release install fan-out; OPERATING.md
§"Ministries and the Cabinet"; GLOSSARY (Ministry, Cabinet, mode).

M1 and the code halves of M2/M3 need no approval. Provisioning the Cabinet
(~$10.4/mo) and the trajector box are each an explicit operator go, per the
standing billable-decisions rule.

## Edges that still bite

- **Webhook secrets on the Cabinet** are the only ministry secret it holds —
  verify-only; a leaked webhook secret forges events but touches no code or
  credentials. Keep it that way: never give the Cabinet PATs.
- **Vacation-mode autonomy needs a leash**: the per-ministry cost cap is the
  hard stop; the Section's own approval posture still applies to what the
  missions do (a client box can require approval even for bug fixes, which
  then queue at the Section's own gate — visible on the Cabinet's fleet
  page).
- **Operator notification while away** (a bug mission failed, a cap was
  hit): the Cabinet page shows it, but push (email/ntfy) is an open item —
  parked, not designed here.
- **Classifier honesty**: "bug vs feature" from labels/heuristics will
  misfire; the failure direction must always be *queue*, never *wake* — a
  misclassified feature costs operator attention, a misclassified wake
  costs money silently.
- **Clock drift on modes**: mode is set by the operator, not inferred;
  vacation doesn't end by calendar unless the operator sets a return date
  (nice-to-have on the mode page).

## Open questions (none block M1)

- Cabinet build as the same CI artifact behind a flag (preferred) vs a
  second release target.
- Notification channel for unattended failures (email/SES vs ntfy vs none).
- Whether `pr_review` events in vacation mode should also honour the cost
  cap separately from bugs (probably yes — same gate).
- Within-box sandbox hardening (don't bind all of `$HOME`) — worthwhile
  defence in depth, tracked outside this plan.
