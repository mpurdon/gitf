defmodule GiTF.Merge.Queue do
  @moduledoc """
  GenServer that serializes merge operations using optimal ordering.

  Subscribes to the `"merge:queue"` PubSub topic. When a job passes
  verification, it is added to a pending list. Jobs are dequeued one at
  a time, merged in optimal order (via `GiTF.Merge.Strategy`), and the
  result is reported back to the Major via waggle.

  ## State

      %{
        pending: [{job_id, cell_id}],
        active: {job_id, cell_id, task_ref} | nil,
        completed: [{job_id, outcome, DateTime.t()}]
      }

  ## Registration

  Registered in `GiTF.Registry` under `:merge_queue`.
  At most one MergeQueue process per section.
  """

  use GenServer
  require Logger

  @registry GiTF.Registry
  @registry_key :merge_queue
  @max_history 100
  @merge_timeout_ms :timer.minutes(5)

  # -- Child spec --------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  # -- Client API --------------------------------------------------------------

  @doc "Starts the MergeQueue GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = {:via, Registry, {@registry, @registry_key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current queue state for inspection."
  @spec status() :: map()
  def status do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, :status)
      :error -> %{pending: [], active: nil, completed: []}
    end
  end

  @doc "Returns the number of pending merges."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    case lookup() do
      {:ok, pid} -> GenServer.call(pid, :pending_count)
      :error -> 0
    end
  end

  @doc "Looks up the MergeQueue process via the Registry."
  @spec lookup() :: {:ok, pid()} | :error
  def lookup do
    case Registry.lookup(@registry, @registry_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- GenServer callbacks -----------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(GiTF.PubSub, "merge:queue")

    state = %{
      pending: [],
      active: nil,
      completed: [],
      merge_timer: nil
    }

    # Recovery: check for verified-but-unmerged jobs on startup and periodically
    Process.send_after(self(), :recover_pending, 5_000)
    Process.send_after(self(), :periodic_recovery, :timer.minutes(5))

    Logger.info("MergeQueue started")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    active_info =
      case state.active do
        {job_id, cell_id, _ref} -> %{job_id: job_id, cell_id: cell_id}
        nil -> nil
      end

    reply = %{
      pending: state.pending,
      active: active_info,
      completed: Enum.take(state.completed, 10)
    }

    {:reply, reply, state}
  end

  def handle_call(:pending_count, _from, state) do
    {:reply, length(state.pending), state}
  end

  @impl true
  def handle_info({:merge_ready, job_id, cell_id}, state) do
    Logger.info("MergeQueue received merge-ready job #{job_id}")

    # Deduplicate: don't add if already pending or active
    already_queued =
      Enum.any?(state.pending, fn {jid, _} -> jid == job_id end) or
        match?({^job_id, _, _}, state.active)

    if already_queued do
      Logger.debug("Job #{job_id} already in merge queue, skipping")
      {:noreply, state}
    else
      state = %{state | pending: state.pending ++ [{job_id, cell_id}]}
      state = maybe_process_next(state)
      {:noreply, state}
    end
  end

  # Handle Task completion for the active merge
  def handle_info({ref, {:merge_result, job_id, result}}, %{active: {_, _, ref}} = state) do
    Process.demonitor(ref, [:flush])
    if state.merge_timer, do: Process.cancel_timer(state.merge_timer)
    state = handle_merge_result(job_id, result, state)
    state = %{state | active: nil, merge_timer: nil}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  # Task completed but ref doesn't match active — stale result
  def handle_info({ref, {:merge_result, _job_id, _result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active: {job_id, _, ref}} = state) do
    Logger.error("Merge task crashed for job #{job_id}: #{inspect(reason)}")
    if state.merge_timer, do: Process.cancel_timer(state.merge_timer)

    GiTF.Waggle.send("merge_queue", "major", "merge_failed",
      "Merge task crashed for job #{job_id}: #{inspect(reason)}")

    GiTF.Telemetry.emit([:gitf, :merge, :crashed], %{}, %{
      job_id: job_id,
      reason: inspect(reason)
    })

    entry = {job_id, :crash, DateTime.utc_now()}
    state = %{state | active: nil, merge_timer: nil, completed: [entry | Enum.take(state.completed, @max_history - 1)]}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  # Merge task timed out — kill it and move on
  def handle_info({:merge_timeout, ref, task_pid}, %{active: {job_id, _, ref}} = state) do
    Logger.error("Merge task timed out for job #{job_id} after #{div(@merge_timeout_ms, 1000)}s")
    Process.demonitor(ref, [:flush])
    Process.exit(task_pid, :kill)

    GiTF.Waggle.send("merge_queue", "major", "merge_failed",
      "Merge task timed out for job #{job_id}")

    GiTF.Telemetry.emit([:gitf, :merge, :timeout], %{}, %{
      job_id: job_id,
      timeout_seconds: div(@merge_timeout_ms, 1000)
    })

    entry = {job_id, :timeout, DateTime.utc_now()}
    state = %{state | active: nil, merge_timer: nil, completed: [entry | Enum.take(state.completed, @max_history - 1)]}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  # Stale timeout for already-completed merge — ignore
  def handle_info({:merge_timeout, _ref, _pid}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:recover_pending, state) do
    # Find jobs that are done + verified but haven't been merged yet
    # This catches jobs that were verified while the MergeQueue was down
    recovered =
      GiTF.Store.filter(:jobs, fn j ->
        j.status == "done" and
          Map.get(j, :verification_status) == "passed" and
          Map.get(j, :merged_at) == nil and
          not Map.get(j, :phase_job, false)
      end)
      |> Enum.flat_map(fn job ->
        case GiTF.Store.find_one(:cells, fn c ->
               c.ghost_id == job.ghost_id and c.status == "active"
             end) do
          nil -> []
          cell -> [{job.id, cell.id}]
        end
      end)

    if recovered != [] do
      Logger.info("MergeQueue recovered #{length(recovered)} pending merge(s)")
    end

    # Add to pending, deduplicating
    existing_ids = Enum.map(state.pending, &elem(&1, 0)) |> MapSet.new()

    new_pending =
      Enum.reject(recovered, fn {jid, _} -> MapSet.member?(existing_ids, jid) end)

    state = %{state | pending: state.pending ++ new_pending}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  def handle_info(:periodic_recovery, state) do
    Process.send_after(self(), :periodic_recovery, :timer.minutes(5))
    send(self(), :recover_pending)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private: queue processing -----------------------------------------------

  defp maybe_process_next(%{active: nil, pending: []} = state), do: state

  defp maybe_process_next(%{active: nil, pending: pending} = state) do
    ordered = GiTF.Merge.Strategy.optimal_order(pending)

    case ordered do
      [{job_id, cell_id} | rest] ->
        Logger.info("MergeQueue processing job #{job_id}")

        task = Task.async(fn ->
          result = GiTF.Merge.Resolver.resolve(job_id, cell_id)
          {:merge_result, job_id, result}
        end)

        timer = Process.send_after(self(), {:merge_timeout, task.ref, task.pid}, @merge_timeout_ms)
        %{state | active: {job_id, cell_id, task.ref}, pending: rest, merge_timer: timer}

      [] ->
        %{state | pending: []}
    end
  end

  # Active merge in progress — wait
  defp maybe_process_next(state), do: state

  # -- Private: result handling ------------------------------------------------

  defp handle_merge_result(job_id, {:ok, :merged, tier}, state) do
    Logger.info("Job #{job_id} merged successfully at tier #{tier}")

    # Mark the job as merged
    case GiTF.Store.get(:jobs, job_id) do
      nil -> :ok
      job -> GiTF.Store.put(:jobs, Map.put(job, :merged_at, DateTime.utc_now()))
    end

    # Waggle Major
    GiTF.Waggle.send("merge_queue", "major", "job_merged",
      "Job #{job_id} merged successfully (tier #{tier})")

    entry = {job_id, :success, DateTime.utc_now()}
    %{state | completed: [entry | Enum.take(state.completed, @max_history - 1)]}
  end

  defp handle_merge_result(job_id, {:error, {:reimagined, new_job_id}, _tier}, state) do
    Logger.info("Job #{job_id} escalated to re-imagine job #{new_job_id}")

    entry = {job_id, {:reimagined, new_job_id}, DateTime.utc_now()}
    %{state | completed: [entry | Enum.take(state.completed, @max_history - 1)]}
  end

  defp handle_merge_result(job_id, {:error, reason, tier}, state) do
    Logger.warning("Job #{job_id} merge failed at tier #{tier}: #{inspect(reason)}")

    GiTF.Waggle.send("merge_queue", "major", "merge_failed",
      "Job #{job_id} merge failed at tier #{tier}: #{inspect(reason)}")

    entry = {job_id, {:failure, reason}, DateTime.utc_now()}
    %{state | completed: [entry | Enum.take(state.completed, @max_history - 1)]}
  end
end
