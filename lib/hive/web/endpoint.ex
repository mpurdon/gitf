defmodule Hive.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :hive

  @session_options [
    store: :cookie,
    key: "_hive_key",
    signing_salt: :crypto.hash(:sha256, "hive_session_" <> to_string(:erlang.phash2({node(), :os.getpid()}))) |> Base.encode64(padding: false) |> binary_part(0, 24)
  ]

  socket "/socket", Hive.Web.UserSocket,
    websocket: true,
    longpoll: false

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Hive.Web.StaticAssets

  plug Plug.Static,
    at: "/",
    from: :hive,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Logger, log: :info

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug Hive.Web.Router
end
