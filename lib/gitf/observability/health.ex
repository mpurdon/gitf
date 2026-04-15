defmodule GiTF.Observability.Health do
  @moduledoc """
  Health check endpoints for production monitoring.
  """

  require Logger
  alias GiTF.Archive

  @doc "Perform health check"
  @spec check() :: map()
  def check do
    checks = [
      {:pubsub, check_pubsub()},
      {:store, check_store()},
      {:disk, check_disk()},
      {:memory, check_memory()},
      {:missions, check_quests()},
      {:model_api, check_model_api()},
      {:git, check_git()},
      {:major, check_major()},
      {:sync_queue, check_sync_queue()}
    ]

    status = if Enum.all?(checks, fn {_, s} -> s == :ok end), do: :healthy, else: :degraded

    %{
      status: status,
      checks: Map.new(checks),
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Get readiness status"
  @spec ready?() :: boolean()
  def ready? do
    check_store() == :ok
  end

  @doc "Get liveness status — detects zombie state (alive but unproductive)"
  @spec alive?() :: boolean()
  def alive? do
    # Check critical processes exist
    major_alive = Process.whereis(GiTF.Major) != nil
    store_ok = check_store() == :ok

    if not major_alive or not store_ok do
      false
    else
      # Check for zombie: active missions exist but no op activity for 30+ minutes
      active_quests =
        Archive.filter(:missions, fn q ->
          q[:status] not in [nil, "completed", "failed", "cancelled", "paused", "paused_budget"]
        end)

      if active_quests == [] do
        true
      else
        # Any op activity in last 30 minutes?
        thirty_min_ago = DateTime.shift(DateTime.utc_now(), minute: -30)

        recent_activity =
          Archive.filter(:ops, fn j ->
            updated = j[:updated_at] || j[:created_at]
            updated != nil and DateTime.compare(updated, thirty_min_ago) == :gt
          end)

        recent_activity != []
      end
    end
  rescue
    _ -> true
  end

  defp check_store do
    Archive.all(:missions)
    :ok
  rescue
    _ -> :error
  end

  defp check_disk do
    gitf_dir =
      case :persistent_term.get({GiTF.Archive, :data_path}, nil) do
        nil -> File.cwd!()
        path -> Path.dirname(path)
      end

    task = Task.async(fn -> System.cmd("df", ["-k", gitf_dir], stderr_to_stdout: true) end)

    df_result =
      case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
        {:ok, result} -> result
        nil -> {"", 1}
      end

    case df_result do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)

        case lines do
          [_header, data_line | _] ->
            fields = String.split(data_line, ~r/\s+/, trim: true)

            case Enum.at(fields, 3) do
              nil ->
                :ok

              avail_str ->
                avail_kb = String.to_integer(avail_str)
                avail_mb = div(avail_kb, 1024)
                if avail_mb < 100, do: :error, else: :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp check_memory do
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024
    if memory_mb < 1024, do: :ok, else: :warning
  end

  defp check_quests do
    missions = Archive.all(:missions)

    stuck =
      Enum.count(missions, fn q ->
        q.status == "active" &&
          DateTime.diff(DateTime.utc_now(), q.updated_at) > 1800
      end)

    if stuck == 0, do: :ok, else: :warning
  end

  defp check_model_api do
    if GiTF.Runtime.ModelResolver.api_mode?() do
      # In API mode, check that at least one API key is configured
      has_key = GiTF.Runtime.Keys.status() |> Enum.any?(fn {_, v} -> v end)
      if has_key, do: :ok, else: :warning
    else
      case GiTF.Runtime.Models.find_executable() do
        {:ok, _path} -> :ok
        {:error, _} -> :error
      end
    end
  rescue
    _ -> :warning
  end

  defp check_git do
    case System.find_executable("git") do
      nil -> :error
      _path -> :ok
    end
  end

  defp check_major do
    case Process.whereis(GiTF.Major) do
      nil ->
        :warning

      pid ->
        if Process.alive?(pid) do
          try do
            GenServer.call(pid, :status, 2_000)
            :ok
          catch
            :exit, _ -> :error
          end
        else
          :error
        end
    end
  rescue
    _ -> :warning
  end

  defp check_sync_queue do
    case GiTF.Sync.Queue.lookup() do
      {:ok, pid} ->
        if Process.alive?(pid), do: :ok, else: :error

      :error ->
        :warning
    end
  rescue
    _ -> :warning
  end

  defp check_pubsub do
    # Verify PubSub is alive by doing a subscribe/broadcast round-trip
    topic = "section:health_check:#{:erlang.unique_integer([:positive])}"

    case Phoenix.PubSub.subscribe(GiTF.PubSub, topic) do
      :ok ->
        Phoenix.PubSub.broadcast(GiTF.PubSub, topic, :health_ping)

        receive do
          :health_ping -> :ok
        after
          100 -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
