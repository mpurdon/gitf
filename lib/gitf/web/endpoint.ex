defmodule GiTF.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :gitf

  @session_options [
    store: :cookie,
    key: "_gitf_key",
    signing_salt:
      System.get_env("SESSION_SIGNING_SALT") ||
        (if Mix.env() == :prod,
           do: raise("SESSION_SIGNING_SALT env var required in prod"),
           else: "gitf_web_salt_dev"),
    same_site: "Lax",
    http_only: true,
    secure: Mix.env() == :prod
  ]

  socket("/socket", GiTF.Web.UserSocket,
    websocket: true,
    longpoll: false
  )

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  if code_reloading? do
    plug(Phoenix.CodeReloader)
    plug(:bust_version_cache)
  end

  def bust_version_cache(conn, _opts) do
    GiTF.reload_version()
    conn
  end

  plug(GiTF.Web.StaticAssets)

  plug(Plug.Static,
    at: "/",
    from: :gitf,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt),
    cache_control_for_etags: "public, max-age=31536000, immutable",
    cache_control_for_vsn_requests: "public, max-age=31536000, immutable"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Logger, log: :info)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 1_000_000
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(GiTF.Web.Router)
end
