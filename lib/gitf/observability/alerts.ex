defmodule GiTF.Observability.Alerts do
  @moduledoc """
  Alert system for production monitoring.
  Checks conditions and sends notifications.
  """

  require Logger
  alias GiTF.Archive

  @alert_rules [
    {:quest_stuck, 30 * 60},      # 30 minutes
    {:quality_drop, 70},          # Below 70%
    {:cost_spike, 2.0},           # 2x average
    {:failure_rate_high, 0.3},    # 30%
    {:validation_failed, 5 * 60}  # Failed in last 5 mins
  ]

  @doc "Check all alert rules and return triggered alerts"
  def check_alerts do
    Enum.flat_map(@alert_rules, fn {rule, threshold} ->
      case check_rule(rule, threshold) do
        {:alert, message} -> [{rule, message}]
        :ok -> []
      end
    end)
  end

  @doc "Send alert notification. Dispatches to both log and webhook when a webhook_url is configured."
  def notify(alerts, channel \\ :auto) do
    Enum.each(alerts, fn {type, message} ->
      GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{type: type, message: message})

      case channel do
        :auto ->
          # Log directly; webhook is handled by the telemetry handler
          # attached in attach_webhook_handler/0 (fired by the emit above)
          send_notification(:log, type, message)

        other ->
          send_notification(other, type, message)
      end
    end)
  end

  @doc "Dispatch a single alert directly to the configured webhook (and log)."
  @spec dispatch_webhook(atom(), String.t()) :: :ok
  def dispatch_webhook(type, message) do
    Logger.warning("[ALERT] #{type}: #{message}")

    case webhook_url() do
      nil -> :ok
      _url ->
        # Fire-and-forget: avoid blocking the caller during retries
        Task.start(fn -> send_notification(:webhook, type, message) end)
    end

    :ok
  end

  @doc "Attach a telemetry handler that forwards [:gitf, :alert, :raised] events to the webhook."
  def attach_webhook_handler do
    :telemetry.attach(
      "gitf-alert-webhook",
      [:gitf, :alert, :raised],
      &__MODULE__.handle_alert_event/4,
      nil
    )
  rescue
    # Handler already attached or telemetry not available
    _ -> :ok
  end

  @doc false
  def handle_alert_event(_event, _measurements, metadata, _config) do
    type = Map.get(metadata, :type, :unknown)
    message = Map.get(metadata, :message, "")

    if webhook_url() do
      # Fire-and-forget: telemetry handlers run in the caller's process
      Task.start(fn -> send_notification(:webhook, type, message) end)
    end
  rescue
    _ -> :ok
  end

  defp check_rule(:validation_failed, threshold_seconds) do
    ops = Archive.all(:ops)
    recent_failures = Enum.filter(ops, fn j ->
      j.status == "done" &&
      Map.get(j, :verification_status) == "failed" &&
      j.verified_at &&
      DateTime.diff(DateTime.utc_now(), j.verified_at) < threshold_seconds
    end)

    if length(recent_failures) > 0 do
      msg = Enum.map(recent_failures, &"Job #{&1.id} failed validation") |> Enum.join(", ")
      {:alert, msg}
    else
      :ok
    end
  end

  defp check_rule(:quest_stuck, threshold_seconds) do
    missions = Archive.all(:missions)
    stuck = Enum.filter(missions, fn q ->
      q.status == "active" && 
      DateTime.diff(DateTime.utc_now(), q.updated_at) > threshold_seconds
    end)
    
    if length(stuck) > 0 do
      {:alert, "#{length(stuck)} mission(s) stuck for > #{threshold_seconds}s"}
    else
      :ok
    end
  end

  defp check_rule(:quality_drop, threshold) do
    ops = Archive.all(:ops)
    recent = Enum.take(ops, -10)
    scores = Enum.map(recent, & &1[:quality_score]) |> Enum.reject(&is_nil/1)
    
    if !Enum.empty?(scores) do
      avg = Enum.sum(scores) / length(scores)
      if avg < threshold do
        {:alert, "Quality score dropped to #{Float.round(avg, 1)}"}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp check_rule(:cost_spike, multiplier) do
    costs = Archive.all(:costs)
    
    if length(costs) < 10 do
      :ok
    else
      recent = Enum.take(costs, -5) |> Enum.map(& (&1[:total_cost_usd] || &1[:cost_usd] || 0))
      older = Enum.slice(costs, -15..-6) |> Enum.map(& (&1[:total_cost_usd] || &1[:cost_usd] || 0))
      
      recent_avg = Enum.sum(recent) / length(recent)
      older_avg = Enum.sum(older) / length(older)
      
      if recent_avg > older_avg * multiplier do
        {:alert, "Cost spike: $#{Float.round(recent_avg, 2)} vs $#{Float.round(older_avg, 2)}"}
      else
        :ok
      end
    end
  end

  defp check_rule(:failure_rate_high, threshold) do
    ops = Archive.all(:ops)
    recent = Enum.take(ops, -20)
    
    if length(recent) > 0 do
      failed = Enum.count(recent, & &1.status == "failed")
      rate = failed / length(recent)
      
      if rate > threshold do
        {:alert, "Failure rate: #{Float.round(rate * 100, 1)}%"}
      else
        :ok
      end
    else
      :ok
    end
  end

  @webhook_max_retries 3

  defp send_notification(:log, type, message) do
    Logger.warning("[ALERT] #{type}: #{message}")
  end

  defp send_notification(:webhook, type, message) do
    case webhook_url() do
      nil ->
        Logger.debug("No webhook URL configured, skipping alert: #{type}")

      url ->
        payload = %{
          text: "[GiTF Alert] #{type}: #{message}",
          type: to_string(type),
          message: message,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        send_webhook_with_retry(url, payload, type, 0)
    end
  end

  defp send_notification(channel, type, message) do
    Logger.warning("[#{channel}] #{type}: #{message}")
  end

  defp send_webhook_with_retry(_url, _payload, type, attempt) when attempt >= @webhook_max_retries do
    Logger.warning("Webhook exhausted #{@webhook_max_retries} retries for alert: #{type}")
  end

  defp send_webhook_with_retry(url, payload, type, attempt) do
    case Req.post(url, json: payload, receive_timeout: 5_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.debug("Webhook alert sent: #{type}")

      {:ok, %{status: status}} when status in [429, 500, 502, 503, 504] ->
        delay = min(:timer.seconds(2) * Integer.pow(2, attempt), :timer.seconds(30))
        Logger.warning("Webhook returned #{status} for alert #{type}, retrying in #{div(delay, 1000)}s (attempt #{attempt + 1}/#{@webhook_max_retries})")
        Process.sleep(delay)
        send_webhook_with_retry(url, payload, type, attempt + 1)

      {:ok, %{status: status}} ->
        Logger.warning("Webhook returned #{status} for alert: #{type}")

      {:error, reason} ->
        delay = min(:timer.seconds(1) * Integer.pow(2, attempt), :timer.seconds(15))
        Logger.warning("Webhook failed for alert #{type}: #{inspect(reason)}, retrying in #{div(delay, 1000)}s (attempt #{attempt + 1}/#{@webhook_max_retries})")
        Process.sleep(delay)
        send_webhook_with_retry(url, payload, type, attempt + 1)
    end
  rescue
    _ ->
      Logger.warning("Webhook crashed for alert #{type} (attempt #{attempt + 1})")
  end

  defp webhook_url do
    case GiTF.Config.Provider.get([:observability, :webhook_url]) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
