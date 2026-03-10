defmodule Hive.Budget.Watchdog do
  @moduledoc """
  Active budget enforcement for the Hive.

  Periodically checks the accumulated cost of all active Quests and Bees.
  If a budget is exceeded, it:
  1. Pauses the quest (stops active bees, preserves state).
  2. Attempts auto-escalation (25% budget increase, up to 2x original).
  3. Resumes the quest if budget is expanded.
  4. Emits a high-priority alert.
  """

  use GenServer
  require Logger

  alias Hive.Store
  alias Hive.Budget

  @check_interval :timer.seconds(10)
  @max_budget_multiplier 2.0

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
      Store.filter(:quests, fn q ->
        q[:status] in ["active", "implementation", "research", "design",
                        "review", "planning", "validation", "requirements"]
      end)

    Enum.reduce(active_quests, state, fn quest, acc ->
      case Budget.check(quest.id) do
        {:error, :budget_exceeded, spent} ->
          handle_over_budget(quest, spent, acc)
        _ ->
          acc
      end
    end)
  end

  defp handle_over_budget(quest, spent, state) do
    quest_id = quest.id
    count = Map.get(state.escalation_count, quest_id, 0)
    original_budget = Budget.budget_for(quest_id)
    max_allowed = original_budget * @max_budget_multiplier

    if count < 3 and spent < max_allowed do
      # Auto-escalate: increase budget by 25%
      new_budget = Float.round(spent * 1.25, 2)
      new_budget = min(new_budget, max_allowed)

      # Store budget override on the quest record
      case Store.get(:quests, quest_id) do
        nil ->
          Logger.warning("Failed to escalate budget for quest #{quest_id}")

        quest_record ->
          Store.put(:quests, Map.put(quest_record, :budget_override, new_budget))

          Logger.info(
            "Budget auto-escalated for quest #{quest_id}: " <>
              "$#{spent} spent, new budget $#{new_budget} (escalation #{count + 1})"
          )

          Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{
            type: :budget_escalated,
            message: "Quest #{quest_id} budget escalated to $#{new_budget} (#{count + 1}x)"
          })
      end

      %{state | escalation_count: Map.put(state.escalation_count, quest_id, count + 1)}
    else
      # Max escalations reached — pause the quest, don't kill it
      Logger.warning(
        "Quest #{quest_id} exceeded max budget ($#{spent}). " <>
          "Pausing quest (#{count} escalations exhausted)."
      )

      pause_quest(quest, spent)
      state
    end
  end

  defp pause_quest(quest, spent) do
    quest_id = quest.id

    # Stop active bees but don't fail their jobs (they can resume)
    active_bees =
      Store.filter(:bees, fn b ->
        b.job_id != nil and b.status == "working"
      end)
      |> Enum.filter(fn b ->
        case Store.get(:jobs, b.job_id) do
          %{quest_id: ^quest_id} -> true
          _ -> false
        end
      end)

    Enum.each(active_bees, fn bee ->
      Logger.warning("Watchdog killing bee #{bee.id} (Quest #{quest_id} over budget)")
      # Create handoff before stopping so work isn't lost
      try do
        Hive.Handoff.create(bee.id)
      rescue
        _ -> :ok
      end
      # Force-kill: GenServer.call(:stop) can hang if bee is stuck
      case Hive.Bee.Worker.lookup(bee.id) do
        {:ok, pid} ->
          # Give 2s for graceful stop, then kill
          try do
            GenServer.call(pid, :stop, 2_000)
          catch
            :exit, _ -> Process.exit(pid, :kill)
          end
        :error -> :ok
      end
    end)

    update_quest_status(quest.id, "paused_budget")

    Hive.Telemetry.emit([:hive, :alert, :raised], %{}, %{
      type: :budget_paused,
      message: "Quest #{quest.id} paused at $#{spent} (budget exhausted after escalations)"
    })
  end

  defp check_paused_quests do
    # Check if any paused quests now have budget (e.g., manual increase)
    paused = Store.filter(:quests, fn q -> q[:status] == "paused_budget" end)

    Enum.each(paused, fn quest ->
      case Budget.check(quest.id) do
        {:ok, _remaining} ->
          Logger.info("Quest #{quest.id} budget restored, resuming")
          update_quest_status(quest.id, "active")

          # Notify Queen to re-evaluate
          Hive.Waggle.send(
            "watchdog",
            "queen",
            "quest_advance",
            quest.id
          )

        _ ->
          :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp update_quest_status(quest_id, status) do
    case Store.get(:quests, quest_id) do
      nil -> :ok
      quest -> Store.put(:quests, Map.put(quest, :status, status))
    end
  end
end
