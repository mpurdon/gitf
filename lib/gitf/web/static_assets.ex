defmodule GiTF.Web.StaticAssets do
  @moduledoc """
  Serves Phoenix and LiveView JS embedded at compile time.

  Escripts don't include priv/static, so we read the JS files at compile
  time and serve them from memory via a simple plug.
  """
  @behaviour Plug

  @phoenix_js File.read!("deps/phoenix/priv/static/phoenix.min.js")
  @live_view_js File.read!("deps/phoenix_live_view/priv/static/phoenix_live_view.min.js")
  @sortable_js File.read!("priv/static/assets/sortable.min.js")
  @studio_voice_js File.read!("priv/static/assets/studio_voice.js")
  @external_resource "priv/static/assets/studio_voice.js"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/assets/phoenix.min.js"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/javascript")
    |> Plug.Conn.send_resp(200, @phoenix_js)
    |> Plug.Conn.halt()
  end

  def call(%{request_path: "/assets/phoenix_live_view.min.js"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/javascript")
    |> Plug.Conn.send_resp(200, @live_view_js)
    |> Plug.Conn.halt()
  end

  def call(%{request_path: "/assets/sortable.min.js"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/javascript")
    |> Plug.Conn.send_resp(200, @sortable_js)
    |> Plug.Conn.halt()
  end

  def call(%{request_path: "/assets/studio_voice.js"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("application/javascript")
    |> Plug.Conn.send_resp(200, @studio_voice_js)
    |> Plug.Conn.halt()
  end

  def call(conn, _opts), do: conn
end
