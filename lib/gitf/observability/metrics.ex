defmodule GiTF.Observability.Metrics do
  @moduledoc """
  Metrics collection with ETS-backed ring buffer for time-series data.

  Stores the last `@max_points` data points per metric, enabling trend
  detection (e.g., cost_trend in Autonomy). Point-in-time collection is
  still available via `collect_metrics/0`.
  """

  alias GiTF.Store

  @table :gitf_metrics_ring
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
      [:gitf, :ghost, :spawned],
      [:gitf, :ghost, :completed],
      [:gitf, :ghost, :failed],
      [:gitf, :job, :completed],
      [:gitf, :token, :consumed]
    ]

    :telemetry.attach_many("section-metrics-ring", events, &__MODULE__.handle_telemetry/4, %{})
    :ok
  end

  @doc false
  def handle_telemetry([:gitf, :ghost, :spawned], _measurements, _meta, _config) do
    record(:bees_spawned, 1)
  end

  def handle_telemetry([:gitf, :ghost, :completed], %{duration_ms: ms}, _meta, _config) do
    record(:bee_duration_ms, ms)
  end

  def handle_telemetry([:gitf, :ghost, :failed], _measurements, _meta, _config) do
    record(:bees_failed, 1)
  end

  def handle_telemetry([:gitf, :job, :completed], _measurements, _meta, _config) do
    record(:jobs_completed, 1)
  end

  def handle_telemetry([:gitf, :token, :consumed], %{cost: cost}, _meta, _config)
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
      jobs: job_metrics(),
      ghosts: bee_metrics(),
      quality: quality_metrics(),
      costs: cost_metrics()
    }
  end

  @doc "Export metrics in Prometheus format"
  def export_prometheus do
    metrics = collect_metrics()

    [
      "gitf_quests_total #{metrics.quests.total}",
      "gitf_quests_active #{metrics.quests.active}",
      "gitf_quests_completed #{metrics.quests.completed}",
      "gitf_quests_failed #{metrics.quests.failed}",
      "gitf_bees_active #{metrics.ghosts.active}",
      "gitf_bees_idle #{metrics.ghosts.idle}",
      "gitf_quality_score_avg #{metrics.quality.average}",
      "gitf_cost_total_usd #{metrics.costs.total}",
      "gitf_cost_trend #{trend(:cost_usd)}"
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
    ghosts = Store.all(:ghosts)
    workers = Enum.count(ghosts, &(Map.get(&1, :status) in ["working", "starting"]))

    %{
      uptime: System.monotonic_time(:second),
      memory_mb: :erlang.memory(:total) / 1_024 / 1_024,
      worker_count: workers
    }
  end

  defp quest_metrics do
    quests = Store.all(:quests)

    %{
      total: length(quests),
      active: Enum.count(quests, &(Map.get(&1, :status) in ["active", "pending"])),
      completed: Enum.count(quests, &(Map.get(&1, :status) == "completed")),
      failed: Enum.count(quests, &(Map.get(&1, :status) == "failed"))
    }
  end

  defp job_metrics do
    jobs = Store.all(:jobs)

    %{
      total: length(jobs),
      pending: Enum.count(jobs, &(Map.get(&1, :status) == "pending")),
      running: Enum.count(jobs, &(Map.get(&1, :status) == "running")),
      done: Enum.count(jobs, &(Map.get(&1, :status) == "done")),
      failed: Enum.count(jobs, &(Map.get(&1, :status) == "failed"))
    }
  end

  defp bee_metrics do
    ghosts = Store.all(:ghosts)

    %{
      total: length(ghosts),
      active: Enum.count(ghosts, &(Map.get(&1, :status) in ["working", "starting"])),
      idle: Enum.count(ghosts, &(Map.get(&1, :status) == "idle")),
      stopped: Enum.count(ghosts, &(Map.get(&1, :status) in ["stopped", "crashed"]))
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
      total: Enum.sum(Enum.map(costs, &Map.get(&1, :cost_usd, 0.0))),
      count: length(costs)
    }
  end
end
