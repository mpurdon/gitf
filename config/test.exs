import Config

config :gitf, GiTF.Repo,
  database: Path.join(System.tmp_dir!(), "gitf_test_#{System.unique_integer([:positive])}.db"),
  pool_size: 1

config :gitf, GiTF.Dashboard.Endpoint,
  http: [port: 4002],
  server: false,
  secret_key_base:
    "test_secret_key_base_at_least_64_bytes_long_for_phoenix_endpoint_testing_abcdefghij",
  render_errors: [formats: [html: GiTF.Dashboard.ErrorHTML], layout: false],
  pubsub_server: GiTF.PubSub,
  live_view: [signing_salt: "gitf_dashboard_test_salt"]

config :logger, level: :warning

# Disable OTel tracing in tests
config :opentelemetry,
  traces_exporter: :none
