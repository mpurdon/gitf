defmodule GiTF.Aramaki do
  @moduledoc """
  Aramaki — the project-management / admission layer above the factory.

  Named for Section 9's chief, who decides which cases the team takes. Where
  the Major orchestrates *how* a mission runs, Aramaki decides *which* work
  becomes a mission and *when* it starts.

  Responsibilities:

    * **Ingest** signals — GitHub issues (via `Aramaki.Intake` off the webhook),
      and any other pending, un-started missions (inbox / Sentry). This also
      closes a long-standing gap: pending missions from those sources were
      never auto-started.
    * **Admit** work within capacity — a periodic tick (and event nudges) start
      pending Aramaki missions in priority order, but only while
      `Aramaki.Policy.capacity_available?/1` holds (factory daily budget +
      concurrent-mission cap). Admission is a multiplier on every runaway risk,
      so the gate is deliberately conservative.
    * **Report** back on GitHub — `Aramaki.Lifecycle` comments/labels the source
      issue as the mission moves, links the PR on publish, and closes the issue
      on merge.

  Untrusted-input safety: issue bodies are attacker-controllable, and ghosts
  now run sandboxed (see `GiTF.Sandbox`), but admission is still label-gated
  (`gitf:build`) so only maintainer-approved issues ever reach the factory.

  Enable with config `[:aramaki, :enabled] = true` (default false) — Aramaki is
  opt-in; without it the factory behaves exactly as before.
  """

  use GenServer
  require Logger

  alias GiTF.Aramaki.Policy

  @tick_interval_ms 30_000

  # Intake channels whose pending missions Aramaki owns (and will auto-start).
  # Operator-created missions (source nil) are deliberately NOT auto-started.
  @owned_sources ~w(github_issue project)

  # -- Client ----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether Aramaki is enabled (config `[:aramaki, :enabled]`, default false)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:gitf, :aramaki, []) |> Keyword.get(:enabled, false) == true
  end

  @doc """
  Force an admission pass now (used by tests, webhook nudges, and project
  advancement). Uses the `{:consider, _}` path so it does NOT reschedule the
  periodic timer — only the timer's own `:tick` does that, otherwise every
  nudge would add another recurring timer.
  """
  @spec tick() :: :ok
  def tick do
    if pid = Process.whereis(__MODULE__), do: send(pid, {:consider, :manual})
    :ok
  end

  # -- Server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    advance_projects()
    admit_pending()
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:consider, _mission_id}, state) do
    # An intake just created a pending mission (or a project mission finished,
    # possibly unblocking dependents) — act now rather than on the next tick.
    advance_projects()
    admit_pending()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Admission -------------------------------------------------------------

  @doc """
  Starts as many pending Aramaki missions as capacity allows, highest priority
  first. Public so tests can drive it deterministically. Returns the number
  admitted.
  """
  @spec admit_pending() :: non_neg_integer()
  def admit_pending do
    active = active_count()

    case Policy.capacity_available?(active) do
      {:full, reason} ->
        if pending_aramaki_missions() != [] do
          Logger.info("Aramaki: capacity full (#{reason}); holding pending work")
        end

        0

      {:ok, slots} ->
        pending_aramaki_missions()
        |> Enum.sort_by(&Map.get(&1, :aramaki_priority, 2))
        |> Enum.take(slots)
        |> Enum.reduce(0, fn mission, admitted ->
          case admit(mission) do
            :ok -> admitted + 1
            _ -> admitted
          end
        end)
    end
  rescue
    e ->
      Logger.warning("Aramaki.admit_pending crashed: #{Exception.message(e)}")
      0
  end

  defp admit(mission) do
    Logger.info("Aramaki: starting mission #{mission.id} (priority #{Map.get(mission, :aramaki_priority, 2)})")

    case GiTF.Major.Orchestrator.start_quest(mission.id) do
      {:ok, _} ->
        GiTF.Aramaki.Lifecycle.on_admitted(mission)
        :ok

      {:error, reason} ->
        Logger.warning("Aramaki: start_quest failed for #{mission.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Project advancement -----------------------------------------------------

  @doc """
  Creates pending missions for every ready roadmap item of every active
  project (an item is ready when all its `depends_on` items completed). The
  missions then flow through the same capacity-gated `admit_pending/0` as
  issue-sourced work. Returns the number of missions created.
  """
  @spec advance_projects() :: non_neg_integer()
  def advance_projects do
    GiTF.Project.by_status("active")
    |> Enum.reduce(0, fn project, created ->
      created + advance_project(project)
    end)
  rescue
    e ->
      Logger.warning("Aramaki.advance_projects crashed: #{Exception.message(e)}")
      0
  end

  defp advance_project(project) do
    # Heal items whose mission finished without the terminal notification
    # (restart/crash windows), then work from the healed record — which may
    # have left the project paused (item failure) or completed.
    :ok = GiTF.Project.reconcile(project)
    project = GiTF.Project.get(project.id) || project

    ready = if project.status == "active", do: GiTF.Project.ready_items(project), else: []

    Enum.reduce(ready, 0, fn item, created ->
      attrs = %{
        goal: GiTF.Project.mission_goal(project, item),
        name: "#{project.name}: #{String.slice(item.title, 0, 50)}",
        sector_id: project.sector_id,
        workflow_id: item.workflow_id,
        source: "project",
        source_project: %{project_id: project.id, item_id: item.id},
        aramaki_priority: Map.get(project, :aramaki_priority, 2)
      }

      case GiTF.Missions.create(attrs) do
        {:ok, mission} ->
          {:ok, _} = GiTF.Project.attach_mission(project.id, item.id, mission.id)

          Logger.info(
            "Aramaki: project #{project.id} item #{item.id} → pending mission #{mission.id}"
          )

          created + 1

        {:error, reason} ->
          Logger.warning(
            "Aramaki: mission create failed for project #{project.id} item #{item.id}: #{inspect(reason)}"
          )

          created
      end
    end)
  end

  # Pending missions that Aramaki owns (came in through an owned intake
  # channel). We deliberately do NOT auto-start arbitrary pending missions —
  # only ones that came through Aramaki's admission gate.
  defp pending_aramaki_missions do
    GiTF.Archive.all(:missions)
    |> Enum.filter(fn m ->
      Map.get(m, :status) == "pending" and Map.get(m, :source) in @owned_sources
    end)
  end

  defp active_count do
    GiTF.Archive.all(:missions)
    |> Enum.count(fn m ->
      Map.get(m, :source) in @owned_sources and
        Map.get(m, :status) in GiTF.Missions.active_statuses()
    end)
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end
