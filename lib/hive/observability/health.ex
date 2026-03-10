defmodule Hive.Observability.Health do
  @moduledoc """
  Health check endpoints for production monitoring.
  """

  require Logger
  alias Hive.Store

  @doc "Perform health check"
  def check do
    checks = [
      {:pubsub, check_pubsub()},
      {:store, check_store()},
      {:disk, check_disk()},
      {:memory, check_memory()},
      {:quests, check_quests()},
      {:model_api, check_model_api()},
      {:git, check_git()},
      {:queen, check_queen()},
      {:merge_queue, check_merge_queue()}
    ]

    status = if Enum.all?(checks, fn {_, s} -> s == :ok end), do: :healthy, else: :degraded

    %{
      status: status,
      checks: Map.new(checks),
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Get readiness status"
  def ready? do
    check_store() == :ok
  end

  @doc "Get liveness status — detects zombie state (alive but unproductive)"
  def alive? do
    # Check critical processes exist
    queen_alive = Process.whereis(Hive.Queen) != nil
    store_ok = check_store() == :ok

    if not queen_alive or not store_ok do
      false
    else
      # Check for zombie: active quests exist but no job activity for 30+ minutes
      active_quests = Store.filter(:quests, fn q ->
        q[:status] not in [nil, "completed", "failed", "cancelled", "paused", "paused_budget"]
      end)

      if active_quests == [] do
        true
      else
        # Any job activity in last 30 minutes?
        thirty_min_ago = DateTime.add(DateTime.utc_now(), -1800, :second)
        recent_activity = Store.filter(:jobs, fn j ->
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
    Store.all(:quests)
    :ok
  rescue
    _ -> :error
  end

  defp check_disk do
    hive_dir =
      case :persistent_term.get({Hive.Store, :data_path}, nil) do
        nil -> File.cwd!()
        path -> Path.dirname(path)
      end

    task = Task.async(fn -> System.cmd("df", ["-k", hive_dir], stderr_to_stdout: true) end)

    df_result = case Task.yield(task, 5_000) || Task.shutdown(task, 1_000) do
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
    quests = Store.all(:quests)

    stuck =
      Enum.count(quests, fn q ->
        q.status == "active" &&
          DateTime.diff(DateTime.utc_now(), q.updated_at) > 1800
      end)

    if stuck == 0, do: :ok, else: :warning
  end

  defp check_model_api do
    case Hive.Runtime.Models.find_executable() do
      {:ok, _path} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp check_git do
    case System.find_executable("git") do
      nil -> :error
      _path -> :ok
    end
  end

  defp check_queen do
    case Process.whereis(Hive.Queen) do
      nil -> :warning
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

  defp check_merge_queue do
    case Hive.Merge.Queue.lookup() do
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
    topic = "hive:health_check:#{:erlang.unique_integer([:positive])}"

    case Phoenix.PubSub.subscribe(Hive.PubSub, topic) do
      :ok ->
        Phoenix.PubSub.broadcast(Hive.PubSub, topic, :health_ping)

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
