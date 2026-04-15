import Config

config :gitf, GiTF.Repo, database: ".gitf/gitf.db"

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
