import Config

config :hive, Hive.Repo, database: ".hive/hive.db"

config :hive, Hive.Web.Endpoint,
  code_reloader: true,
  live_reload: [
    patterns: [
      ~r"lib/hive/web/live/.*(ex)$",
      ~r"lib/hive/web/layout.*(ex)$"
    ]
  ]

config :logger, level: :debug
