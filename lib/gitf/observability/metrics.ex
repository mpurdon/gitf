defmodule GiTF.Observability.Metrics do
  @moduledoc """
  Metrics collection with ETS-backed ring buffer for time-series data.

  Stores the last `@max_points` data points per metric, enabling trend
  detection (e.g., cost_trend in Autonomy). Point-in-time collection is
  still available via `collect_metrics/0`.
  """

  alias GiTF.Archive
  require GiTF.Ghost.Status, as: GhostStatus

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

  @doc "Returns uptime in seconds since server boot."
  @spec uptime_seconds() :: non_neg_integer()
  def uptime_seconds do
    System.system_time(:second) - :persistent_term.get(:gitf_boot_time)
  rescue
    _ -> :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
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
      [:gitf, :op, :completed],
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

  def handle_telemetry([:gitf, :op, :completed], _measurements, _meta, _config) do
    record(:jobs_completed, 1)
  end

  def handle_telemetry([:gitf, :token, :consumed], %{cost: cost}, _meta, _config)
      when is_number(cost) do
    record(:cost_usd, cost)
  end

  def handle_telemetry(_event, _measurements, _meta, _config), do: :ok

  # -- Point-in-time collection (legacy API) ---------------------------------

  @doc """
  Collect all system metrics (single pass per collection).

  Accepts optional pre-fetched data to avoid redundant Archive reads
  when the caller already has the collections loaded.
  """
  def collect_metrics(opts \\ []) do
    ghosts = opts[:ghosts] || Archive.all(:ghosts)
    ops = opts[:ops] || Archive.all(:ops)
    missions = opts[:missions] || Archive.all(:missions)
    costs = opts[:costs] || Archive.all(:costs)

    ghost_counts = tally_statuses(ghosts)
    op_counts = tally_statuses(ops)
    mission_counts = tally_statuses(missions)

    active_ghosts =
      Map.get(ghost_counts, GhostStatus.working(), 0) +
        Map.get(ghost_counts, GhostStatus.starting(), 0)

    scores = Enum.map(ops, & &1[:quality_score]) |> Enum.reject(&is_nil/1)

    %{
      system: %{
        uptime: uptime_seconds(),
        memory_bytes: :erlang.memory(:total),
        memory_mb: :erlang.memory(:total) / 1_024 / 1_024,
        worker_count: active_ghosts
      },
      missions: %{
        total: length(missions),
        active: Map.get(mission_counts, "active", 0) + Map.get(mission_counts, "pending", 0),
        completed: Map.get(mission_counts, "completed", 0),
        failed: Map.get(mission_counts, "failed", 0)
      },
      ops: %{
        total: length(ops),
        pending: Map.get(op_counts, "pending", 0),
        running: Map.get(op_counts, "running", 0),
        done: Map.get(op_counts, "done", 0),
        failed: Map.get(op_counts, "failed", 0)
      },
      ghosts: %{
        total: length(ghosts),
        active: active_ghosts,
        idle: Map.get(ghost_counts, GhostStatus.idle(), 0),
        stopped:
          Map.get(ghost_counts, GhostStatus.stopped(), 0) +
            Map.get(ghost_counts, GhostStatus.crashed(), 0)
      },
      quality: %{
        average: if(scores == [], do: 0, else: Enum.sum(scores) / length(scores)),
        count: length(scores)
      },
      costs: %{
        total: Enum.sum(Enum.map(costs, &Map.get(&1, :cost_usd, 0.0))),
        count: length(costs)
      }
    }
  end

  @doc "Export metrics in Prometheus exposition format"
  def export_prometheus do
    metrics = collect_metrics()

    lines = [
      "# HELP gitf_uptime_seconds Seconds since server boot",
      "# TYPE gitf_uptime_seconds gauge",
      "gitf_uptime_seconds #{metrics.system.uptime}",
      "",
      "# HELP gitf_missions_total Total number of missions",
      "# TYPE gitf_missions_total gauge",
      "gitf_missions_total #{metrics.missions.total}",
      "# HELP gitf_missions_active Currently active missions",
      "# TYPE gitf_missions_active gauge",
      "gitf_missions_active #{metrics.missions.active}",
      "# HELP gitf_missions_completed Completed missions",
      "# TYPE gitf_missions_completed counter",
      "gitf_missions_completed #{metrics.missions.completed}",
      "# HELP gitf_missions_failed Failed missions",
      "# TYPE gitf_missions_failed counter",
      "gitf_missions_failed #{metrics.missions.failed}",
      "",
      "# HELP gitf_ops_total Total operations",
      "# TYPE gitf_ops_total gauge",
      "gitf_ops_total #{metrics.ops.total}",
      "# HELP gitf_ops_pending Pending operations",
      "# TYPE gitf_ops_pending gauge",
      "gitf_ops_pending #{metrics.ops.pending}",
      "# HELP gitf_ops_running Running operations",
      "# TYPE gitf_ops_running gauge",
      "gitf_ops_running #{metrics.ops.running}",
      "# HELP gitf_ops_done Completed operations",
      "# TYPE gitf_ops_done counter",
      "gitf_ops_done #{metrics.ops.done}",
      "# HELP gitf_ops_failed Failed operations",
      "# TYPE gitf_ops_failed counter",
      "gitf_ops_failed #{metrics.ops.failed}",
      "",
      "# HELP gitf_ghosts_active Active ghost workers",
      "# TYPE gitf_ghosts_active gauge",
      "gitf_ghosts_active #{metrics.ghosts.active}",
      "# HELP gitf_ghosts_total Total ghosts spawned",
      "# TYPE gitf_ghosts_total gauge",
      "gitf_ghosts_total #{metrics.ghosts.total}",
      "",
      "# HELP gitf_cost_total_usd Total LLM cost in USD",
      "# TYPE gitf_cost_total_usd counter",
      "gitf_cost_total_usd #{metrics.costs.total}",
      "# HELP gitf_cost_trend Cost trend ratio (>1 = increasing)",
      "# TYPE gitf_cost_trend gauge",
      "gitf_cost_trend #{trend(:cost_usd)}",
      "",
      "# HELP gitf_quality_score_avg Average quality score",
      "# TYPE gitf_quality_score_avg gauge",
      "gitf_quality_score_avg #{metrics.quality.average}",
      "",
      "# HELP gitf_memory_bytes BEAM VM memory usage",
      "# TYPE gitf_memory_bytes gauge",
      "gitf_memory_bytes #{metrics.system.memory_bytes}",
      "# HELP gitf_process_count BEAM process count",
      "# TYPE gitf_process_count gauge",
      "gitf_process_count #{:erlang.system_info(:process_count)}"
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  # -- Private ---------------------------------------------------------------

  defp tally_statuses(records) do
    Enum.frequencies_by(records, &Map.get(&1, :status, "unknown"))
  end

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
end
