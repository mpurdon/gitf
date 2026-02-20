defmodule Hive.Observability.Metrics do
  @moduledoc """
  Metrics collection with ETS-backed ring buffer for time-series data.

  Stores the last `@max_points` data points per metric, enabling trend
  detection (e.g., cost_trend in Autonomy). Point-in-time collection is
  still available via `collect_metrics/0`.
  """

  alias Hive.Store

  @table :hive_metrics_ring
  @max_points 1000

  # -- Init ------------------------------------------------------------------

  @doc "Initialize the ETS ring buffer. Call once at application startup."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:named_table, :public, :ordered_set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # -- Ring buffer API -------------------------------------------------------

  @doc "Record a metric data point with the current timestamp."
  @spec record(atom(), number()) :: :ok
  def record(metric, value) when is_atom(metric) and is_number(value) do
    ts = System.monotonic_time(:millisecond)
    key = {metric, ts}
    :ets.insert(@table, {key, value})
    maybe_evict(metric)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the last N data points for a metric (default: all)."
  @spec series(atom(), pos_integer()) :: [{integer(), number()}]
  def series(metric, limit \\ @max_points) do
    # Match all entries for this metric
    match_spec = [{{{metric, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]

    :ets.select(@table, match_spec)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(-limit)
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the trend as a ratio of recent average to older average.

  A value > 1.0 means the metric is increasing, < 1.0 means decreasing.
  Returns 1.0 if insufficient data.
  """
  @spec trend(atom()) :: float()
  def trend(metric) do
    points = series(metric) |> Enum.map(&elem(&1, 1))

    if length(points) < 10 do
      1.0
    else
      midpoint = div(length(points), 2)
      {older, recent} = Enum.split(points, midpoint)

      older_avg = Enum.sum(older) / length(older)
      recent_avg = Enum.sum(recent) / length(recent)

      if older_avg == 0, do: 1.0, else: recent_avg / older_avg
    end
  end

  # -- Telemetry handlers ----------------------------------------------------

  @doc "Attach telemetry handlers to auto-record metrics."
  @spec attach_handlers() :: :ok
  def attach_handlers do
    events = [
      [:hive, :bee, :spawned],
      [:hive, :bee, :completed],
      [:hive, :bee, :failed],
      [:hive, :job, :completed],
      [:hive, :token, :consumed]
    ]

    :telemetry.attach_many("hive-metrics-ring", events, &__MODULE__.handle_telemetry/4, %{})
    :ok
  end

  @doc false
  def handle_telemetry([:hive, :bee, :spawned], _measurements, _meta, _config) do
    record(:bees_spawned, 1)
  end

  def handle_telemetry([:hive, :bee, :completed], %{duration_ms: ms}, _meta, _config) do
    record(:bee_duration_ms, ms)
  end

  def handle_telemetry([:hive, :bee, :failed], _measurements, _meta, _config) do
    record(:bees_failed, 1)
  end

  def handle_telemetry([:hive, :job, :completed], _measurements, _meta, _config) do
    record(:jobs_completed, 1)
  end

  def handle_telemetry([:hive, :token, :consumed], %{cost: cost}, _meta, _config)
      when is_number(cost) do
    record(:cost_usd, cost)
  end

  def handle_telemetry(_event, _measurements, _meta, _config), do: :ok

  # -- Point-in-time collection (legacy API) ---------------------------------

  @doc "Collect all system metrics"
  def collect_metrics do
    %{
      system: system_metrics(),
      quests: quest_metrics(),
      bees: bee_metrics(),
      quality: quality_metrics(),
      costs: cost_metrics()
    }
  end

  @doc "Export metrics in Prometheus format"
  def export_prometheus do
    metrics = collect_metrics()

    [
      "hive_quests_total #{metrics.quests.total}",
      "hive_quests_active #{metrics.quests.active}",
      "hive_quests_completed #{metrics.quests.completed}",
      "hive_quests_failed #{metrics.quests.failed}",
      "hive_bees_active #{metrics.bees.active}",
      "hive_bees_idle #{metrics.bees.idle}",
      "hive_quality_score_avg #{metrics.quality.average}",
      "hive_cost_total_usd #{metrics.costs.total}",
      "hive_cost_trend #{trend(:cost_usd)}"
    ]
    |> Enum.join("\n")
  end

  # -- Private ---------------------------------------------------------------

  defp maybe_evict(metric) do
    match_spec = [{{{metric, :_}, :_}, [], [true]}]
    count = :ets.select_count(@table, match_spec)

    if count > @max_points do
      # Delete oldest entries
      to_delete = count - @max_points
      keys = :ets.select(@table, [{{{metric, :"$1"}, :_}, [], [{{metric, :"$1"}}]}])
      keys |> Enum.sort() |> Enum.take(to_delete) |> Enum.each(&:ets.delete(@table, &1))
    end
  rescue
    ArgumentError -> :ok
  end

  defp system_metrics do
    %{
      uptime: System.monotonic_time(:second),
      memory_mb: :erlang.memory(:total) / 1_024 / 1_024,
      process_count: :erlang.system_info(:process_count)
    }
  end

  defp quest_metrics do
    quests = Store.all(:quests)

    %{
      total: length(quests),
      active: Enum.count(quests, &(&1.status == "active")),
      completed: Enum.count(quests, &(&1.status == "completed")),
      failed: Enum.count(quests, &(&1.status == "failed"))
    }
  end

  defp bee_metrics do
    bees = Store.all(:bees)

    %{
      total: length(bees),
      active: Enum.count(bees, &(&1.status == "active")),
      idle: Enum.count(bees, &(&1.status == "idle"))
    }
  end

  defp quality_metrics do
    jobs = Store.all(:jobs)
    scores = Enum.map(jobs, & &1[:quality_score]) |> Enum.reject(&is_nil/1)

    %{
      average: if(Enum.empty?(scores), do: 0, else: Enum.sum(scores) / length(scores)),
      count: length(scores)
    }
  end

  defp cost_metrics do
    costs = Store.all(:costs)

    %{
      total: Enum.sum(Enum.map(costs, & &1.total_cost_usd)),
      count: length(costs)
    }
  end
end
