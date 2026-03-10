import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("HIVE_PORT") || "4000")
  host = System.get_env("HIVE_HOST") || "0.0.0.0"
  {:ok, ip} = host |> String.to_charlist() |> :inet.parse_address()

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      "HIVE_SECRET_KEY_BASE_CHANGEME_1234567890_extra_padding_to_reach_64_bytes_minimum!!"

  config :hive, Hive.Web.Endpoint,
    http: [ip: ip, port: port],
    server: true,
    code_reloader: false,
    secret_key_base: secret
end
