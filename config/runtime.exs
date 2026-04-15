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

if config_env() == :prod do
  port = String.to_integer(System.get_env("GITF_PORT") || "4000")
  host = System.get_env("GITF_HOST") || "0.0.0.0"
  {:ok, ip} = host |> String.to_charlist() |> :inet.parse_address()

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one via: mix phx.gen.secret
      """

  live_view_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise """
      environment variable LIVE_VIEW_SIGNING_SALT is missing.
      """

  session_salt =
    System.get_env("SESSION_SIGNING_SALT") ||
      raise """
      environment variable SESSION_SIGNING_SALT is missing.
      """

  check_origin =
    case System.get_env("GITF_CHECK_ORIGIN") do
      nil -> true
      "true" -> true
      "false" -> false
      list -> String.split(list, ",", trim: true)
    end

  config :gitf, GiTF.Web.Endpoint,
    http: [ip: ip, port: port],
    server: true,
    code_reloader: false,
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
