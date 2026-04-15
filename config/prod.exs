import Config

config :gitf, GiTF.Repo, database: ".gitf/gitf.db"

config :gitf, GiTF.Web.Endpoint,
  debug_errors: false,
  check_origin: true

config :logger, level: :info
