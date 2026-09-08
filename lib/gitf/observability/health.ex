defmodule GiTF.Observability.Health do
  @moduledoc """
  Health check endpoints for production monitoring.
  """

  require Logger
  alias GiTF.Archive

  @doc "Perform health check"
  @spec check() :: map()
  def check do
    # A Cabinet deliberately runs no Major, no sync queue, no ghosts and
    # calls no models; judging it by the factory's checks would report a
    # healthy Cabinet as degraded forever (the first one did, 2026-08-31).
    checks =
      if GiTF.Cabinet.mode?() do
        [
          {:pubsub, check_pubsub()},
          {:store, check_store()},
          {:disk, check_disk()},
          {:memory, check_memory()},
          {:git, check_git()}
        ]
      else
        [
          {:pubsub, check_pubsub()},
          {:store, check_store()},
          {:disk, check_disk()},
          {:memory, check_memory()},
          {:missions, check_quests()},
          {:model_api, check_model_api()},
          {:git, check_git()},
          {:major, check_major()},
          {:sync_queue, check_sync_queue()},
          {:sandbox, check_sandbox()}
        ]
      end

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

  @doc "Missions still wanting the factory or an operator (non-terminal)."
  @spec active_missions() :: [map()]
  def active_missions do
    Archive.filter(:missions, &GiTF.Missions.non_terminal?/1)
  end

  @doc """
  Missions that want the factory right now — `active_missions/0` minus the
  ones holding for a person. See `GiTF.Missions.running?/1`.
  """
  @spec running_missions() :: [map()]
  def running_missions, do: Enum.filter(active_missions(), &GiTF.Missions.running?/1)

  @doc "Get liveness status — detects zombie state (alive but unproductive)"
  @spec alive?() :: boolean()
  def alive? do
    probe(active_missions()) != :down
  rescue
    # Fail CLOSED at the gate, covering the input scan too: a raise in
    # active_missions used to collapse to [] and alive?([]) == true —
    # the hardened probe fed by an unguarded input.
    e ->
      Logger.error("Liveness probe raised: #{Exception.message(e)}")
      false
  end

  @doc "True unless the daemon's critical processes are gone. Accepts the active missions."
  @spec alive?([map()]) :: boolean()
  def alive?(active_quests), do: probe(active_quests) != :down

  @doc """
  The daemon's liveness, separated from its verdict on the work:

    * `:down` — the Major or the store is gone; nothing else can be trusted
    * `:stalled` — up, but running missions have shown no op activity for
      the stuck threshold (a zombie: alive and unproductive)
    * `:ok`

  Liveness readers (`/health`, idle-stop, `gitf wake`, the Cabinet fleet)
  act on `:down`; only the zombie alert acts on `:stalled`. One 503 for
  both made remote clients read a stalled or held factory as a box that
  never came up (msn-629e74).
  """
  @spec probe([map()]) :: :ok | :stalled | :down
  def probe(active_quests) do
    # A Cabinet runs no Major by design — its liveness is the store and
    # the endpoint answering.
    major_alive = GiTF.Cabinet.mode?() or Process.whereis(GiTF.Major) != nil

    cond do
      not major_alive or check_store() != :ok -> :down
      zombie?(active_quests) -> :stalled
      true -> :ok
    end
  rescue
    # Fail CLOSED: "the liveness probe crashed" must not read as "alive" —
    # that permanently blinds the zombie detector. Worst case here is a
    # spurious zombie alert, which is the survivable direction.
    e ->
      Logger.error("Liveness probe raised: #{Exception.message(e)}")
      :down
  end

  @doc """
  True when missions are running but no op has moved within the stuck
  threshold — the factory is up and not working. Held missions are not
  running (`GiTF.Missions.running?/1`).
  """
  @spec zombie?([map()]) :: boolean()
  def zombie?(active_quests) do
    case Enum.filter(active_quests, &GiTF.Missions.running?/1) do
      [] -> false
      running -> not Enum.any?(running, &recent_op_activity?/1)
    end
  end

  @doc """
  The idle-stop verdict: no ghost running, no mission running. A held
  mission needs nothing from the box until someone answers, and answering
  starts with `gitf wake` (msn-629e74). An unknown ghost count is never idle.
  """
  @spec idle?(non_neg_integer() | nil, [map()]) :: boolean()
  def idle?(ghosts, running_missions), do: ghosts == 0 and running_missions == []

  @doc """
  True when a running mission's own record has not moved within the stuck
  threshold, by awake time. The one rule behind `check_quests/0`, the
  `quest_stuck` alert and the dashboard.
  """
  @spec stuck?(map()) :: boolean()
  def stuck?(mission) do
    GiTF.Missions.running?(mission) and
      GiTF.Clock.awake_elapsed(mission[:updated_at]) > stuck_threshold_seconds()
  end

  defp stuck_threshold_seconds, do: GiTF.Config.Thresholds.get(:alert_quest_stuck_seconds)

  # Any op of this mission touched within the stuck threshold, by awake
  # time — a box that slept mid-mission must not wake up as a zombie.
  defp recent_op_activity?(mission) do
    threshold = stuck_threshold_seconds()

    Archive.by_index(:ops, :mission_id, mission.id)
    |> Enum.any?(fn op ->
      GiTF.Clock.awake_elapsed(op[:updated_at] || op[:created_at]) <= threshold
    end)
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

    # POSIX -P forces the 6-column layout on macOS + Linux.
    task =
      Task.async(fn ->
        System.cmd("df", ["-Pk", gitf_dir],
          stderr_to_stdout: true,
          env: [{"LC_ALL", "C"}, {"LANG", "C"}]
        )
      end)

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
    # Fail CLOSED: a disk check that crashed has not verified the disk.
    e ->
      Logger.warning("Disk health check raised: #{Exception.message(e)}")
      :error
  end

  defp check_memory do
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024
    if memory_mb < 1024, do: :ok, else: :warning
  end

  defp check_quests do
    if Enum.any?(Archive.all(:missions), &stuck?/1), do: :warning, else: :ok
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

  # Failing means sandbox_required is set but no kernel sandbox is effective —
  # ghosts would be refused, so the operator should see it before missions do.
  defp check_sandbox do
    case GiTF.Sandbox.check_policy() do
      :ok -> :ok
      {:error, _} -> :error
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
