defmodule GiTF.Exfil do
  @moduledoc """
  Graceful exfil orchestration for long-running TUI sessions.

  Traps exit signals and performs ordered teardown:
  1. Notify channels ("gitf shutting down")
  2. Drain in-flight links
  3. Save Archive state
  4. Stop ghosts gracefully (SIGTERM to Claude ports, wait timeout)
  5. Stop Major
  6. Close TUI
  7. Exit
  """

  use GenServer

  require Logger
  require GiTF.Ghost.Status, as: GhostStatus

  @default_drain_timeout 5_000

  # -- Public API ------------------------------------------------------------

  @doc "Starts the exfil coordinator."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Initiates graceful exfil."
  @spec initiate() :: :ok
  def initiate do
    GenServer.cast(__MODULE__, :exfil)
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    drain_timeout = Keyword.get(opts, :drain_timeout, @default_drain_timeout)
    {:ok, %{drain_timeout: drain_timeout, shutting_down: false}}
  end

  @impl true
  def handle_cast(:exfil, %{shutting_down: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:exfil, state) do
    do_shutdown(state.drain_timeout)
    {:noreply, %{state | shutting_down: true}}
  end

  @impl true
  def terminate(_reason, state) do
    unless state.shutting_down do
      do_shutdown(state.drain_timeout)
    end

    :ok
  end

  # -- Private ---------------------------------------------------------------

  defp do_shutdown(drain_timeout) do
    # Suppress noisy log output during teardown
    Logger.configure(level: :none)

    # 1. Notify channels
    notify_channels()

    # 2. Mark running ops as stopped (preserves state for resume)
    mark_jobs_stopped()

    # 3. Save backups for active ghosts
    save_active_checkpoints()

    # 4. Flush Archive to ensure all state is persisted before stopping processes
    flush_store()

    # 5. Drain links (wait for in-flight to complete)
    drain_waggles(drain_timeout)

    # 6. Stop ghosts (parallel with per-ghost timeout)
    stop_ghosts(drain_timeout)

    # 7. Stop Major
    stop_major()
  end

  defp notify_channels do
    Phoenix.PubSub.broadcast(GiTF.PubSub, "section:system", {:shutdown, :initiated})
  rescue
    e -> Logger.warning("Exfil: notify_channels failed: #{Exception.message(e)}")
  end

  defp mark_jobs_stopped do
    GiTF.Archive.filter(:ops, fn j -> j.status in ["running", "assigned"] end)
    |> Enum.each(fn op ->
      GiTF.Archive.put(:ops, %{op | status: "pending"})
    end)
  rescue
    e -> Logger.warning("Exfil: mark_jobs_stopped failed: #{Exception.message(e)}")
  end

  defp save_active_checkpoints do
    GiTF.Archive.filter(:ghosts, fn b -> b.status == GhostStatus.working() end)
    |> Enum.each(fn ghost ->
      try do
        GiTF.Transfer.create(ghost.id)
      rescue
        e ->
          Logger.warning(
            "Exfil: checkpoint save failed for ghost #{ghost.id}: #{Exception.message(e)}"
          )
      end
    end)
  rescue
    e -> Logger.warning("Exfil: save_active_checkpoints failed: #{Exception.message(e)}")
  end

  defp drain_waggles(timeout) do
    # Wait for the full drain timeout to allow in-flight links to complete
    Process.sleep(timeout)
  end

  defp stop_ghosts(timeout) do
    case Process.whereis(GiTF.SectorSupervisor) do
      nil ->
        :ok

      _pid ->
        children = DynamicSupervisor.which_children(GiTF.SectorSupervisor)

        # Stop ghosts in parallel with per-ghost timeout to prevent one hung ghost
        # from blocking exfil of all others
        tasks =
          Enum.map(children, fn {_, pid, _, _} ->
            Task.async(fn ->
              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(pid, :shutdown, timeout)
                catch
                  :exit, _ -> Process.exit(pid, :kill)
                end
              end
            end)
          end)

        # Wait for all with a hard ceiling
        Task.yield_many(tasks, timeout + 1_000)
        |> Enum.each(fn {task, result} ->
          if result == nil, do: Task.shutdown(task, :brutal_kill)
        end)
    end
  rescue
    e -> Logger.warning("Exfil: stop_ghosts failed: #{Exception.message(e)}")
  end

  defp flush_store do
    # Force a no-op write cycle to ensure all pending data is on disk
    # This is a read-then-write under the lock, which flushes the cache to disk
    GiTF.Archive.transact(fn data -> data end)
  rescue
    e -> Logger.warning("Exfil: flush_store failed: #{Exception.message(e)}")
  end

  defp stop_major do
    case Process.whereis(GiTF.Major) do
      nil -> :ok
      pid -> GenServer.stop(pid, :shutdown, 5_000)
    end
  rescue
    e -> Logger.warning("Exfil: stop_major failed: #{Exception.message(e)}")
  end
end
