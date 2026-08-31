# Ministries — multi-tenant separation for the factory

*Plan of record, 2026-08-31. Written after the inquiry-gate night
(`docs/stories/2026-08-31-inquiry-gate-first-runs.md`) surfaced the need: the
operator wants the factory working on employer ("Trajector") codebases with
the employer's Bedrock account, the employer's git identity, and a hard
guarantee that nothing bleeds between that work and personal projects.*

## The concept

Ghost in the Shell's chain of command is **Ministry → Bureau → Section**, and
this codebase already calls the factory the *Section* ("Manage codebases
(sectors) tracked by this section", `section:alerts`). The unit above sector
that means "the organisation this work is done *for*, with its own authority,
identity and budget" is the **Ministry**.

- **Ministry** — a client/tenant. Owns: git identity, GitHub credentials, LLM
  provider routing + cloud credentials, cost caps, autonomy defaults, and an
  isolation boundary.
- **Section** — the factory (unchanged).
- **Sector** — a codebase, now carrying a `ministry_id`.

Initial ministries: `home-affairs` (the operator's own projects — cora, gitf
dogfooding) and `trajector` (employer work: work Bedrock, work email, work
GitHub account).

## Ground truth — what is global today (verified in code)

| Concern | Today | Where |
|---|---|---|
| git author/committer | hardcoded `user.name=gitf`, `user.email=gitf@localhost` at sector clone | `lib/gitf/sector.ex:106-108` |
| GitHub token | one: `GITHUB_TOKEN` env → `[github] token` in config.toml → `gh auth token` keyring | `lib/gitf/github.ex` `github_token/0` |
| PR / push | `git push origin` from the sector clone (remote-URL creds), GitHub REST with the one token | `lib/gitf/publish.ex`, `lib/gitf/github.ex` |
| Claude CLI auth | the box's one login state (shared `~/.claude`); ghost env deliberately **scrubs** AWS vars | `lib/gitf/runtime/claude.ex` `@scrubbed_env_vars`, `build_env/1` |
| In-process LLM (bedrock/google) | one `[llm]` block: `execution_mode`, `provider_priority`, `[llm.providers.bedrock] aws_profile/region` + tier models; `Keys.load/0` loads **one** AWS profile into node env at boot | `lib/gitf/runtime/keys.ex`, `provider_manager.ex` |
| Sector record | `validation_command`, `validation_timeout_ms`, `sync_strategy`, `require_human_approval` — no identity/provider fields | `api_controller.ex @sector_mutable_fields`, Archive `:sectors` |
| Sandbox | bwrap binds the **whole factory home read-only** + worktree writable + shared `.claude/.config/.cache/.npm/.cargo` writable; `--share-net` | `lib/gitf/sandbox/bubblewrap.ex:52-141` |
| Install cache | global, keyed by lockfile SHA-256, hardlinked across all sectors | `lib/gitf/install_cache.ex` |
| Knowledge / skills / sector intelligence | already `sector_id`-scoped | `knowledge/prompt_context.ex`, `skills/retrieval.ex`, `intel/sector_profile.ex` |
| Costs | per ghost → op → mission → sector; no ministry rollup or cap | `lib/gitf/costs.ex` |
| Backups | one S3 bucket in the personal AWS account snapshots the whole data volume | `gitf-backup.timer` |

## The edges that bite (why each ministry field exists)

1. **Commits are made by more than ghosts.** Consolidation merges, sync
   commits, `scrub_committed_residue`'s cleanup commit, publish — all run as
   the daemon in the sector clone or worktrees. Setting identity per-command
   would miss one; setting **repo-local `git config user.name/user.email` at
   clone and worktree creation** covers every git operation in that tree
   forever. This is the one-line-per-seam fix, and it's why identity lives on
   the ministry, not in ghost env.
2. **The GitHub token is read in four places** (publish REST, review intake,
   events poller, outcomes tracker). All must resolve **sector → ministry →
   token** or work PRs get opened/commented by the personal account. A
   fine-grained PAT (or GitHub App installation) per ministry; org SSO
   authorisation required for the Trajector one.
3. **Push credentials are not the API token.** `git push origin` uses the
   remote URL / credential helper. Per-ministry: embed `x-access-token:<token>@`
   in the remote URL at clone (rotatable via `git remote set-url`), or a
   per-ministry SSH key with an `core.sshCommand` repo-local config. Prefer
   the https+token form — it reuses the same secret as the API.
4. **The Claude CLI's identity is account-level, not per-spawn.** Ghosts for
   `trajector` must not run on the personal Anthropic subscription. The CLI
   supports `CLAUDE_CODE_USE_BEDROCK=1` + AWS creds + region via env, and
   `CLAUDE_CONFIG_DIR` relocates its config/state. Per-ministry ghost env:
   `CLAUDE_CONFIG_DIR=/var/lib/gitf/ministries/<slug>/claude`,
   `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_*` creds for the ministry profile,
   `AWS_REGION`. **This inverts today's scrub**: `Runtime.Claude.build_env/1`
   deliberately deletes AWS vars from ghost env; the scrub must become
   "scrub unless the ministry supplies them" — supplied creds are the
   ministry's own Bedrock, which the ghost legitimately needs.
5. **`Keys.load/0` puts ONE profile into node env.** Two ministries with two
   AWS accounts cannot share node env. In-process Bedrock calls (ReqLLM) must
   take credentials per request (per-ministry provider config resolved at
   call time), and the node-env path becomes the `home-affairs` default only.
   SSO-expiry handling (`env_creds_expired?`) must become per-profile.
6. **A ghost can read every other ministry's code.** bwrap binds the whole
   home read-only. An LLM in a `trajector` worktree can `cat` cora's source —
   and vice versa, which is the worse direction (client code leaking into
   personal-project prompts). The bind set must become: the ghost's own
   worktree (rw) + the **ministry's** cache dirs (rw) + toolchains (ro) —
   *not* `$HOME`, and never `sectors/` wholesale or `.gitf/` store files.
7. **Shared caches are a side channel.** `~/.claude` (CLI memory/settings),
   `~/.npm`, `~/.cargo`, and the install cache are shared. `.claude` memory
   is the sharpest edge — the CLI can carry context between sectors. Fix:
   per-ministry `CLAUDE_CONFIG_DIR`, per-ministry npm/cargo cache dirs bound
   into the sandbox, and the install cache rooted per ministry
   (`.gitf/cache/<ministry>/node_modules/<key>`); content-addressing already
   prevents code mixing, the per-ministry root prevents hardlink coupling and
   makes deletion-by-ministry trivial.
8. **The box and its backups live in the personal AWS account.** Work source
   sits on a personal EBS volume and is snapshotted to a personal S3 bucket.
   This is a policy decision, not a code fix. Options, strongest first:
   (a) a second box per ministry — the terraform + installer already support
   it, and it makes every other isolation concern moot; (b) same box,
   per-ministry backup exclusion or a work-owned bucket for the work
   sector's paths; (c) accept and document. **Operator decision required
   before real Trajector code lands.**
9. **Costs must split for expensing.** Bedrock usage on the work profile
   bills to the work account by construction (good — that's most of it), but
   the factory's own ledger must roll up per ministry for caps and for the
   Trajector invoicing flow. `costs` records reach ministry via sector; add
   `ministry_id` at record time to avoid join-time archaeology.
10. **Approval posture differs per client.** Work code likely wants
    `require_human_approval` and a stricter autonomy tier by default —
    ministry-level defaults that sectors inherit unless overridden.
11. **Webhooks/events**: the events poller and review intake iterate
    outcomes; each poll must use that outcome's ministry token, and webhook
    secrets become per-repo as today (no change beyond token resolution).
12. **Attribution trailers**: the `Co-Authored-By` / PR-body attribution the
    factory writes should be per-ministry text (an employer may not want
    tool attribution in commits at all).

## Design

### The record

New Archive collection `:ministries`:

```elixir
%{
  id: "min-...",            # generated
  slug: "trajector",        # stable, used in paths
  name: "Trajector",
  git: %{author_name: "...", author_email: "work@..."},
  github: %{auth: :env_ref, env: "GITF_MIN_TRAJECTOR_GITHUB_TOKEN",
            attribution: :none | :default | "custom text"},
  llm: %{execution_mode: :bedrock, provider_priority: ["bedrock"],
         aws: %{profile_env: "GITF_MIN_TRAJECTOR_AWS", region: "us-east-1"},
         tiers: %{fast: "...", general: "...", thinking: "..."}},
  limits: %{cost_cap_usd_month: 200.0},
  defaults: %{require_human_approval: true, autonomy_tier: :require_approval},
  isolation: %{claude_config_dir: true, cache_root: true}
}
```

**Secrets are never in the Archive.** Ministry records hold *references*;
values live in `/etc/gitf/ministries/<slug>.env` (0600, root-owned, loaded at
boot beside `gitf.env`, hot-reloadable via `Config.Provider.reload()` like
everything else). AWS uses named profiles in the service user's
`~/.aws/config` (SSO or keys), referenced by profile name.

`:sectors` gains `ministry_id` (required). Migration backfills every existing
sector to `home-affairs`, which is created with today's global values — so
**M1 ships with zero behaviour change for existing sectors**.

### The three spawn-time seams

Everything resolves through one function, `GiTF.Ministry.for_sector(sector_id)`,
called at:

1. **Worktree/clone creation** (`Sector.add`, `Ghosts.spawn_in_worktree`,
   shell adoption): repo-local git config (name/email, remote URL with the
   ministry token, attribution), per-ministry cache dirs created.
2. **Ghost spawn env** (`Runtime.Claude.build_env/1` via `Loadout`):
   `CLAUDE_CONFIG_DIR`, Bedrock env + creds when the ministry says so,
   scrub otherwise (today's behaviour).
3. **Every GitHub call** (`GitHub.request` gains a `ministry:`/`sector:`
   option; publish, review intake, events poller, outcomes tracker pass it).

Plus one render-time seam: `ProviderManager`/`ModelResolver` keyed by
ministry for the in-process paths (validation LLM, knowledge embeddings,
triage) — per-request credentials, not node env.

### Sandbox

`Sandbox.wrap_command` gains the sector's ministry context and binds:

- rw: the worktree; `/var/lib/gitf/ministries/<slug>/{claude,npm,cargo,cache}`
- ro: toolchains (`/usr`, `/opt/node`…), the sector's own clone (for git
  alternates), **nothing else under the factory home**
- keep `--unshare-all --share-net` (per-ministry egress control is out of
  scope; note it as a later hardening)

A regression test per direction: a sandboxed command in ministry A must fail
to read a file in ministry B's sector and in `.gitf/`.

## Milestones

**M1 — identity (the "work email" ask).** `:ministries` collection + CRUD
(CLI/MCP/API) + `sector.ministry_id` + migration; repo-local git identity and
remote-URL token at clone/worktree creation; `GitHub.*` per-ministry token;
attribution per ministry; dashboard shows the ministry on sector/mission
pages. *Acceptance: a scratch repo under the work GitHub account, onboarded
as a `trajector` sector; one trivial mission; the PR, its commits (author
AND committer), and any comments all carry the work identity, and `git log`
on cora shows nothing changed for `home-affairs`.*

**M2 — provider routing (the "work Bedrock" ask).** Per-ministry `llm` block;
ghost env inversion of the AWS scrub + `CLAUDE_CODE_USE_BEDROCK` +
`CLAUDE_CONFIG_DIR`; per-request creds for in-process providers; per-ministry
cost rollup (`ministry_id` on cost records) + monthly cap enforced where the
mission cost cap already is. *Acceptance: the same trajector mission runs
with zero calls on the personal Anthropic account (verify via `costs` model
prefixes and the work account's Bedrock metrics), and cora still runs on
today's routing.*

**M3 — isolation.** Sandbox bind narrowing + the two cross-read regression
tests; per-ministry install-cache root, npm/cargo caches, claude config dir;
`Skills.Retrieval`/knowledge verified to have no cross-sector fallback
(they're sector-scoped; add the test that proves it). *Acceptance: the
cross-read tests, plus one real mission per ministry run interleaved with no
shared mutable path outside `/tmp`.*

**M4 — posture + operator decisions.** Ministry-default
`require_human_approval`/autonomy inherited by sectors; the backup/box
decision implemented (second box, backup split, or documented acceptance);
dashboard ministry filter; OPERATING.md §"Ministries"; GLOSSARY entry.

Sizing: M1 is the largest single milestone (many call sites, one concept);
M2 is riskier (credentials, the scrub inversion) but smaller; M3 is mostly
sandbox args + tests; M4 is small code, one real decision.

## Decisions only the operator can make

1. **Same box or a box per ministry?** (Edge 8. A second small Graviton box
   in the work context is the clean answer if the employer cares where source
   lives; everything in this plan still applies per box.)
2. **Trajector GitHub auth**: fine-grained PAT from the work account vs a
   GitHub App — PAT is M1-cheap; App is better long-term for org installs.
3. **Attribution policy for work commits** (edge 12): none, default, custom.
4. **Backup handling for work sectors** if staying on one box.

## Explicitly out of scope (for now)

- Per-ministry dashboard *authentication* (tailnet identity already names the
  one operator; multi-operator RBAC is a different project).
- Per-ministry network egress policy in the sandbox.
- OS-user-per-ministry separation (bwrap narrowing first; revisit if a
  second box isn't chosen).
- Moving phase-order knowledge (`@post_validation_phases`) into workflow
  metadata — unrelated cleanup noted in the /simplify pass.
