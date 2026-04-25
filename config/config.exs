import Config

config :gitf, GiTF.Web.Endpoint,
  http: [port: 4000],
  server: true,
  debug_errors: true,
  check_origin: false,
  watchers: [],
  secret_key_base:
    "GITF_SECRET_KEY_BASE_CHANGEME_1234567890_extra_padding_to_reach_64_bytes_minimum!!",
  pubsub_server: GiTF.PubSub,
  live_view: [signing_salt: "gitf_live_salt_123"],
  session_signing_salt: "gitf_session_salt_dev",
  session_secure: false,
  render_errors: [
    formats: [html: GiTF.Web.ErrorHTML, json: GiTF.Web.ErrorJSON],
    layout: false
  ]

config :gitf, GiTF.Dashboard.Endpoint,
  session_signing_salt: "gitf_dashboard_salt_dev",
  session_secure: false,
  live_view: [signing_salt: "gitf_live_salt_123"]

config :llm_db,
  # data_dir is resolved at runtime via GITF_HOME (see config/runtime.exs) so
  # containers don't freeze in the build user's home directory.
  compile_embed: true

# Routes start_quest through a pre-research triage phase that classifies
# complexity and sets skip_flags to collapse the pipeline. Override with
# GITF_TRIAGE_ENABLED=false to force the legacy `pending → research → ...`
# path (see config/runtime.exs).
config :gitf, :triage_enabled, true

# Timeouts — consolidated so ops can tune without editing module attributes.
# Values in milliseconds unless suffixed with `_seconds`.
config :gitf, :timeouts,
  # Ghost worker heartbeat / staleness
  heartbeat_interval_ms: 15_000,
  stale_threshold_seconds: 120,
  verify_beacon_initial_ms: 10_000,
  checkpoint_interval_ms: 30_000,
  task_skill_freshness_seconds: 3600,
  # Major lifecycle
  pending_timeout_seconds: 600,
  assigned_timeout_seconds: 600,
  clarification_timeout_ms: 15 * 60 * 1_000,
  # Major periodic schedules
  waggle_recovery_interval_ms: 30_000,
  waggle_stale_seconds: 30,
  debrief_interval_ms: 5 * 60 * 1_000,
  stall_check_interval_ms: 2 * 60 * 1_000,
  stuck_recovery_interval_ms: 5 * 60 * 1_000,
  phase_advancement_interval_ms: 3 * 60 * 1_000,
  janitor_interval_ms: 15 * 60 * 1_000,
  autoscale_interval_ms: 60_000,
  job_spawn_interval_ms: 15_000,
  # Post-completion outcome tracking — how often the Tracker wakes to
  # poll open PRs. Per-record next_poll_at already decays (5m→4h), so this
  # is just the polling floor.
  outcome_tracking_interval_ms: 5 * 60 * 1_000

config :gitf, :llm,
  execution_mode: :api,
  default_models: %{
    opus: "google:gemini-2.5-pro",
    sonnet: "google:gemini-2.5-flash",
    haiku: "google:gemini-2.5-flash",
    fast: "google:gemini-2.5-flash"
  }

# Allow ReqLLM to load API keys from .env files when present
config :req_llm, load_dotenv: true

# Self-improving skill library (Milestone 1). When enabled, ghost
# provisioning embeds the op goal, retrieves top-K matching skills from
# the Archive, and installs them into the worktree's .claude/skills/
# directory for Claude Code to discover. Defaults to disabled —
# opt in per environment (see config/runtime.exs or override here).
config :gitf, :skills_enabled, false
config :gitf, :skill_embedding_model, "openai:text-embedding-3-small"
config :gitf, :skill_top_k, 5
config :gitf, :skill_min_similarity, 0.45

# Milestone 2: validator-driven refinement. When `:skill_refinement_enabled`
# is true, the orchestrator spawns an async task after each validation
# phase that attributes outcomes to applied skills and may propose
# new/refined skills. `:skill_auto_commit_enabled` gates whether
# critic-approved drafts actually land in the Archive — keep it false
# during shadow-mode rollout and flip once draft quality has been
# reviewed by an operator.
config :gitf, :skill_refinement_enabled, false
config :gitf, :skill_auto_commit_enabled, false
config :gitf, :skill_refinement_model, "google:gemini-2.5-flash"
config :gitf, :skill_critic_model, "google:gemini-2.5-flash"

# Post-completion outcome tracking. When enabled, the orchestrator
# records a mission_outcomes row each time a mission publishes a PR, and
# the Outcomes.Tracker polls GitHub for state transitions + reviews until
# the PR reaches a terminal category. Feeding those signals back into the
# skill library / Trust / sector profile is gated separately via
# :outcome_refinement_enabled.
config :gitf, :outcomes_enabled, false
config :gitf, :outcome_refinement_enabled, false

# Inbound webhook ingestion. When enabled, /api/v1/webhooks/github
# accepts HMAC-SHA256-signed events. Pull-request events for tracked
# PRs short-circuit the outcome polling cycle. Secret comes from
# config or GITF_GITHUB_WEBHOOK_SECRET env var.
config :gitf, :webhooks_enabled, true
config :gitf, :github_webhook_secret, nil

# Visual capture (screenshots via headless browser). When enabled,
# GiTF.Visual.Capture.screenshot/3 wraps `npx playwright screenshot`.
# Requires `npm install -g playwright` and `npx playwright install
# chromium`. Without these, screenshot/3 returns {:error,
# :driver_unavailable}.
config :gitf, :visual_capture_enabled, true

# Language Server Protocol client. When enabled, GiTF.LSP.Client wraps
# a long-running language server (default: ElixirLS via `language_server.sh`
# on PATH) for symbol-aware navigation. Without a driver on PATH,
# Client.start_link returns {:error, :driver_unavailable}. Override the
# binary via :lsp_executable config or LSP_EXECUTABLE env var.
config :gitf, :lsp_enabled, true
config :gitf, :lsp_executable, nil

# Graduated autonomy from accumulated outcomes. Thresholds are the
# "how confident are we this sector is earning the right to skip
# approval / needs more scrutiny" knobs. Kept off by default — flip on
# only after a sector has 50+ outcomes with refinement enabled.
config :gitf, :outcome_autonomy_tiers_enabled, false
config :gitf, :autonomy_trusted_min_rate, 0.9
config :gitf, :autonomy_trusted_min_samples, 20
config :gitf, :autonomy_require_approval_max_rate, 0.5
config :gitf, :autonomy_require_approval_min_samples, 10
config :gitf, :autonomy_alert_threshold_stddev, 2

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:remission_id]

# OpenTelemetry — default to OTLP export if OTEL_EXPORTER_OTLP_ENDPOINT is set
config :opentelemetry,
  resource: %{service: %{name: "gitf"}},
  sampler: {:parent_based, %{root: :always_on}},
  traces_exporter: {:otel_exporter_otlp, %{protocol: :http_protobuf}}

import_config "#{config_env()}.exs"
