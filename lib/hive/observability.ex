defmodule Hive.Observability do
  @moduledoc """
  Main observability module for production monitoring.
  Coordinates metrics, alerts, and health checks.
  """

  alias Hive.Observability.{Metrics, Alerts, Health}

  @doc "Start monitoring loop"
  def start_monitoring(interval_seconds \\ 60) do
    Task.start(fn -> monitoring_loop(interval_seconds) end)
  end

  @doc "Get current system status"
  def status do
    %{
      health: Health.check(),
      metrics: Metrics.collect_metrics(),
      alerts: Alerts.check_alerts()
    }
  end

  defp monitoring_loop(interval) do
    # Check alerts
    alerts = Alerts.check_alerts()
    if !Enum.empty?(alerts) do
      Alerts.notify(alerts)
    end
    
    # Sleep and repeat
    Process.sleep(interval * 1000)
    monitoring_loop(interval)
  end
end
