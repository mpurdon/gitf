defmodule GiTF.Web.WebhookController do
  @moduledoc """
  Inbound webhook receiver for external systems (GitHub today; Sentry,
  Linear, generic to follow).

  Webhooks short-circuit polling: when GitHub fires a `pull_request`
  event for a PR the Factory is tracking, the outcome's `next_poll_at`
  is bumped to now and `Outcomes.Tracker.tick/0` is cast so the next
  pass picks up the new state immediately instead of waiting for the
  decay schedule's next slot (potentially hours).

  Verifies HMAC-SHA256 signatures (`X-Hub-Signature-256`) against the
  raw request body. Body is stashed by `GiTF.Web.CacheBodyReader` before
  `Plug.Parsers` consumes it.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias GiTF.Outcomes

  @doc """
  GitHub webhook receiver. Handles `pull_request` and `ping` events.

  Returns:
    * 200 with `{"ok": true}` on successful dispatch (or unknown PR — we
      do not leak existence)
    * 401 on missing/bad signature
    * 503 when webhook ingestion is disabled
  """
  def github(conn, _params) do
    cond do
      not enabled?() ->
        conn |> put_status(503) |> json(%{error: "webhook ingestion disabled"})

      not signature_valid?(conn) ->
        Logger.warning("GitHub webhook: signature verification failed")
        conn |> put_status(401) |> json(%{error: "invalid signature"})

      true ->
        event = get_req_header(conn, "x-github-event") |> List.first() || "unknown"
        handle_github_event(event, conn.body_params)
        json(conn, %{ok: true, event: event})
    end
  end

  # -- Event dispatch --------------------------------------------------------

  defp handle_github_event("ping", _payload) do
    Logger.info("GitHub webhook: ping received")
    :ok
  end

  defp handle_github_event("pull_request", %{"pull_request" => %{"html_url" => url}})
       when is_binary(url) do
    case Outcomes.get_by_pr_url(url) do
      nil ->
        Logger.debug("GitHub webhook: PR #{url} not tracked, ignoring")
        :ok

      outcome ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        Outcomes.update(outcome.id, fn o ->
          Map.put(o, :next_poll_at, now)
        end)

        # Force the tracker through a tick so the just-bumped record is
        # picked up immediately rather than at the next 5-min interval.
        if Process.whereis(GiTF.Outcomes.Tracker) do
          GiTF.Outcomes.Tracker.tick()
        end

        Logger.info("GitHub webhook: PR #{url} flagged for immediate poll (outcome=#{outcome.id})")
        :ok
    end
  end

  defp handle_github_event(event, _payload) do
    Logger.debug("GitHub webhook: unhandled event=#{event}")
    :ok
  end

  # -- HMAC-SHA256 signature verification ------------------------------------

  defp signature_valid?(conn) do
    with secret when is_binary(secret) and secret != "" <- webhook_secret(),
         [signature_header] <- get_req_header(conn, "x-hub-signature-256"),
         "sha256=" <> provided <- signature_header,
         body when is_binary(body) <- conn.assigns[:raw_body] do
      expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
      Plug.Crypto.secure_compare(provided, expected)
    else
      _ -> false
    end
  end

  defp webhook_secret do
    Application.get_env(:gitf, :github_webhook_secret) ||
      System.get_env("GITF_GITHUB_WEBHOOK_SECRET")
  end

  defp enabled? do
    Application.get_env(:gitf, :webhooks_enabled, false) == true
  end
end
