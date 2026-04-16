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
  job_spawn_interval_ms: 15_000

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

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:remission_id]

# OpenTelemetry — default to OTLP export if OTEL_EXPORTER_OTLP_ENDPOINT is set
config :opentelemetry,
  resource: %{service: %{name: "gitf"}},
  sampler: {:parent_based, %{root: :always_on}},
  traces_exporter: {:otel_exporter_otlp, %{protocol: :http_protobuf}}

import_config "#{config_env()}.exs"
