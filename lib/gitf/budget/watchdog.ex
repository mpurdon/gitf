defmodule GiTF.Budget.Watchdog do
  @moduledoc """
  Active budget enforcement for the GiTF.

  Periodically checks the accumulated cost of all active Quests and Ghosts.
  If a budget is exceeded, it:
  1. Pauses the mission (stops active ghosts, preserves state).
  2. Attempts auto-escalation (25% budget increase, up to 2x original).
  3. Resumes the mission if budget is expanded.
  4. Emits a high-priority alert.
  """

  use GenServer
  require Logger

  alias GiTF.Archive
  alias GiTF.Budget
  require GiTF.Ghost.Status, as: GhostStatus

  @check_interval :timer.seconds(10)
  @max_budget_multiplier 2.0
  # Auto-fail paused missions after this grace period (default: 2 hours)
  @pause_grace_hours 2

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Budget Watchdog started")
    schedule_check()
    {:ok, %{escalation_count: %{}}}
  end

  @impl true
  def handle_info(:check_budgets, state) do
    state = check_active_quests(state)
    check_paused_quests()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_budgets, @check_interval)
  end

  defp check_active_quests(state) do
    active_quests =
      Archive.filter(:missions, fn q ->
        q[:status] in [
          "active",
          "implementation",
          "research",
          "design",
          "review",
          "planning",
          "validation",
          "requirements"
        ]
      end)

    Enum.reduce(active_quests, state, fn mission, acc ->
      case Budget.check(mission.id) do
        {:error, :budget_exceeded, spent} ->
          handle_over_budget(mission, spent, acc)

        _ ->
          acc
      end
    end)
  end

  defp handle_over_budget(mission, spent, state) do
    mission_id = mission.id
    count = Map.get(state.escalation_count, mission_id, 0)
    original_budget = Budget.budget_for(mission_id)
    max_allowed = original_budget * @max_budget_multiplier

    if count < 3 and spent < max_allowed do
      # Auto-escalate: increase budget by 25%
      new_budget = Float.round(spent * 1.25, 2)
      new_budget = min(new_budget, max_allowed)

      # Archive budget override on the mission record
      case Archive.get(:missions, mission_id) do
        nil ->
          Logger.warning("Failed to escalate budget for mission #{mission_id}")

        quest_record ->
          Archive.put(:missions, Map.put(quest_record, :budget_override, new_budget))

          Logger.info(
            "Budget auto-escalated for mission #{mission_id}: " <>
              "$#{spent} spent, new budget $#{new_budget} (escalation #{count + 1})"
          )

          GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
            type: :budget_escalated,
            message: "Quest #{mission_id} budget escalated to $#{new_budget} (#{count + 1}x)"
          })
      end

      %{state | escalation_count: Map.put(state.escalation_count, mission_id, count + 1)}
    else
      # Max escalations reached — pause the mission, don't kill it
      Logger.warning(
        "Quest #{mission_id} exceeded max budget ($#{spent}). " <>
          "Pausing mission (#{count} escalations exhausted)."
      )

      pause_quest(mission, spent)
      state
    end
  end

  defp pause_quest(mission, spent) do
    mission_id = mission.id

    # Stop active ghosts but don't fail their ops (they can resume)
    active_ghosts =
      Archive.filter(:ghosts, fn b ->
        b.op_id != nil && b.status == GhostStatus.working()
      end)
      |> Enum.filter(fn b ->
        case Archive.get(:ops, b.op_id) do
          %{mission_id: ^mission_id} -> true
          _ -> false
        end
      end)

    Enum.each(active_ghosts, fn ghost ->
      Logger.warning("Watchdog killing ghost #{ghost.id} (Quest #{mission_id} over budget)")
      # Create transfer before stopping so work isn't lost
      try do
        GiTF.Transfer.create(ghost.id)
      rescue
        _ -> :ok
      end

      # Force-kill: GenServer.call(:stop) can hang if ghost is stuck
      case GiTF.Ghost.Worker.lookup(ghost.id) do
        {:ok, pid} ->
          # Give 2s for graceful stop, then kill
          try do
            GenServer.call(pid, :stop, 2_000)
          catch
            :exit, _ -> Process.exit(pid, :kill)
          end

        :error ->
          :ok
      end
    end)

    update_quest_status(mission.id, "paused_budget", %{paused_at: DateTime.utc_now()})

    GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
      type: :budget_paused,
      message: "Quest #{mission.id} paused at $#{spent} (budget exhausted after escalations)"
    })
  end

  defp check_paused_quests do
    # Check if any paused missions now have budget (e.g., manual increase)
    paused = Archive.filter(:missions, fn q -> q[:status] == "paused_budget" end)

    Enum.each(paused, fn mission ->
      case Budget.check(mission.id) do
        {:ok, _remaining} ->
          Logger.info("Quest #{mission.id} budget restored, resuming")
          update_quest_status(mission.id, "active")

          # Notify Major to re-evaluate
          GiTF.Link.send(
            "watchdog",
            "major",
            "quest_advance",
            mission.id
          )

        _ ->
          # Check grace period — auto-fail if paused too long
          maybe_auto_fail_paused(mission)
      end
    end)
  rescue
    _ -> :ok
  end

  defp maybe_auto_fail_paused(mission) do
    paused_at =
      Map.get(mission, :paused_at) || Map.get(mission, :updated_at) ||
        Map.get(mission, :inserted_at)

    case paused_at do
      %DateTime{} = ts ->
        hours_paused = DateTime.diff(DateTime.utc_now(), ts, :second) / 3600

        if hours_paused > @pause_grace_hours do
          Logger.warning(
            "Quest #{mission.id} paused for #{Float.round(hours_paused, 1)}h (grace period exceeded), auto-failing"
          )

          GiTF.Missions.transition_phase(
            mission.id,
            "completed",
            "Budget exhausted — auto-failed after #{@pause_grace_hours}h grace period"
          )

          GiTF.Missions.update_status!(mission.id)

          GiTF.Telemetry.emit([:gitf, :alert, :raised], %{}, %{
            type: :budget_auto_failed,
            message:
              "Quest #{mission.id} auto-failed after #{@pause_grace_hours}h budget pause grace period"
          })
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "Auto-fail check failed for paused mission #{mission.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp update_quest_status(mission_id, status, extra \\ %{}) do
    case Archive.get(:missions, mission_id) do
      nil -> :ok
      mission -> Archive.put(:missions, Map.merge(mission, Map.put(extra, :status, status)))
    end
  end
end
