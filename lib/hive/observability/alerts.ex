defmodule Hive.Observability.Alerts do
  @moduledoc """
  Alert system for production monitoring.
  Checks conditions and sends notifications.
  """

  require Logger
  alias Hive.Store

  @alert_rules [
    {:quest_stuck, 30 * 60},      # 30 minutes
    {:quality_drop, 70},           # Below 70%
    {:cost_spike, 2.0},            # 2x average
    {:failure_rate_high, 0.3}      # 30%
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

  @doc "Send alert notification"
  def notify(alerts, channel \\ :log) do
    Enum.each(alerts, fn {type, message} ->
      send_notification(channel, type, message)
    end)
  end

  defp check_rule(:quest_stuck, threshold_seconds) do
    quests = Store.all(:quests)
    stuck = Enum.filter(quests, fn q ->
      q.status == "active" && 
      DateTime.diff(DateTime.utc_now(), q.updated_at) > threshold_seconds
    end)
    
    if length(stuck) > 0 do
      {:alert, "#{length(stuck)} quest(s) stuck for > #{threshold_seconds}s"}
    else
      :ok
    end
  end

  defp check_rule(:quality_drop, threshold) do
    jobs = Store.all(:jobs)
    recent = Enum.take(jobs, -10)
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
    costs = Store.all(:costs)
    
    if length(costs) < 10 do
      :ok
    else
      recent = Enum.take(costs, -5) |> Enum.map(& &1.total_cost_usd)
      older = Enum.slice(costs, -15..-6) |> Enum.map(& &1.total_cost_usd)
      
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
    jobs = Store.all(:jobs)
    recent = Enum.take(jobs, -20)
    
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

  defp send_notification(:log, type, message) do
    Logger.warning("[ALERT] #{type}: #{message}")
  end

  defp send_notification(:webhook, type, message) do
    case webhook_url() do
      nil ->
        Logger.debug("No webhook URL configured, skipping alert: #{type}")

      url ->
        payload = %{
          text: "[Hive Alert] #{type}: #{message}",
          type: to_string(type),
          message: message,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        case Req.post(url, json: payload, receive_timeout: 5_000) do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.debug("Webhook alert sent: #{type}")

          {:ok, %{status: status}} ->
            Logger.warning("Webhook returned #{status} for alert: #{type}")

          {:error, reason} ->
            Logger.warning("Webhook failed for alert #{type}: #{inspect(reason)}")
        end
    end
  end

  defp send_notification(channel, type, message) do
    Logger.warning("[#{channel}] #{type}: #{message}")
  end

  defp webhook_url do
    case Hive.Config.Provider.get([:observability, :webhook_url]) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
