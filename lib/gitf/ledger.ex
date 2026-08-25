defmodule GiTF.Ledger do
  @moduledoc """
  Orchestration bookkeeper — tracks mission outcomes by pipeline mode.

  A supervised GenServer that reacts to mission lifecycle events via PubSub
  and maintains running statistics per pipeline mode (fast, full). Rebuilds
  from Archive on init for crash recovery.

  ## Tracked Metrics

    * Missions started/completed/failed per mode
    * Average duration per mode (wall clock)
    * Average cost per mode
    * Rework frequency (fix ops) per mode
    * Phase durations per mode
    * Success rate per mode

  ## Usage

      GiTF.Ledger.stats()           # All stats by mode
      GiTF.Ledger.stats("fast")     # Stats for fast mode only
      GiTF.Ledger.record(mission)   # Manually record a completed mission
  """

  use GenServer
  require Logger

  alias GiTF.Archive

  @name __MODULE__

  # -- Client API --------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Returns aggregated stats for all modes or a specific mode."
  @spec stats(String.t() | nil) :: map()
  def stats(mode \\ nil) do
    GenServer.call(@name, {:stats, mode})
  catch
    :exit, _ -> %{}
  end

  @doc "Returns the raw ledger entries (list of mission outcome records)."
  @spec entries() :: list()
  def entries do
    GenServer.call(@name, :entries)
  catch
    :exit, _ -> []
  end

  @doc "Manually record a mission outcome (used by orchestrator on completion)."
  @spec record(map()) :: :ok
  def record(mission) do
    GenServer.cast(@name, {:record, mission})
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    # Subscribe to monitor events for real-time tracking
    Phoenix.PubSub.subscribe(GiTF.PubSub, "section:monitor")
    Phoenix.PubSub.subscribe(GiTF.PubSub, "section:costs")

    # Rebuild ledger from Archive (crash recovery)
    entries = rebuild_from_archive()
    Logger.info("Ledger started with #{length(entries)} historical entries")

    {:ok, %{entries: entries}}
  end

  @impl true
  def handle_call({:stats, nil}, _from, state) do
    {:reply, compute_all_stats(state.entries), state}
  end

  def handle_call({:stats, mode}, _from, state) do
    filtered = Enum.filter(state.entries, &(&1.mode == mode))
    {:reply, compute_mode_stats(mode, filtered), state}
  end

  def handle_call(:entries, _from, state) do
    {:reply, state.entries, state}
  end

  @impl true
  def handle_cast({:record, mission}, state) do
    case build_entry(mission) do
      nil ->
        {:noreply, state}

      entry ->
        # Deduplicate by mission_id
        entries = reject_duplicate(state.entries, entry.mission_id)
        {:noreply, %{state | entries: [entry | entries]}}
    end
  end

  # React to mission completion/failure events via PubSub bridge
  @impl true
  def handle_info({:gitf_event, %{event: "gitf.mission.completed", metadata: meta}}, state) do
    case load_and_record(meta[:mission_id], state) do
      {:ok, new_state} -> {:noreply, new_state}
      :skip -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private: entry building -------------------------------------------------

  defp build_entry(mission) do
    ops = mission[:ops] || []
    impl_ops = Enum.reject(ops, & &1[:phase_job])
    fix_ops = Enum.filter(impl_ops, &is_binary(&1[:fix_of]))

    # Compute duration from mission timestamps
    started = mission[:inserted_at]
    finished = mission[:updated_at] || DateTime.utc_now()

    duration_seconds =
      if started && finished do
        DateTime.diff(finished, started, :second)
      else
        0
      end

    # One fetch feeds both the per-phase map and the wall clock.
    transitions = mission_transitions(mission.id)

    # Wall clock = first transition (the start) to last transition (the
    # terminal), on wall-clock inserted_at rather than monotonic seq —
    # monotonic time is not comparable across daemon restarts, and
    # updated_at (the duration_seconds source above) moves every time
    # anything writes to a finished mission. Queue wait is created→started,
    # kept separate: a mission that sat pending for a day did not RUN for
    # a day, and a serverless-provider comparison cares about execution.
    {wall_clock_seconds, queue_wait_seconds} =
      case transitions do
        [first | _] = list ->
          last = List.last(list)

          wall =
            with %DateTime{} = a <- first[:inserted_at],
                 %DateTime{} = b <- last[:inserted_at] do
              max(DateTime.diff(b, a, :second), 0)
            else
              _ -> nil
            end

          wait =
            with %DateTime{} = created <- started,
                 %DateTime{} = began <- first[:inserted_at] do
              max(DateTime.diff(began, created, :second), 0)
            else
              _ -> nil
            end

          {wall, wait}

        [] ->
          {nil, nil}
      end

    # Compute cost from Archive
    all_costs = Archive.all(:costs)
    mission_costs = Enum.filter(all_costs, &(&1[:mission_id] == mission.id))
    total_cost = mission_costs |> Enum.map(&(&1[:cost_usd] || 0.0)) |> Enum.sum()

    rework_cost =
      mission_costs
      |> Enum.filter(&(&1[:phase_type] == "rework"))
      |> Enum.map(&(&1[:cost_usd] || 0.0))
      |> Enum.sum()

    # Compute files changed
    total_files = impl_ops |> Enum.map(&(&1[:files_changed] || 0)) |> Enum.sum()

    # Phase durations from transitions
    phase_durations = compute_phase_durations(transitions)

    outcome = if mission.status == "completed", do: :completed, else: :failed

    %{
      mission_id: mission.id,
      name: mission[:name],
      mode: mission[:pipeline_mode] || "full",
      outcome: outcome,
      duration_seconds: duration_seconds,
      wall_clock_seconds: wall_clock_seconds,
      queue_wait_seconds: queue_wait_seconds,
      total_cost: total_cost,
      rework_cost: rework_cost,
      total_ops: length(impl_ops),
      fix_ops: length(fix_ops),
      files_changed: total_files,
      phase_durations: phase_durations,
      completed_at: finished
    }
  rescue
    e ->
      Logger.warning(
        "Ledger: failed to build entry for #{inspect(mission[:id])}: #{Exception.message(e)}"
      )

      nil
  end

  defp mission_transitions(mission_id) do
    Archive.filter(:mission_phase_transitions, fn t -> t.mission_id == mission_id end)
    |> Enum.sort_by(& &1[:seq])
  rescue
    _ -> []
  end

  defp compute_phase_durations(transitions) do
    transitions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from_t, to_t] ->
      duration = (to_t[:seq] || 0) - (from_t[:seq] || 0)
      # seq is monotonic microseconds — convert to seconds
      {from_t.to_phase, max(div(duration, 1_000_000), 0)}
    end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp load_and_record(nil, _state), do: :skip

  defp load_and_record(mission_id, state) do
    case GiTF.Missions.get(mission_id) do
      {:ok, mission} when mission.status in ["completed", "failed"] ->
        case build_entry(mission) do
          nil ->
            :skip

          entry ->
            entries = reject_duplicate(state.entries, entry.mission_id)
            {:ok, %{state | entries: [entry | entries]}}
        end

      _ ->
        :skip
    end
  end

  defp reject_duplicate(entries, mission_id) do
    Enum.reject(entries, &(&1.mission_id == mission_id))
  end

  # -- Private: rebuild from Archive -------------------------------------------

  defp rebuild_from_archive do
    GiTF.Missions.list()
    |> Enum.filter(&(&1.status in ["completed", "failed"]))
    |> Enum.map(&build_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
  rescue
    e ->
      Logger.warning("Ledger: rebuild failed: #{Exception.message(e)}")
      []
  end

  # -- Private: stats computation ----------------------------------------------

  defp compute_all_stats(entries) do
    modes = entries |> Enum.map(& &1.mode) |> Enum.uniq()

    by_mode =
      Map.new(modes, fn mode ->
        mode_entries = Enum.filter(entries, &(&1.mode == mode))
        {mode, compute_mode_stats(mode, mode_entries)}
      end)

    %{
      total_missions: length(entries),
      by_mode: by_mode,
      overall: compute_mode_stats("all", entries)
    }
  end

  defp compute_mode_stats(mode, entries) do
    total = length(entries)
    completed = Enum.count(entries, &(&1.outcome == :completed))
    failed = Enum.count(entries, &(&1.outcome == :failed))

    durations = Enum.map(entries, & &1.duration_seconds)
    costs = Enum.map(entries, & &1.total_cost)
    rework_costs = Enum.map(entries, & &1.rework_cost)
    fix_counts = Enum.map(entries, & &1.fix_ops)
    file_counts = Enum.map(entries, & &1.files_changed)

    %{
      mode: mode,
      total: total,
      completed: completed,
      failed: failed,
      success_rate: if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0),
      avg_duration_seconds: safe_avg(durations),
      avg_cost: safe_avg(costs),
      total_cost: Enum.sum(costs),
      avg_rework_cost: safe_avg(rework_costs),
      total_rework_cost: Enum.sum(rework_costs),
      rework_rate: rework_rate(entries),
      avg_fix_ops: safe_avg(fix_counts),
      avg_files_changed: safe_avg(file_counts),
      # Per-phase average durations across all missions in this mode
      avg_phase_durations: avg_phase_durations(entries)
    }
  end

  defp safe_avg([]), do: 0.0
  defp safe_avg(values), do: Float.round(Enum.sum(values) / length(values), 2)

  defp rework_rate(entries) do
    with_rework = Enum.count(entries, &(&1.fix_ops > 0))
    total = length(entries)
    if total > 0, do: Float.round(with_rework / total * 100, 1), else: 0.0
  end

  defp avg_phase_durations(entries) do
    entries
    |> Enum.flat_map(fn e ->
      Enum.map(e.phase_durations, fn {phase, dur} -> {phase, dur} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {phase, durations} ->
      {phase, safe_avg(durations)}
    end)
  end
end
