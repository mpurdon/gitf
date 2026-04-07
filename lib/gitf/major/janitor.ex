defmodule GiTF.Major.Janitor do
  @moduledoc """
  Autonomous maintenance agent for the Dark Factory.

  The Janitor identifies "passive" codebase improvements when the factory is idle:
  - Documentation gaps (missing @doc, @moduledoc)
  - Type spec gaps
  - Linter warnings
  - Dead code identification
  - Code duplication
  """

  require Logger
  alias GiTF.Archive

  @doc """
  Evaluates the factory state and spawns janitor missions if idle.
  """
  def run_if_idle do
    if GiTF.Config.dark_factory?() do
      missions = Archive.all(:missions)

      if idle?(missions) and budget_healthy?(missions) and janitor_backpressure_ok?(missions) do
        Logger.info("Factory is idle, spawning janitor mission...")
        spawn_janitor_mission()
      end
    end

    :ok
  end

  @max_janitor_missions 2
  @cooldown_minutes 30

  defp idle?(missions) do
    not Enum.any?(missions, &(&1.status == "active"))
  end

  defp janitor_backpressure_ok?(missions) do
    janitor_count =
      Enum.count(missions, fn m ->
        m.status in ["active", "pending"] and
          String.starts_with?(m.name || "", "janitor-")
      end)

    janitor_count < @max_janitor_missions
  end

  defp budget_healthy?(missions) do
    active = Enum.filter(missions, &(&1.status == "active"))

    no_overages =
      Enum.all?(active, fn mission ->
        case GiTF.Budget.check(mission.id) do
          {:ok, _remaining} -> true
          {:error, :budget_exceeded, _} -> false
        end
      end)

    config_budget = GiTF.Budget.config_budget()

    total_spent =
      Enum.reduce(active, 0.0, fn m, acc ->
        acc + GiTF.Budget.spent_for(m.id)
      end)

    headroom = config_budget - total_spent
    no_overages and headroom > 0.50
  rescue
    _ -> true
  end

  defp spawn_janitor_mission do
    sectors = Archive.all(:sectors)

    if sectors != [] do
      # Load janitor_runs once, build lookup map by sector_id
      runs_by_sector =
        Archive.all(:janitor_runs)
        |> Map.new(fn r -> {r.sector_id, r} end)

      sector = pick_least_recent_sector(sectors, runs_by_sector)
      run = Map.get(runs_by_sector, sector.id)

      if recently_maintained?(run) do
        Logger.debug("Janitor: sector #{sector.id} was recently maintained, skipping")
        :ok
      else
        goal = pick_janitor_goal(run)

        case GiTF.Missions.create(%{
               goal: goal,
               sector_id: sector.id,
               name: "janitor-#{GiTF.ID.generate(:msn)}",
               status: "pending"
             }) do
          {:ok, mission} ->
            record_maintenance(sector.id, goal, run)
            Logger.info("Janitor: created mission #{mission.id} for sector #{sector.name}")
            GiTF.Major.Orchestrator.start_quest(mission.id, force_fast_path: true)

          _ ->
            :ok
        end
      end
    end
  end

  defp pick_least_recent_sector(sectors, runs_by_sector) do
    Enum.min_by(sectors, fn sector ->
      case Map.get(runs_by_sector, sector.id) do
        nil -> ~U[2000-01-01 00:00:00Z]
        run -> run.maintained_at
      end
    end, DateTime)
  end

  defp recently_maintained?(nil), do: false

  defp recently_maintained?(run) do
    minutes_ago = DateTime.diff(DateTime.utc_now(), run.maintained_at, :second) / 60
    minutes_ago < @cooldown_minutes
  end

  defp record_maintenance(sector_id, goal, nil) do
    Archive.insert(:janitor_runs, %{
      sector_id: sector_id,
      maintained_at: DateTime.utc_now(),
      last_goal: goal
    })
  end

  defp record_maintenance(_sector_id, goal, existing) do
    existing
    |> Map.put(:maintained_at, DateTime.utc_now())
    |> Map.put(:last_goal, goal)
    |> then(&Archive.put(:janitor_runs, &1))
  end

  @goals [
    "Identify and add missing @doc and @moduledoc strings to public modules and functions.",
    "Add Elixir type specifications (@spec) to public functions that are missing them.",
    "Identify and remove unused private functions or variables.",
    "Check for TODO or FIXME comments and resolve the ones that are simple fixes.",
    "Identify code blocks that are duplicated and suggest a shared helper function."
  ]

  defp pick_janitor_goal(nil), do: Enum.random(@goals)

  defp pick_janitor_goal(%{last_goal: last_goal}) when is_binary(last_goal) do
    candidates = Enum.reject(@goals, &(&1 == last_goal))
    candidates = if candidates == [], do: @goals, else: candidates
    Enum.random(candidates)
  end

  defp pick_janitor_goal(_), do: Enum.random(@goals)
end
