defmodule GiTF.Dashboard.Endpoint do
  @moduledoc """
  Phoenix endpoint for the GiTF web dashboard.

  This endpoint is NOT started automatically in Application.ex. It is
  started on demand when the user runs `gitf dashboard` from the CLI.
  This keeps the footprint small for normal orchestration work.
  """

  use Phoenix.Endpoint, otp_app: :gitf

  @session_options [
    store: :cookie,
    key: "_hive_dashboard",
    signing_salt:
      System.get_env("LIVE_VIEW_SIGNING_SALT") ||
        (if Mix.env() == :prod,
           do: raise("LIVE_VIEW_SIGNING_SALT env var required in prod"),
           else: "gitf_salt_dev"),
    same_site: "Lax",
    http_only: true,
    secure: Mix.env() == :prod
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :gitf,
    only: ~w(assets)
  )

  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session, @session_options)

  plug(GiTF.Dashboard.Router)
end
