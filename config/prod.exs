import Config

# OpenTelemetry in prod: ratio-based sampling (default 10%) to avoid
# exporting 100% of traces. Override via OTEL_TRACES_SAMPLER_ARG.
otel_sample_ratio =
  case Float.parse(System.get_env("OTEL_TRACES_SAMPLER_ARG") || "0.1") do
    {f, _} -> f
    :error -> 0.1
  end

config :opentelemetry,
  sampler: {:parent_based, %{root: {:trace_id_ratio_based, otel_sample_ratio}}}

config :gitf, GiTF.Web.Endpoint,
  debug_errors: false,
  check_origin: true

# Logger level is set in config/runtime.exs via LOG_LEVEL env var so it can
# be tuned without rebuilding the release.

# Prod: no local-IP auth bypass by default — behind a reverse proxy, all
# traffic appears as 127.0.0.1. Require explicit API key auth. Operators
# deploying behind a trusted proxy may opt in via runtime.exs.
config :gitf, :local_ip_bypass, false
config :gitf, :trust_x_forwarded_for, false
