defmodule GiTF.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :gitf

  @session_options [
    store: :cookie,
    key: "_gitf_key",
    signing_salt:
      :crypto.hash(:sha256, "gitf_session_" <> to_string(:erlang.phash2({node(), :os.getpid()})))
      |> Base.encode64(padding: false)
      |> binary_part(0, 24)
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
    only: ~w(assets fonts images favicon.ico robots.txt)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Logger, log: :info)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(GiTF.Web.Router)
end
