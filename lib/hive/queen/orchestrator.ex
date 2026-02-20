defmodule Hive.Queen.Orchestrator do
  @moduledoc """
  Queen's orchestration capabilities for Phase 2.4.
  
  Manages phase transitions and coordinates the full workflow:
  research → planning → implementation
  """

  alias Hive.Store
  alias Hive.Queen.Research
  alias Hive.Queen.Planner

  @doc """
  Start a quest workflow.
  
  Initiates research phase and sets up phase transition tracking.
  """
  @spec start_quest(String.t()) :: {:ok, map()} | {:error, term()}
  def start_quest(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id),
         :ok <- validate_quest_ready(quest),
         {:ok, _} <- Hive.Quests.transition_phase(quest_id, "research", "Quest started") do
      
      # Start research phase
      case Research.research_comb(quest.comb_id) do
        {:ok, research} ->
          # Store research summary
          quest_record = Store.get(:quests, quest_id)
          updated = Map.put(quest_record, :research_summary, research)
          Store.put(:quests, updated)
          
          # Transition to planning
          transition_to_planning(quest_id, research)
          
        {:error, reason} ->
          {:error, {:research_failed, reason}}
      end
    end
  end

  @doc """
  Get quest status with phase information.
  """
  @spec get_quest_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_quest_status(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      transitions = Hive.Quests.get_phase_transitions(quest_id)
      
      status = %{
        quest: quest,
        current_phase: Map.get(quest, :current_phase, "pending"),
        phase_history: transitions,
        research_complete: not is_nil(Map.get(quest, :research_summary)),
        plan_complete: not is_nil(Map.get(quest, :implementation_plan)),
        jobs_created: length(quest.jobs) > 0
      }
      
      {:ok, status}
    end
  end

  @doc """
  Advance quest to next phase if current phase is complete.
  """
  @spec advance_quest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def advance_quest(quest_id) do
    with {:ok, quest} <- Hive.Quests.get(quest_id) do
      current_phase = Map.get(quest, :current_phase, "pending")
      
      case current_phase do
        "research" ->
          if Map.get(quest, :research_summary) do
            transition_to_planning(quest_id, quest.research_summary)
          else
            {:error, :research_not_complete}
          end
          
        "planning" ->
          if Map.get(quest, :implementation_plan) do
            transition_to_implementation(quest_id)
          else
            {:error, :planning_not_complete}
          end
          
        "implementation" ->
          if all_jobs_complete?(quest.jobs) do
            complete_quest(quest_id)
          else
            {:ok, "implementation"}
          end
          
        phase ->
          {:ok, phase}
      end
    end
  end

  # Private helpers

  defp validate_quest_ready(quest) do
    cond do
      is_nil(quest.comb_id) -> {:error, :no_comb_assigned}
      quest.status != "pending" -> {:error, :quest_not_pending}
      true -> :ok
    end
  end

  defp transition_to_planning(quest_id, research_summary) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest_id, "planning", "Research complete"),
         {:ok, plan} <- Planner.generate_plan(quest_id, research_summary),
         {:ok, jobs} <- Planner.create_jobs_from_plan(quest_id, plan) do
      
      # Update quest status
      Hive.Quests.update_status!(quest_id)
      
      {:ok, "planning"}
    end
  end

  defp transition_to_implementation(quest_id) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest_id, "implementation", "Planning complete"),
         {:ok, quest} <- Hive.Quests.get(quest_id) do
      
      # Spawn bees for ready jobs
      spawn_ready_jobs(quest)
      
      # Update quest status
      Hive.Quests.update_status!(quest_id)
      
      {:ok, "implementation"}
    end
  end

  defp complete_quest(quest_id) do
    with {:ok, _} <- Hive.Quests.transition_phase(quest_id, "completed", "All jobs complete") do
      Hive.Quests.update_status!(quest_id)
      {:ok, "completed"}
    end
  end

  defp spawn_ready_jobs(quest) do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        quest.jobs
        |> Enum.filter(&(&1.status == "pending"))
        |> Enum.filter(&Hive.Jobs.ready?(&1.id))
        |> Enum.each(fn job ->
          case Hive.Bees.spawn(job.id, job.comb_id, hive_root) do
            {:ok, bee} ->
              :ok
            {:error, reason} ->
              :ok # Log but don't fail the transition
          end
        end)
      
      {:error, _} ->
        :ok
    end
  end

  defp all_jobs_complete?(jobs) do
    jobs != [] and Enum.all?(jobs, &(&1.status == "done"))
  end
end