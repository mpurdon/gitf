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

# Isolate the test suite's store from wherever the repo happens to live.
# Without this, `mix test` run inside a workspace (including this source
# repo) boots the Archive against that workspace's REAL .gitf/store — tests
# then read accumulated dev data and leak their own writes back into it.
# This was the standing source of "fails here, passes in a clean checkout":
# debrief counts off by one, phantom sectors saturating the pool, etc.
# Evaluated per mix invocation, so every run gets a fresh directory.
config :gitf,
       :store_dir,
       Path.join(
         System.tmp_dir!(),
         "gitf_test_store_#{System.os_time(:millisecond)}_#{System.unique_integer([:positive])}"
       )

# Disable the Archive's periodic async flush in tests: they flush explicitly
# (Archive.flush/0) where they assert on disk, and the terminate flush handles
# graceful stops. This prevents a background disk write from racing a test's
# temp-dir teardown.
config :gitf, :archive_flush_interval_ms, 0

# The janitor's boot-time recovery + timers stay off in tests: the Core
# supervisor restarts every time a test swaps the Archive, and each restart
# would asynchronously advance missions created by other tests (completing
# them, starting reviews) — the main source of cross-test flakes. Tests
# drive the janitor's public functions directly, per its own design.
config :gitf, :janitor_autonomous, false

# Disable OTel tracing in tests
config :opentelemetry,
  traces_exporter: :none
