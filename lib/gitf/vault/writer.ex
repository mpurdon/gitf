defmodule GiTF.Vault.Writer do
  @moduledoc """
  Projects Factory state to the Obsidian vault on disk.

  The Writer subscribes to existing telemetry events (mission lifecycle,
  ghost lifecycle) and renders the corresponding markdown files. Writes
  are debounced per file so a burst of phase advances on one mission
  produces a single re-render, not one write per event.

  ## Why a GenServer

  We need:

  - A debounce window (otherwise N tightly-scheduled events → N writes).
  - A serial commit point (atomic temp+rename per file is enough on its
    own, but rendering with stale Archive reads can race; we read at
    commit time inside the GenServer to get a consistent snapshot).
  - Backpressure: if disk is slow we don't want telemetry handlers
    blocking on writes.

  Telemetry handlers are pure dispatch — they `cast` an event into the
  Writer and return immediately. The Writer batches per-target keys (one
  pending render per target across the debounce window).

  ## Event → target mapping

  | Event                                        | Targets re-rendered                |
  |----------------------------------------------|-----------------------------------|
  | `[:gitf, :mission, :created]`                | mission file, sector kanban       |
  | `[:gitf, :mission, :priority_changed]`       | mission file, sector kanban       |
  | `[:gitf, :mission, :completed]`              | mission file, sector kanban       |
  | `[:gitf, :mission, :user_visible_completed]` | mission file, sector kanban       |
  | `[:gitf, :mission_server, :started]`         | mission file, sector kanban       |
  | `[:gitf, :mission_server, :phase_complete]`  | mission file, sector kanban       |
  | `[:gitf, :ghost, :spawned]`                  | ghost profile                      |
  | `[:gitf, :ghost, :completed]`                | ghost profile                      |
  | `[:gitf, :ghost, :failed]`                   | ghost profile                      |

  Daily notes and full-vault rebuilds are explicit (called by the Major's
  scheduler or via API) — not telemetry-driven.

  ## Disabled by default

  Set `:vault_writer_enabled` to `true` to attach handlers. With the
  Writer disabled, telemetry events flow through with no side effects;
  this is the default in tests and for operators who don't use the vault.
  """

  use GenServer
  require Logger

  alias GiTF.Archive
  alias GiTF.Vault.File, as: VFile
  alias GiTF.Vault.Path, as: VPath
  alias GiTF.Vault.Renderer.{DailyNote, Ghost, Kanban, Mission}

  @name __MODULE__
  @default_debounce_ms 1_500

  # -- Public API ------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || @name)
  end

  @doc """
  Schedules a render of the mission file for `mission_id`. Coalesces with
  any pending render for the same mission within the debounce window.
  """
  @spec render_mission(String.t()) :: :ok
  def render_mission(mission_id) when is_binary(mission_id) do
    cast({:render_mission, mission_id})
  end

  @doc "Schedules a render of the kanban for `sector_id`."
  @spec render_kanban(String.t()) :: :ok
  def render_kanban(sector_id) when is_binary(sector_id) do
    cast({:render_kanban, sector_id})
  end

  @doc "Schedules a render of the ghost profile for `ghost_id`."
  @spec render_ghost(String.t()) :: :ok
  def render_ghost(ghost_id) when is_binary(ghost_id) do
    cast({:render_ghost, ghost_id})
  end

  @doc """
  Renders the daily note for `date` (Date or nil → today). Synchronous —
  intended for the Major's nightly scheduler or `gitf vault daily`.
  """
  @spec render_daily_note(Date.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def render_daily_note(date \\ nil) do
    GenServer.call(@name, {:render_daily_note, date || Date.utc_today()}, 30_000)
  end

  @doc """
  Forces all pending debounced renders to commit immediately. Returns
  after every queued write completes. Useful in tests and at shutdown.
  """
  @spec flush() :: :ok
  def flush, do: GenServer.call(@name, :flush, 30_000)

  @doc "Whether the Writer is currently enabled (read at every event)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:gitf, :vault_writer_enabled, false) == true
  end

  @doc """
  Attaches telemetry handlers. Idempotent; safe to call multiple times.
  Only takes effect when `enabled?/0` returns true at event time.
  """
  @spec attach_telemetry() :: :ok
  def attach_telemetry do
    handlers = [
      {[:gitf, :mission, :created], &handle_mission_event/4},
      {[:gitf, :mission, :priority_changed], &handle_mission_event/4},
      {[:gitf, :mission, :completed], &handle_mission_event/4},
      {[:gitf, :mission, :user_visible_completed], &handle_mission_event/4},
      {[:gitf, :mission_server, :started], &handle_mission_event/4},
      {[:gitf, :mission_server, :phase_complete], &handle_mission_event/4},
      {[:gitf, :ghost, :spawned], &handle_ghost_event/4},
      {[:gitf, :ghost, :completed], &handle_ghost_event/4},
      {[:gitf, :ghost, :failed], &handle_ghost_event/4}
    ]

    Enum.each(handlers, fn {event, fun} ->
      handler_id = "gitf-vault-writer-#{Enum.join(event, ".")}"
      :telemetry.detach(handler_id)
      :telemetry.attach(handler_id, event, fun, nil)
    end)

    :ok
  end

  # -- Telemetry handlers (run in caller process) ----------------------------

  @doc false
  def handle_mission_event(_event, _measurements, metadata, _config) do
    if enabled?() do
      mission_id = metadata[:mission_id] || metadata["mission_id"]

      if is_binary(mission_id) do
        render_mission(mission_id)

        case Archive.get(:missions, mission_id) do
          %{sector_id: sid} when is_binary(sid) -> render_kanban(sid)
          _ -> :ok
        end
      end
    end

    :ok
  end

  @doc false
  def handle_ghost_event(_event, _measurements, metadata, _config) do
    if enabled?() do
      ghost_id = metadata[:ghost_id] || metadata[:bee_id] || metadata["ghost_id"]
      if is_binary(ghost_id), do: render_ghost(ghost_id)
    end

    :ok
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       pending: MapSet.new(),
       timer: nil,
       debounce_ms: opts[:debounce_ms] || @default_debounce_ms
     }}
  end

  @impl true
  def handle_cast({:render_mission, _} = job, state), do: {:noreply, enqueue(job, state)}
  def handle_cast({:render_kanban, _} = job, state), do: {:noreply, enqueue(job, state)}
  def handle_cast({:render_ghost, _} = job, state), do: {:noreply, enqueue(job, state)}

  @impl true
  def handle_info(:debounce_tick, state) do
    state = %{state | timer: nil}
    {:noreply, commit_pending(state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state =
      if state.timer do
        Process.cancel_timer(state.timer)
        %{state | timer: nil}
      else
        state
      end

    {:reply, :ok, commit_pending(state)}
  end

  @impl true
  def handle_call({:render_daily_note, date}, _from, state) do
    {:reply, do_render_daily_note(date), state}
  end

  # -- Internals -------------------------------------------------------------

  defp cast(msg) do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.cast(@name, msg)
    end
  end

  defp enqueue(job, state) do
    pending = MapSet.put(state.pending, job)
    timer = state.timer || Process.send_after(self(), :debounce_tick, state.debounce_ms)
    %{state | pending: pending, timer: timer}
  end

  defp commit_pending(%{pending: pending} = state) do
    Enum.each(pending, &commit_job/1)
    %{state | pending: MapSet.new()}
  end

  defp commit_job({:render_mission, mission_id}), do: do_render_mission(mission_id)
  defp commit_job({:render_kanban, sector_id}), do: do_render_kanban(sector_id)
  defp commit_job({:render_ghost, ghost_id}), do: do_render_ghost(ghost_id)

  defp do_render_mission(mission_id) do
    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         %{} = mission <- Archive.get(:missions, mission_id),
         sector_id when is_binary(sector_id) <- mission[:sector_id] || "_global" do
      activity = activity_for(mission)
      body = Mission.render(mission, activity: activity)
      title = mission[:name] || mission[:goal] || mission_id
      file = VPath.mission_file(gitf_root, sector_id, mission_id, title)

      case VFile.write(file, body) do
        {:ok, _hash} -> :ok
        {:error, reason} -> Logger.warning("Vault.Writer mission write failed: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp do_render_kanban(sector_id) do
    with {:ok, gitf_root} <- GiTF.gitf_dir() do
      missions = Archive.filter(:missions, fn m -> m[:sector_id] == sector_id end)
      body = Kanban.render(sector_id, missions)
      file = VPath.sector_kanban_file(gitf_root, sector_id)

      case VFile.write(file, body) do
        {:ok, _hash} -> :ok
        {:error, reason} -> Logger.warning("Vault.Writer kanban write failed: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp do_render_ghost(ghost_id) do
    with {:ok, gitf_root} <- GiTF.gitf_dir(),
         %{} = ghost <- Archive.get(:ghosts, ghost_id) do
      recent = recent_missions_for_ghost(ghost)
      body = Ghost.render(ghost, recent_missions: recent)
      file = VPath.ghost_file(gitf_root, ghost[:name] || ghost_id)

      case VFile.write(file, body) do
        {:ok, _hash} -> :ok
        {:error, reason} -> Logger.warning("Vault.Writer ghost write failed: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp do_render_daily_note(date) do
    with {:ok, gitf_root} <- GiTF.gitf_dir() do
      snapshot = build_daily_snapshot(date)
      body = DailyNote.render(snapshot)
      file = VPath.daily_note_file(gitf_root, date)

      case VFile.write(file, body) do
        {:ok, _hash} -> {:ok, file}
        {:error, _} = err -> err
      end
    end
  end

  # -- Snapshot assembly -----------------------------------------------------

  defp activity_for(_mission) do
    # M2 keeps activity minimal — the Major doesn't yet log structured
    # event timelines per mission. M3's Compile/Lint pass will populate
    # this from the ledger + telemetry archive. For now: empty.
    []
  end

  defp recent_missions_for_ghost(ghost) do
    Archive.filter(:missions, fn m ->
      m[:current_ghost_id] == ghost[:id] or has_phase_job_for_ghost?(m, ghost[:id])
    end)
    |> Enum.sort_by(fn m -> m[:updated_at] || m[:inserted_at] end, {:desc, DateTime})
    |> Enum.take(10)
  end

  defp has_phase_job_for_ghost?(%{phase_jobs: jobs}, ghost_id) when is_map(jobs) do
    Enum.any?(jobs, fn {_phase, j} -> j[:ghost_id] == ghost_id end)
  end

  defp has_phase_job_for_ghost?(_, _), do: false

  defp build_daily_snapshot(date) do
    midnight = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_of_day = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

    all_missions = Archive.all(:missions)

    merged_today = Enum.filter(all_missions, &merged_in_range?(&1, midnight, end_of_day))
    failed_today = Enum.filter(all_missions, &failed_in_range?(&1, midnight, end_of_day))

    in_flight =
      Enum.filter(all_missions, fn m -> m[:status] in GiTF.Missions.active_statuses() end)

    sectors = sector_summaries(all_missions)

    %{
      date: date,
      missions: %{
        merged_today: merged_today,
        failed_today: failed_today,
        in_flight: in_flight,
        planned_today: []
      },
      ghosts: %{active: active_ghosts()},
      sectors: sectors,
      costs: %{}
    }
  end

  defp merged_in_range?(%{status: status, updated_at: t}, from, to)
       when status in ["completed", "merged"] and not is_nil(t) do
    DateTime.compare(t, from) != :lt and DateTime.compare(t, to) != :gt
  end

  defp merged_in_range?(_, _, _), do: false

  defp failed_in_range?(%{status: "failed", updated_at: t}, from, to) when not is_nil(t) do
    DateTime.compare(t, from) != :lt and DateTime.compare(t, to) != :gt
  end

  defp failed_in_range?(_, _, _), do: false

  defp sector_summaries(missions) do
    missions
    |> Enum.group_by(& &1[:sector_id])
    |> Enum.reject(fn {sid, _} -> is_nil(sid) end)
    |> Enum.map(fn {sid, sector_missions} ->
      counts =
        Enum.reduce(sector_missions, %{todo: 0, doing: 0, review: 0, done: 0}, fn m, acc ->
          case lane_for_status(m[:status]) do
            :todo -> %{acc | todo: acc.todo + 1}
            :doing -> %{acc | doing: acc.doing + 1}
            :review -> %{acc | review: acc.review + 1}
            :done -> %{acc | done: acc.done + 1}
            _ -> acc
          end
        end)

      Map.put(counts, :id, sid)
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp lane_for_status(s)
       when s in ["pending", "planning", "requirements"],
       do: :todo

  defp lane_for_status(s)
       when s in ["active", "research", "design", "implementation", "validation"],
       do: :doing

  defp lane_for_status(s) when s in ["review", "awaiting_approval"], do: :review
  defp lane_for_status(s) when s in ["completed", "merged"], do: :done
  defp lane_for_status(_), do: nil

  defp active_ghosts do
    Archive.filter(:ghosts, fn g -> g[:status] in [:running, "running", :provisioning] end)
  end

end
