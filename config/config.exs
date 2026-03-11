import Config

config :gitf, GiTF.Web.Endpoint,
  http: [port: 4000],
  server: true,
  debug_errors: true,
  check_origin: false,
  watchers: [],
  secret_key_base: "GITF_SECRET_KEY_BASE_CHANGEME_1234567890_extra_padding_to_reach_64_bytes_minimum!!",
  pubsub_server: GiTF.PubSub,
  live_view: [signing_salt: "gitf_live_salt_123"],
  render_errors: [
    formats: [html: GiTF.Web.ErrorHTML, json: GiTF.Web.ErrorJSON],
    layout: false
  ]

config :llm_db,
  data_dir: Path.join(System.user_home!(), ".gitf/llm_db"),
  compile_embed: true

config :gitf, :llm,
  execution_mode: :api,
  default_models: %{
    opus: "google:gemini-2.5-pro",
    sonnet: "google:gemini-2.5-flash",
    haiku: "google:gemini-2.0-flash",
    fast: "google:gemini-2.0-flash"
  }

# Allow ReqLLM to load API keys from .env files when present
config :req_llm, load_dotenv: true

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:remission_id]

import_config "#{config_env()}.exs"
