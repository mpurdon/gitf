defmodule GiTF.Web.TailnetAuth do
  @moduledoc """
  Dashboard identity plug + LiveView mount hook.

  As a plug (in the `:browser`/`:dashboard` pipelines): resolves the
  caller's tailnet identity via `GiTF.Tailnet`, assigns it, stores the
  login in the session for the LiveView socket, and — when enforcement
  is `:required` — rejects unauthorized requests with a 403 before any
  page renders.

  As an `on_mount` hook (in the dashboard `live_session`): re-checks the
  session-carried identity at websocket mount, because router plugs do
  not run for socket upgrades. The session cookie is signed, so a caller
  can only present an identity the plug actually granted.
  """

  import Plug.Conn

  alias GiTF.Tailnet

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    identity = Tailnet.identity(conn)

    if Tailnet.authorized?(identity) do
      conn
      |> assign(:tailnet_identity, identity)
      |> put_session(:tailnet_login, identity && identity.login)
      |> put_session(:tailnet_kind, identity && Atom.to_string(identity.kind))
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Forbidden: this dashboard requires an authorized tailnet identity.\n")
      |> halt()
    end
  end

  def on_mount(:default, _params, session, socket) do
    identity =
      case {session["tailnet_login"], session["tailnet_kind"]} do
        {login, kind} when is_binary(login) and kind in ["local", "tailnet"] ->
          %{login: login, kind: String.to_existing_atom(kind), node: nil}

        _ ->
          nil
      end

    if Tailnet.authorized?(identity) do
      {:cont, Phoenix.Component.assign(socket, :tailnet_identity, identity)}
    else
      # The HTTP request for the page already 403s, so this only fires on
      # hand-crafted socket connects. Redirect home, which 403s too.
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  @doc "The actor login for audit records, from a socket or conn assigns map."
  @spec actor(map()) :: String.t()
  def actor(%{tailnet_identity: %{login: login}}) when is_binary(login), do: login
  def actor(_), do: "unidentified"
end
