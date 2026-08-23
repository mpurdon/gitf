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

  alias GiTF.GitHub.ReviewIntake
  alias GiTF.Outcomes
  alias GiTF.Sentry.Inbound, as: SentryInbound

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

      not github_signature_valid?(conn) ->
        Logger.warning("GitHub webhook: signature verification failed")
        conn |> put_status(401) |> json(%{error: "invalid signature"})

      true ->
        event = get_req_header(conn, "x-github-event") |> List.first() || "unknown"
        handle_github_event(event, conn.body_params)
        json(conn, %{ok: true, event: event})
    end
  end

  @doc """
  Sentry webhook receiver. Verified payloads are handed to
  `GiTF.Sentry.Inbound.dispatch/1`, which creates or dedupes a mission.

  Returns 200 with `{"ok": true, "result": ...}` on every accepted payload
  (including ignored ones — we do not leak which projects/issues we
  track), 401 on bad signature, 503 when disabled.
  """
  def sentry(conn, _params) do
    cond do
      not enabled?() ->
        conn |> put_status(503) |> json(%{error: "webhook ingestion disabled"})

      not sentry_signature_valid?(conn) ->
        Logger.warning("Sentry webhook: signature verification failed")
        conn |> put_status(401) |> json(%{error: "invalid signature"})

      true ->
        result =
          case SentryInbound.dispatch(conn.body_params) do
            {:ok, :ignored, reason} ->
              reason

            {:ok, kind, _} ->
              kind

            {:error, reason} ->
              Logger.warning("Sentry webhook: dispatch failed: #{inspect(reason)}")
              :error
          end

        json(conn, %{ok: true, result: to_string(result)})
    end
  end

  # -- Event dispatch --------------------------------------------------------

  defp handle_github_event("ping", _payload) do
    Logger.info("GitHub webhook: ping received")
    :ok
  end

  defp handle_github_event("pull_request", %{"pull_request" => %{"html_url" => url}})
       when is_binary(url) do
    bump_outcome_poll(url)
  end

  # A submitted review is the moment an outcome's verdict actually changes —
  # changes_requested, or the approval that precedes a merge. Polling would
  # find it eventually; bumping here means the outcome record reflects the
  # human's decision as soon as they make it.
  defp handle_github_event("pull_request_review", payload) do
    with %{"pull_request" => %{"html_url" => url}} when is_binary(url) <- payload do
      bump_outcome_poll(url)
    end

    case ReviewIntake.dispatch(payload) do
      {:ok, :mission_created, mission} ->
        Logger.info("GitHub webhook: review → follow-up mission #{mission.id}")

      {:ok, :ignored, reason} ->
        Logger.debug("GitHub webhook: review not ingested (#{reason})")

      {:error, reason} ->
        Logger.warning("GitHub webhook: review intake failed: #{inspect(reason)}")
    end

    :ok
  end

  # Inline comments arrive one event per comment and carry no verdict of
  # their own, so they refresh the outcome but never spawn work — the
  # enclosing review is the unit of intent.
  defp handle_github_event("pull_request_review_comment", %{
         "pull_request" => %{"html_url" => url}
       })
       when is_binary(url) do
    bump_outcome_poll(url)
  end

  defp handle_github_event("issues", payload) do
    # Aramaki (admission layer) is opt-in; only route issue events when on.
    if GiTF.Aramaki.enabled?() do
      case GiTF.Aramaki.Intake.dispatch(payload) do
        {:ok, kind, _} -> Logger.info("GitHub webhook: issue → #{kind}")
        {:error, reason} -> Logger.warning("GitHub webhook: issue intake failed: #{inspect(reason)}")
      end
    else
      Logger.debug("GitHub webhook: issues event ignored (Aramaki disabled)")
    end

    :ok
  end

  defp handle_github_event(event, _payload) do
    Logger.debug("GitHub webhook: unhandled event=#{event}")
    :ok
  end

  # An untracked PR is silently ignored: the factory does not confirm which
  # pull requests it watches.
  defp bump_outcome_poll(url) do
    case Outcomes.get_by_pr_url(url) do
      nil ->
        Logger.debug("GitHub webhook: PR #{url} not tracked, ignoring")
        :ok

      outcome ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        Outcomes.update(outcome.id, &Map.put(&1, :next_poll_at, now))

        # Force the tracker through a tick so the just-bumped record is
        # picked up immediately rather than at the next 5-min interval.
        if Process.whereis(GiTF.Outcomes.Tracker) do
          GiTF.Outcomes.Tracker.tick()
        end

        Logger.info("GitHub webhook: PR #{url} flagged for immediate poll (outcome=#{outcome.id})")
        :ok
    end
  end

  # -- HMAC-SHA256 signature verification ------------------------------------

  # GitHub: `X-Hub-Signature-256: sha256=<hex>` over the raw body.
  defp github_signature_valid?(conn) do
    GiTF.Web.Signature.verify(
      github_secret(),
      get_req_header(conn, "x-hub-signature-256") |> List.first(),
      conn.assigns[:raw_body]
    )
  end

  # Sentry: `Sentry-Hook-Signature: <hex>` (no `sha256=` prefix) over
  # the raw body using the integration's client secret.
  defp sentry_signature_valid?(conn) do
    GiTF.Web.Signature.verify(
      sentry_secret(),
      get_req_header(conn, "sentry-hook-signature") |> List.first(),
      conn.assigns[:raw_body]
    )
  end

  defp github_secret do
    Application.get_env(:gitf, :github_webhook_secret) ||
      System.get_env("GITF_GITHUB_WEBHOOK_SECRET")
  end

  defp sentry_secret do
    Application.get_env(:gitf, :sentry_webhook_secret) ||
      System.get_env("GITF_SENTRY_WEBHOOK_SECRET")
  end

  defp enabled? do
    Application.get_env(:gitf, :webhooks_enabled, false) == true
  end
end
