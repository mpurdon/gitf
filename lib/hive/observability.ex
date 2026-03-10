defmodule Hive.Observability do
  @moduledoc """
  Supervised GenServer for production monitoring.
  Periodically runs health checks, collects metrics, and fires alerts.
  """

  use GenServer
  require Logger

  alias Hive.Observability.{Metrics, Alerts, Health}

  @default_interval :timer.seconds(60)

  # -- Client API --------------------------------------------------------------

  @doc "Starts the Observability GenServer under supervision."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "No-op for backward compatibility."
  def start_monitoring(_interval_seconds \\ 60), do: {:ok, self()}

  @doc "Get current system status."
  def status do
    %{
      health: Health.check(),
      metrics: Metrics.collect_metrics(),
      alerts: Alerts.check_alerts()
    }
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule_check(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:run_checks, state) do
    run_checks()
    schedule_check(state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private -----------------------------------------------------------------

  defp schedule_check(interval) do
    Process.send_after(self(), :run_checks, interval)
  end

  defp run_checks do
    alerts = Alerts.check_alerts()

    # Check for zombie state (active quests but no progress)
    alerts =
      if Health.alive?() do
        alerts
      else
        Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{type: :zombie_detected})
        [{:zombie_detected, "Hive appears unproductive: active quests but no job activity for 30+ minutes"} | alerts]
      end

    if alerts != [] do
      Alerts.notify(alerts)
    end

    # Run Doctor checks and emit health status (with auto-fix enabled)
    health_results = Hive.Doctor.run_all(fix: true)
    overall_status = 
      if Enum.any?(health_results, &(&1.status == :error)), do: :error, 
      else: (if Enum.any?(health_results, &(&1.status == :warn)), do: :warn, else: :ok)
      
    Hive.Telemetry.emit([:hive, :health, :checked], %{check_count: length(health_results)}, %{
      status: overall_status,
      details: health_results
    })

    Metrics.collect_metrics()
  rescue
    e ->
      Logger.warning("Observability check failed: #{Exception.message(e)}")
  end
end
