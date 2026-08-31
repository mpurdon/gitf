defmodule GiTF.Web.CabinetHookController do
  @moduledoc """
  Cabinet webhook ingress: `POST /hooks/:ministry`.

  Verifies the GitHub HMAC against THAT ministry's secret (resolved from
  its env reference), hands the event to `GiTF.Cabinet.Gate`, and answers
  200 immediately — waking and forwarding happen in the background. The
  raw body and signature are kept so the Section can verify the forwarded
  delivery with the same secret; the Cabinet never re-signs anything.

  Unknown ministry and bad signature are both 404 — this path is public
  (tailscale funnel), and it must not confirm which slugs exist.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias GiTF.Cabinet.{Gate, Registry}

  def receive(conn, %{"ministry" => slug}) do
    with %{} = ministry <- Registry.by_slug(slug),
         secret when is_binary(secret) <- Registry.webhook_secret(ministry),
         true <- signature_valid?(conn, secret) do
      event = conn |> get_req_header("x-github-event") |> List.first() || "unknown"

      raw = %{
        "body" => conn.assigns[:raw_body],
        "headers" => forwardable_headers(conn)
      }

      {outcome, _} = result = Gate.handle(ministry, event, conn.body_params, raw)
      Logger.info("Cabinet: #{slug} #{event} → #{outcome}")
      json(conn, %{ok: true, outcome: outcome, event: event})

      _ = result
      conn
    else
      _ ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  defp signature_valid?(conn, secret) do
    with [sig] <- get_req_header(conn, "x-hub-signature-256"),
         raw when is_binary(raw) <- conn.assigns[:raw_body] do
      expected =
        "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

      Plug.Crypto.secure_compare(sig, expected)
    else
      _ -> false
    end
  end

  defp forwardable_headers(conn) do
    for h <- ["x-github-event", "x-github-delivery", "x-hub-signature-256", "content-type"],
        [v | _] <- [get_req_header(conn, h)],
        do: {h, v}
  end
end
