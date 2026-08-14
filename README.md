# GiTF — Ghost in the Factory, Section 9

Multi-agent orchestration system for AI coding assistants. Coordinate multiple AI instances working on a shared codebase with automatic task delegation, isolated git worktrees, inter-agent messaging, cost tracking, and a real-time web dashboard.

**Status: Dark Factory — lights-out hardened.** Fully autonomous operation with self-healing, behavioral quality gates, and intelligent model selection, hardened for unattended multi-day runs:

- **Safe to run unattended** — killable AI subprocesses with hard wall-clock caps, a fail-closed factory-wide daily spend ceiling, terminal escalation on stalled approvals, kernel-sandboxed ghost execution, and non-destructive mission-failure (never `reset --hard` a repo with human work).
- **Trustable quality gate** — beyond unit tests: modality-aware behavioral verification drives each change through its real interface (CLI / HTTP / …) against holdout scenarios judged by an LLM, gating publish.
- **Deployable as a service** — a systemd release with idle-stop economics, S3 backups, and a Terraform stack for a single always-cheap Graviton EC2 box behind Tailscale (see [Deployment](#deployment)).

Built in Elixir, leveraging OTP supervision trees for process management, Phoenix PubSub for messaging, and an ETS-first archive with ETF persistence.

## How it executes work

**No AI coding CLI is required.** The default execution mode is `api`: ghosts run an agentic loop over direct HTTP (via ReqLLM) to a model provider. CLI mode — spawning `claude`, `copilot`, or `kimi` binaries — remains available as an alternative.

| Mode | How | Providers |
|------|-----|-----------|
| `api` (default) | Direct HTTP, agentic loop in-process | Google Gemini (default), Anthropic, OpenAI, Groq, Mistral, Together, Fireworks |
| `bedrock` | SigV4 to AWS Bedrock (no resident API key) | Anthropic models via Bedrock |
| `ollama` | Local models over the OpenAI-compatible API | qwen2.5-coder etc. |
| `cli` | Spawns a local coding CLI per ghost | `claude`, `copilot`, `kimi` (pluggable via `GiTF.Plugin.Model`) |

Select with `--mode api|cli|ollama|bedrock` on any command, `GITF_EXECUTION_MODE`, or `[llm] execution_mode` in config. Models are resolved per task tier (thinking / general / fast) with provider priority, circuit breaking, and rate limiting.

## Getting Started

### 1. Install prerequisites

| Dependency | Version | Install |
|------------|---------|---------|
| **Elixir** | 1.18+ | `brew install elixir` or [elixir-lang.org/install](https://elixir-lang.org/install.html) |
| **Git** | 2.25+ | `brew install git` or [git-scm.com](https://git-scm.com) |
| **An LLM API key** | — | e.g. Google Gemini or Anthropic — or a local coding CLI if you prefer `cli` mode |

### 2. Build the GiTF CLI

```bash
git clone git@github.com:mpurdon/gitf.git
cd gitf
mix deps.get
mix escript.build
cp gitf /usr/local/bin/   # optional
```

### 3. Create a workspace and add a repo

Run any command against the directory you want as your factory — GiTF offers to initialize it:

```bash
gitf -w ~/my-factory medic       # "No gitf project found. Initialize at ...? [y/n]"
cd ~/my-factory
gitf sector add /path/to/your/repo --name myproject
```

Put your API key in the global config (`~/.config/gitf/config.toml`, created for you):

```toml
[llm.keys]
google = "..."      # or anthropic = "..."
```

`gitf medic` verifies everything is ready. `gitf onboard` can auto-detect and register a project with sensible defaults.

### 4. Run work

```bash
gitf run "fix the flaky retry test"     # quick-run a focused task, skips the full pipeline
gitf mission "add rate limiting to the API"   # full Research → Plan → Implement pipeline
gitf major                              # interactive Major coordinator session
```

The Major analyzes the request, breaks it into ops, spawns ghosts (parallel AI instances in isolated git worktrees), and coordinates them to completion.

### 5. Monitor progress

```bash
gitf                    # Interactive "Dark Factory" TUI dashboard
gitf watch              # Live terminal progress (simple view)
gitf mission list       # Active missions
gitf ghost list         # Running ghosts
gitf costs summary      # Token spend
```

## The daemon

For anything beyond one-shot CLI usage, run GiTF as a long-lived service:

```bash
gitf daemon             # (alias: gitf server)  web + REST + MCP + factory
```

One process serves, on port 4000 (`-p`/`GITF_PORT`):

- **Web dashboard** — `http://localhost:4000/dashboard`: overview, missions (plan / design / diagnostics), ghosts, ops, approvals, costs, model performance, providers, sectors, shells, workflows editor, merge queue, timeline, rollback, autonomy, health, settings — and the **Planning Studio** (`/dashboard/studio`), a live split-pane where a conversation with the planner builds the project board in real time, with optional voice input (Gemini Live, off by default).
- **REST API** — `/api/v1`: missions (including the plan/confirm/reject/revise loop), ops, ghosts, projects, sectors, costs, plus public `health`, `ready`, `version`, an authenticated Prometheus `metrics` endpoint, and HMAC-verified GitHub/Sentry webhook receivers.
- **MCP server** — a Unix socket at `~/.config/gitf/mcp.sock` (daemon mode) or stdio via `gitf mcp-serve`, so Claude Code and other MCP clients can drive the factory as tools.

Authentication is an `x-api-key` header checked against `GITF_API_KEY` (or `[server] api_key`). Point a remote CLI at a daemon once with:

```bash
gitf login https://factory.example.com --key YOUR_KEY
```

after which every `gitf` command on that machine transparently drives the remote factory.

## Projects (Aramaki)

Missions are single objectives; **projects** are DAG-scheduled roadmaps of many missions:

```bash
gitf project new        # interactive planning discussion → roadmap → approve → execute
gitf project list / show <id> / pause <id> / resume <id>
```

Aramaki can also watch GitHub issues (opt-in, `GITF_ARAMAKI_ENABLED`): it admits work labeled `gitf:build` within budget/capacity and reports progress back on the issue.

## Workflows

Mission phase pipelines are data, not code: YAML workflows with per-phase handlers, model tiers, timeouts, and pass/fail routing. Eight templates ship in `priv/workflows/` (`standard`, `bug-fix`, `refactor`, `perf`, `security-patch`, `dep-upgrade`, `doc-only`, `spike`); user-supplied workflows are picked up per sector.

```bash
gitf workflow list / show <name> / validate
```

There's a visual editor at `/dashboard/workflows`.

## Safety machinery

On by default:

- **Sandboxed execution** — AI-authored commands run under `bwrap` (Linux), `sandbox-exec` (macOS), or Docker. `GITF_SANDBOX_REQUIRED=1` makes this fail-closed: no sandbox, no execution (the server deployment ships with this on).
- **Spend control** — per-mission budgets plus a fail-closed factory-wide daily ceiling (`daily_budget_usd`); breach pauses the factory rather than burning on.
- **Kill discipline** — every OS subprocess is signal-killed with grace periods, child reaping, and zombie detection; wall-clock caps bound every ghost.
- **Non-destructive failure** — mission failure and `gitf rollback` use `git revert`, never `reset --hard`.

## Alerting

Severity-mapped alerts (budget pauses, stalled ghosts, approval requests, cost spikes…) with deduplication go to a JSON webhook (`[observability] webhook_url` — ntfy.sh, Slack, …) and/or the built-in **Telegram channel plugin**, which also accepts inbound commands (`/ghost list`, `/mission show 1`). OpenTelemetry export and a Prometheus endpoint cover metrics.

## The intelligence layer (default off)

Beyond the core pipeline, GiTF has an opt-in learning loop — each piece is a feature flag, off until you enable it:

| Capability | Flag |
|------------|------|
| Skill library — capture lessons as reusable skills, injected by embedding similarity | `GITF_SKILLS_ENABLED` |
| Outcome tracking + refinement — did merged work actually survive? | `GITF_OUTCOMES_ENABLED` |
| Autonomy tiers — sectors earn reduced approval requirements from outcome history | `GITF_OUTCOME_AUTONOMY_TIERS_ENABLED` |
| Knowledge engine — a wiki compiled from debriefs, injected into context (BM25 + embeddings) | `GITF_KNOWLEDGE_CONTEXT_ENABLED` |
| LSP-backed validation of generated code | `GITF_LSP_VALIDATION_ENABLED` |
| Workflow inference — pick the right workflow per mission automatically | `GITF_WORKFLOW_INFERENCE_ENABLED` |
| Implementation tournaments — N parallel variants, best one merges | `GITF_PARALLEL_IMPL_ATTEMPTS=N` |
| Aramaki GitHub admission | `GITF_ARAMAKI_ENABLED` |

All flags are logged at boot.

## Deployment

GiTF ships as a proper release:

```bash
RELEASE_TAR=1 MIX_ENV=prod mix release     # or grab gitf-release-arm64 from CI
sudo rel/install-systemd.sh gitf-*.tar.gz  # idempotent: user, /opt/gitf, /etc/gitf, units
```

The systemd bundle includes the daemon unit, an **idle-stop** timer (a quiet factory powers the box off), and an **S3 backup** timer. [`docs/deploy-aws.md`](docs/deploy-aws.md) is the full runbook for the reference AWS deployment — one Graviton EC2 instance with zero inbound ports (Tailscale is the front door), Terraform in [`infra/aws/`](infra/aws/), a wake Lambda for restarting the stopped box from a phone, and idle-stop economics that put a quiet month at ~$3.

## Configuration

Config is layered: global `~/.config/gitf/config.toml` (keys, budgets, thresholds) with per-project overrides in `<workspace>/.gitf/config.toml`. The important global keys:

```toml
[costs]
budget_usd = 10.0            # per-mission
daily_budget_usd = 100.0     # factory-wide rolling 24h, fail-closed
warn_threshold_usd = 5.0

[llm.keys]
google = ""                  # provider API keys
anthropic = ""

[major]
max_ghosts = 5
dark_factory = false

[github]
token = ""

[observability]
webhook_url = ""             # alert webhook (ntfy.sh, Slack, ...)

[server]
url = ""                     # set by `gitf login` for remote CLI use
```

Most settings are also editable live at `/dashboard/settings`. Any command accepts `-w <path>` to target a workspace without `cd`.

## CLI Reference

`gitf quickref` prints the up-to-date card. The full command tree (all support `--help`):

```
Core        run · mission · major · ghost · ops · sector · project · shell
Monitor     (bare gitf = TUI) · dashboard · watch · costs · budget · models · monitor
Quality     verify · accept · validate · quality · scope · audit-adjacent: intel
Daemon      daemon (alias server) · login · mcp-serve
Knowledge   knowledge · vault · workflow
Health      medic · heal · tachikoma · deadlock · optimize · drift · conflict · rollback
Misc        onboard · brief · transfer · link_msg · github · completions · quickref · version
```

## Development

```bash
mix test                      # heavy suites (simulator, e2e, llm, ...) are tag-excluded by default
mix format
mix escript.build             # dev CLI binary
RELEASE_TAR=1 MIX_ENV=prod mix release   # deployable tarball (CI builds arm64)
```

## Further Reading

- [`specs/ARCHITECTURE.md`](specs/ARCHITECTURE.md) — Detailed system design, workflows, and schema.
- [`specs/GLOSSARY.md`](specs/GLOSSARY.md) — Full terminology reference.
- [`specs/DELEGATION.md`](specs/DELEGATION.md) — Major delegation principle and enforcement.
- [`docs/deploy-aws.md`](docs/deploy-aws.md) — AWS deployment runbook.

## License

MIT
