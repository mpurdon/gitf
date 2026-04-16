defmodule GiTF.Dashboard.Endpoint do
  @moduledoc """
  Phoenix endpoint for the GiTF web dashboard.

  This endpoint is NOT started automatically in Application.ex. It is
  started on demand when the user runs `gitf dashboard` from the CLI.
  This keeps the footprint small for normal orchestration work.
  """

  use Phoenix.Endpoint, otp_app: :gitf

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        :peer_data,
        session: {GiTF.Web.SessionOptions, :for_endpoint, [__MODULE__]}
      ]
    ]
  )

  plug(Plug.Static,
    at: "/",
    from: :gitf,
    only: ~w(assets),
    cache_control_for_etags: "public, max-age=31536000, immutable",
    cache_control_for_vsn_requests: "public, max-age=31536000, immutable"
  )

  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 1_000_000
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(GiTF.Web.RuntimeSessionPlug, endpoint: __MODULE__)

  plug(GiTF.Dashboard.Router)
end
