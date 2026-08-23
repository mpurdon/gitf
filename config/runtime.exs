import Config

# Logger level — runtime-tunable so a release doesn't need rebuilding.
log_level =
  case System.get_env("LOG_LEVEL", "info") do
    "" -> :info
    level -> String.to_existing_atom(level)
  end

config :logger, level: log_level

# llm_db data dir — resolved against GITF_HOME at runtime to avoid baking in
# the build user's home directory inside container images.
gitf_home = System.get_env("GITF_HOME") || Path.join(System.user_home!(), ".gitf")
config :llm_db, data_dir: Path.join(gitf_home, "llm_db")

# Feature flags. Env var names match the Application key with a GITF_ prefix.
# Data-driven so every flag the startup log (Application.log_feature_flags/0)
# knows about is actually parseable here — previously several were logged but
# never read, so setting them did nothing. Keep this list in sync with that
# log. (Stopgap until the full Flag Registry + CLI lands.)
boolean_flags = [
  {"GITF_TRIAGE_ENABLED", :triage_enabled},
  {"GITF_SKILLS_ENABLED", :skills_enabled},
  {"GITF_SKILL_REFINEMENT_ENABLED", :skill_refinement_enabled},
  {"GITF_SKILL_AUTO_COMMIT_ENABLED", :skill_auto_commit_enabled},
  {"GITF_OUTCOMES_ENABLED", :outcomes_enabled},
  {"GITF_PR_REVIEW_INTAKE_ENABLED", :pr_review_intake_enabled},
  {"GITF_OUTCOME_REFINEMENT_ENABLED", :outcome_refinement_enabled},
  {"GITF_OUTCOME_AUTONOMY_TIERS_ENABLED", :outcome_autonomy_tiers_enabled},
  {"GITF_VAULT_WRITER_ENABLED", :vault_writer_enabled},
  {"GITF_KNOWLEDGE_CONTEXT_ENABLED", :knowledge_context_enabled},
  {"GITF_KNOWLEDGE_COMPILE_ENABLED", :knowledge_compile_enabled},
  {"GITF_WORKFLOW_DSL_ENABLED", :workflow_dsl_enabled},
  {"GITF_WORKFLOW_INFERENCE_ENABLED", :workflow_inference_enabled},
  {"GITF_LSP_ENABLED", :lsp_enabled},
  {"GITF_LSP_VALIDATION_ENABLED", :lsp_validation_enabled},
  {"GITF_WEBHOOKS_ENABLED", :webhooks_enabled},
  {"GITF_VISUAL_CAPTURE_ENABLED", :visual_capture_enabled},
  {"GITF_SANDBOX_ENABLED", :sandbox_enabled},
  {"GITF_SANDBOX_REQUIRED", :sandbox_required},
  {"GITF_LOG_STDOUT", :log_stdout},
  {"GITF_BEDROCK_PROMPT_CACHE", :bedrock_prompt_cache}
]

for {env_var, key} <- boolean_flags do
  case System.get_env(env_var) do
    v when v in ["false", "0"] -> config :gitf, key, false
    v when v in ["true", "1"] -> config :gitf, key, true
    _ -> :ok
  end
end

# Aramaki (PM/admission layer + project advancement) — nested under :aramaki,
# so it can't ride the flat boolean_flags list above.
case System.get_env("GITF_ARAMAKI_ENABLED") do
  v when v in ["true", "1"] -> config :gitf, :aramaki, enabled: true
  v when v in ["false", "0"] -> config :gitf, :aramaki, enabled: false
  _ -> :ok
end

# Planning-studio voice (nested under :studio, same reason as above).
case System.get_env("GITF_STUDIO_VOICE_ENABLED") do
  v when v in ["true", "1"] -> config :gitf, :studio, voice_enabled: true
  v when v in ["false", "0"] -> config :gitf, :studio, voice_enabled: false
  _ -> :ok
end

if model = System.get_env("GITF_STUDIO_VOICE_MODEL") do
  config :gitf, :studio, voice_model: model
end

# Ghost activity-watchdog stale threshold. Build-heavy sectors (Rust/ts-rs
# bindings take minutes on small boxes) need more headroom than the 120s
# default even with tool-execution heartbeats, because a saturated box can
# delay heartbeat delivery.
case System.get_env("GITF_STALE_THRESHOLD_SECONDS") do
  nil ->
    :ok

  raw ->
    case Integer.parse(raw) do
      {n, _} when n >= 30 -> config :gitf, :timeouts, stale_threshold_seconds: n
      _ -> :ok
    end
end

# Integer-valued flag: number of parallel implementation attempts (tournament).
case System.get_env("GITF_PARALLEL_IMPL_ATTEMPTS") do
  nil ->
    :ok

  "" ->
    :ok

  raw ->
    case Integer.parse(raw) do
      {n, _} when n >= 1 -> config :gitf, :parallel_impl_attempts, n
      _ -> :ok
    end
end

# Traces are exported only when somebody is listening. Without an endpoint the
# OTLP exporter cannot initialise, and it retries noisily rather than staying
# quiet, so the default is no exporter at all.
if endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  config :opentelemetry,
    traces_exporter: {:otel_exporter_otlp, %{protocol: :http_protobuf, endpoints: [endpoint]}}
end

if secret = System.get_env("GITF_GITHUB_WEBHOOK_SECRET") do
  config :gitf, :github_webhook_secret, secret
end

if exe = System.get_env("LSP_EXECUTABLE") do
  config :gitf, :lsp_executable, exe
end

if config_env() == :prod do
  port = String.to_integer(System.get_env("GITF_PORT") || "4000")
  # Default to loopback. Operators must explicitly set GITF_HOST=0.0.0.0
  # (e.g. inside a container behind a reverse proxy) to bind all interfaces.
  host = System.get_env("GITF_HOST") || "127.0.0.1"
  {:ok, ip} = host |> String.to_charlist() |> :inet.parse_address()

  # A stable secret only matters for a network-facing DEPLOYMENT (session/cookie
  # continuity across restarts). A release signals that via RELEASE_NAME, so we
  # hard-require the secret there. A local escript (no RELEASE_NAME) is a
  # single-user daemon — generate an ephemeral secret with a warning so the CLI
  # works out of the box instead of crashing on every invocation.
  require_secret = fn name ->
    case System.get_env(name) do
      nil ->
        if System.get_env("RELEASE_NAME") do
          raise "environment variable #{name} is missing. Generate one via: mix phx.gen.secret"
        else
          IO.puts(
            :stderr,
            "[warn] #{name} not set; using an ephemeral value (OK for local use, NOT a deployment)"
          )

          :crypto.strong_rand_bytes(48) |> Base.encode64()
        end

      value ->
        value
    end
  end

  secret = require_secret.("SECRET_KEY_BASE")
  live_view_salt = require_secret.("LIVE_VIEW_SIGNING_SALT")
  session_salt = require_secret.("SESSION_SIGNING_SALT")

  # A local escript daemon is single-user on the host, so trust loopback and let
  # the CLI/HTTP API work without an API key. A release (a real deployment,
  # possibly behind a proxy where all traffic appears as 127.0.0.1) keeps the
  # bypass OFF — see prod.exs. Operators can still force either via config.
  unless System.get_env("RELEASE_NAME") do
    config :gitf, :local_ip_bypass, true
  end

  check_origin =
    case System.get_env("GITF_CHECK_ORIGIN") do
      nil -> true
      "true" -> true
      "false" -> false
      list -> String.split(list, ",", trim: true)
    end

  # Person-level identity on the tailnet-only dashboard. "required" makes
  # GiTF.Web.TailnetAuth reject browser requests whose peer IP does not
  # resolve (via `tailscale whois`) to a login — optionally restricted to
  # the comma-separated GITF_TAILNET_ADMINS list. Default off: local dev
  # and non-tailnet deployments are unaffected.
  case System.get_env("GITF_TAILNET_AUTH") do
    "required" -> config :gitf, :tailnet_auth, :required
    _ -> :ok
  end

  if admins = System.get_env("GITF_TAILNET_ADMINS") do
    config :gitf, :tailnet_admins, String.split(admins, ",", trim: true)
  end

  # NB: compile-env keys (:code_reloader, :debug_errors, …) must NOT be set
  # here unless config/prod.exs sets the same value at compile time — the
  # release refuses to boot on any mismatch.
  config :gitf, GiTF.Web.Endpoint,
    http: [ip: ip, port: port],
    server: true,
    debug_errors: false,
    check_origin: check_origin,
    secret_key_base: secret,
    live_view: [signing_salt: live_view_salt],
    session_signing_salt: session_salt,
    session_secure: true

  config :gitf, GiTF.Dashboard.Endpoint,
    debug_errors: false,
    check_origin: check_origin,
    secret_key_base: secret,
    live_view: [signing_salt: live_view_salt],
    session_signing_salt: session_salt,
    session_secure: true

  # MCP socket path can be overridden
  if sock = System.get_env("GITF_MCP_SOCK") do
    config :gitf, mcp_sock: sock
  end
end
