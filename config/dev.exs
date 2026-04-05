import Config

config :gitf, GiTF.Repo, database: ".gitf/gitf.db"

# code_reloader: true makes Phoenix recompile on each HTTP/LiveView request.
# Use `iex -S mix phx.server` for development — no rebuild needed.
# For GenServer changes, run recompile() in the IEx session.
config :gitf, GiTF.Web.Endpoint, code_reloader: true

config :logger, level: :debug
