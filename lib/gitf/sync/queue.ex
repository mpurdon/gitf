defmodule GiTF.Sync.Queue do
  @moduledoc """
  GenServer that serializes sync operations using optimal ordering.

  Subscribes to the `"sync:queue"` PubSub topic. When a op passes
  verification, it is added to a pending list. Jobs are dequeued one at
  a time, merged in optimal order (via `GiTF.Sync.Strategy`), and the
  result is reported back to the Major via link_msg.

  ## State

      %{
        pending: [{op_id, shell_id}],
        active: {op_id, shell_id, task_ref} | nil,
        completed: [{op_id, outcome, DateTime.t()}]
      }

  ## Registration

  Registered in `GiTF.Registry` under `:sync_queue`.
  At most one SyncQueue process per section.
  """

  use GenServer
  require Logger

  @registry GiTF.Registry
  @registry_key :sync_queue
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

  @doc "Starts the SyncQueue GenServer."
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

  @doc "Looks up the SyncQueue process via the Registry."
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
    Phoenix.PubSub.subscribe(GiTF.PubSub, "sync:queue")

    state = %{
      pending: [],
      active: nil,
      completed: [],
      merge_timer: nil
    }

    # Recovery: check for verified-but-unmerged ops on startup and periodically
    Process.send_after(self(), :recover_pending, 5_000)
    Process.send_after(self(), :periodic_recovery, :timer.minutes(5))

    Logger.info("SyncQueue started")
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    active_info =
      case state.active do
        {op_id, shell_id, _ref} -> %{op_id: op_id, shell_id: shell_id}
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
  def handle_info({:merge_ready, op_id, shell_id}, state) do
    Logger.info("SyncQueue received sync-ready op #{op_id}")

    # Deduplicate: don't add if already pending or active
    already_queued =
      Enum.any?(state.pending, fn {jid, _} -> jid == op_id end) or
        match?({^op_id, _, _}, state.active)

    if already_queued do
      Logger.debug("Job #{op_id} already in sync queue, skipping")
      {:noreply, state}
    else
      state = %{state | pending: state.pending ++ [{op_id, shell_id}]}
      state = maybe_process_next(state)
      {:noreply, state}
    end
  end

  # Handle Task completion for the active sync
  def handle_info({ref, {:merge_result, op_id, result}}, %{active: {_, _, ref}} = state) do
    Process.demonitor(ref, [:flush])
    if state.merge_timer, do: Process.cancel_timer(state.merge_timer)
    state = handle_merge_result(op_id, result, state)
    state = %{state | active: nil, merge_timer: nil}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  # Task completed but ref doesn't match active — stale result
  def handle_info({ref, {:merge_result, _op_id, _result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active: {op_id, _, ref}} = state) do
    Logger.error("Sync task crashed for op #{op_id}: #{inspect(reason)}")
    if state.merge_timer, do: Process.cancel_timer(state.merge_timer)

    GiTF.Link.send("sync_queue", "major", "merge_failed",
      "Sync task crashed for op #{op_id}: #{inspect(reason)}")

    GiTF.Telemetry.emit([:gitf, :sync, :crashed], %{}, %{
      op_id: op_id,
      reason: inspect(reason)
    })

    entry = {op_id, :crash, DateTime.utc_now()}
    state = %{state | active: nil, merge_timer: nil, completed: [entry | Enum.take(state.completed, @max_history - 1)]}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  # Sync task timed out — kill it and move on
  def handle_info({:merge_timeout, ref, task_pid}, %{active: {op_id, _, ref}} = state) do
    Logger.error("Sync task timed out for op #{op_id} after #{div(@merge_timeout_ms, 1000)}s")
    Process.demonitor(ref, [:flush])
    Process.exit(task_pid, :kill)

    GiTF.Link.send("sync_queue", "major", "merge_failed",
      "Sync task timed out for op #{op_id}")

    GiTF.Telemetry.emit([:gitf, :sync, :timeout], %{}, %{
      op_id: op_id,
      timeout_seconds: div(@merge_timeout_ms, 1000)
    })

    entry = {op_id, :timeout, DateTime.utc_now()}
    state = %{state | active: nil, merge_timer: nil, completed: [entry | Enum.take(state.completed, @max_history - 1)]}
    state = maybe_process_next(state)
    {:noreply, state}
  end

  # Stale timeout for already-completed sync — ignore
  def handle_info({:merge_timeout, _ref, _pid}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:recover_pending, state) do
    # Find ops that are done + verified but haven't been merged yet
    # This catches ops that were verified while the SyncQueue was down
    recovered =
      GiTF.Archive.filter(:ops, fn j ->
        j.status == "done" and
          Map.get(j, :verification_status) == "passed" and
          Map.get(j, :merged_at) == nil and
          not Map.get(j, :phase_job, false)
      end)
      |> Enum.flat_map(fn op ->
        case GiTF.Archive.find_one(:shells, fn c ->
               c.ghost_id == op.ghost_id and c.status == "active"
             end) do
          nil -> []
          shell -> [{op.id, shell.id}]
        end
      end)

    if recovered != [] do
      Logger.info("SyncQueue recovered #{length(recovered)} pending sync(s)")
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
    ordered = GiTF.Sync.Strategy.optimal_order(pending)

    case ordered do
      [{op_id, shell_id} | rest] ->
        Logger.info("SyncQueue processing op #{op_id}")

        task = Task.async(fn ->
          result = GiTF.Sync.Resolver.resolve(op_id, shell_id)
          {:merge_result, op_id, result}
        end)

        timer = Process.send_after(self(), {:merge_timeout, task.ref, task.pid}, @merge_timeout_ms)
        %{state | active: {op_id, shell_id, task.ref}, pending: rest, merge_timer: timer}

      [] ->
        %{state | pending: []}
    end
  end

  # Active sync in progress — wait
  defp maybe_process_next(state), do: state

  # -- Private: result handling ------------------------------------------------

  defp handle_merge_result(op_id, {:ok, :merged, tier}, state) do
    Logger.info("Job #{op_id} merged successfully at tier #{tier}")

    # Mark the op as merged
    case GiTF.Archive.get(:ops, op_id) do
      nil -> :ok
      op -> GiTF.Archive.put(:ops, Map.put(op, :merged_at, DateTime.utc_now()))
    end

    # Link Major
    GiTF.Link.send("sync_queue", "major", "job_merged",
      "Job #{op_id} merged successfully (tier #{tier})")

    entry = {op_id, :success, DateTime.utc_now()}
    %{state | completed: [entry | Enum.take(state.completed, @max_history - 1)]}
  end

  defp handle_merge_result(op_id, {:error, {:reimagined, new_op_id}, _tier}, state) do
    Logger.info("Job #{op_id} escalated to re-imagine op #{new_op_id}")

    entry = {op_id, {:reimagined, new_op_id}, DateTime.utc_now()}
    %{state | completed: [entry | Enum.take(state.completed, @max_history - 1)]}
  end

  defp handle_merge_result(op_id, {:error, reason, tier}, state) do
    Logger.warning("Job #{op_id} sync failed at tier #{tier}: #{inspect(reason)}")

    GiTF.Link.send("sync_queue", "major", "merge_failed",
      "Job #{op_id} sync failed at tier #{tier}: #{inspect(reason)}")

    entry = {op_id, {:failure, reason}, DateTime.utc_now()}
    %{state | completed: [entry | Enum.take(state.completed, @max_history - 1)]}
  end
end
