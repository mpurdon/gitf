import Config

config :gitf, GiTF.Repo, database: ".gitf/gitf.db"

# code_reloader: true makes Phoenix recompile on each HTTP/LiveView request.
# Use `iex -S mix phx.server` for development — no rebuild needed.
# For GenServer changes, run recompile() in the IEx session.
config :gitf, GiTF.Web.Endpoint, code_reloader: true

# Dev: allow local-IP auth bypass for convenient CLI access. Disabled in prod.
config :gitf, :local_ip_bypass, true
config :gitf, :trust_x_forwarded_for, false

config :logger, level: :debug

# OpenTelemetry — stdout exporter for dev visibility
config :opentelemetry,
  traces_exporter: {:otel_exporter_stdout, []}
