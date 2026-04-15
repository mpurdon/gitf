defmodule GiTF.Readiness do
  @moduledoc """
  Tracks application readiness. Flips to `:ready` once core recovery
  (Major.handle_continue/resume_active_quests) has completed.

  `/health` is a liveness probe (this process alive + BEAM alive).
  `/ready` is a readiness probe (application fully initialized + core
  services responsive).
  """

  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> :not_ready end, name: __MODULE__)
  end

  @spec mark_ready() :: :ok
  def mark_ready do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> :ready end)
    end

    :ok
  end

  @spec status() :: :ready | :not_ready
  def status do
    case Process.whereis(__MODULE__) do
      nil -> :not_ready
      _ -> Agent.get(__MODULE__, & &1)
    end
  end

  @doc """
  Full readiness probe: checks the flag AND that core services respond.
  Returns `{:ok, checks}` or `{:error, checks}`.
  """
  @spec probe() :: {:ok, map()} | {:error, map()}
  def probe do
    archive_ok = archive_responsive?()
    major_ok = process_alive?(GiTF.Major)
    mission_sup_ok = process_alive?(GiTF.MissionSupervisor)
    flag_ok = status() == :ready

    checks = %{
      flag: flag_ok,
      archive: archive_ok,
      major: major_ok,
      mission_supervisor: mission_sup_ok
    }

    if flag_ok and archive_ok and major_ok and mission_sup_ok do
      {:ok, checks}
    else
      {:error, checks}
    end
  end

  defp process_alive?(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp archive_responsive? do
    try do
      task = Task.async(fn -> GiTF.Archive.count(:missions) end)

      case Task.yield(task, 100) || Task.shutdown(task, :brutal_kill) do
        {:ok, _} -> true
        _ -> false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end
end
