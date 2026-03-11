defmodule GiTF.Test.StoreHelper do
  @moduledoc """
  Helpers for restarting GenServers in tests.

  The application starts GiTF.Archive, GiTF.Major, GiTF.Tachikoma, etc. automatically.
  Tests that need isolated instances must stop the existing ones first.
  """

  @doc """
  Stops any running GiTF.Archive and starts a fresh one with the given data_dir.
  Returns `{:ok, pid}`.
  """
  def restart_store!(data_dir) do
    stop_store()
    GiTF.Archive.start_link(data_dir: data_dir)
  end

  @doc "Stops the currently running GiTF.Archive, if any."
  def stop_store do
    # First try to terminate and remove from the supervisor to prevent auto-restart
    try do
      Supervisor.terminate_child(GiTF.Supervisor, GiTF.Archive)
      Supervisor.delete_child(GiTF.Supervisor, GiTF.Archive)
    catch
      :exit, _ -> :ok
    end

    # Also try direct stop in case it was started outside the supervisor
    safe_stop(GiTF.Archive)

    # Brief pause to ensure the process is fully down
    Process.sleep(10)
  end

  @doc "Stops a named GenServer if it's running. Catches exits gracefully."
  def safe_stop(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> safe_stop_pid(pid)
    end
  end

  def safe_stop(pid) when is_pid(pid) do
    safe_stop_pid(pid)
  end

  @doc """
  Ensures essential infrastructure (PubSub, Registry) is running.
  Call this in test setup if tests may have crashed these processes.
  """
  def ensure_infrastructure do
    # Ensure PubSub is running and functional
    pubsub_ok? =
      case Process.whereis(GiTF.PubSub) do
        nil -> false
        pid -> Process.alive?(pid)
      end

    unless pubsub_ok? do
      Phoenix.PubSub.Supervisor.start_link(name: GiTF.PubSub)
    end

    # Ensure Registry is running and functional
    registry_ok? =
      try do
        Registry.lookup(GiTF.Registry, :__health_check__)
        true
      rescue
        ArgumentError -> false
      end

    unless registry_ok? do
      # Kill any zombie process
      case Process.whereis(GiTF.Registry) do
        nil -> :ok
        pid ->
          try do
            GenServer.stop(pid, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
      end
      Process.sleep(10)
      Registry.start_link(keys: :unique, name: GiTF.Registry)
    end

    :ok
  end

  defp safe_stop_pid(pid) do
    try do
      GenServer.stop(pid, :normal, 5000)
    catch
      :exit, _ -> :ok
    end
  end
end
