defmodule GiTF.Web.CabinetRelayController do
  @moduledoc """
  `POST /relay/:ministry` — a ministry's factory relaying an alert or
  mission event for the Cabinet's Discord bot to post.

  Verified exactly like the GitHub ingress next door: HMAC over the raw
  body with THAT ministry's webhook secret, and 404 for anything that
  fails — this path is public (tailscale funnel) and must not confirm
  which slugs exist. The body is the envelope
  `GiTF.Plugin.Builtin.Channels.Discord.envelope/5` builds: structured
  fields the renderer reads, never raw external text.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias GiTF.Cabinet.Registry

  def receive(conn, %{"ministry" => slug}) do
    with %{} = ministry <- Registry.by_slug(slug),
         secret when is_binary(secret) <- Registry.webhook_secret(ministry),
         true <- GiTF.Web.Signature.valid?(conn, secret),
         %{"type" => type} = event when is_binary(type) <- conn.body_params do
      if GiTF.Cabinet.Discord.enabled?() do
        GiTF.Cabinet.Discord.Bot.post(ministry, event)
        Logger.info("Cabinet relay: #{slug} #{type} → discord")
        json(conn, %{ok: true, posted: true})
      else
        Logger.info("Cabinet relay: #{slug} #{type} received, Discord bot not configured")
        json(conn, %{ok: true, posted: false})
      end
    else
      _ -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end
end
