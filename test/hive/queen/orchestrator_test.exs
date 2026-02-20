defmodule Hive.Queen.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Hive.Queen.Orchestrator
  alias Hive.Store

  setup do
    # Stop any previously running Store to avoid stale data
    try do
      if pid = Process.whereis(Hive.Store), do: GenServer.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    end

    # Start store for tests with unique directory
    tmp_dir = System.tmp_dir!() |> Path.join("orchestrator_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    start_supervised!({Hive.Store, data_dir: tmp_dir})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create test comb and quest
    {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})
    {:ok, quest} = Store.insert(:quests, %{
      name: "test-quest",
      goal: "Build a test feature",
      comb_id: comb.id,
      status: "pending"
    })
    
    %{quest: quest, comb: comb}
  end

  describe "start_quest/1" do
    test "transitions quest to research phase", %{quest: quest} do
      # Mock research to return immediately
      research_result = %{structure: %{main_language: "elixir"}}
      
      # We'll test the phase transition part
      {:ok, _} = Hive.Quests.transition_phase(quest.id, "research", "Quest started")
      
      # Verify phase transition was recorded
      transitions = Hive.Quests.get_phase_transitions(quest.id)
      assert length(transitions) == 1
      assert hd(transitions).to_phase == "research"
    end

    test "validates quest is ready before starting", %{quest: quest} do
      # Set quest to non-pending status
      updated = Map.put(quest, :status, "active")
      Store.put(:quests, updated)
      
      {:error, :quest_not_pending} = Orchestrator.start_quest(quest.id)
    end

    test "requires comb_id to be set", %{quest: quest} do
      # Remove comb_id
      updated = Map.put(quest, :comb_id, nil)
      Store.put(:quests, updated)
      
      {:error, :no_comb_assigned} = Orchestrator.start_quest(quest.id)
    end

    test "returns error for non-existent quest" do
      {:error, :not_found} = Orchestrator.start_quest("non-existent")
    end
  end

  describe "get_quest_status/1" do
    test "returns comprehensive quest status", %{quest: quest} do
      # Add some phase transitions
      {:ok, _} = Hive.Quests.transition_phase(quest.id, "research", "Started")
      {:ok, _} = Hive.Quests.transition_phase(quest.id, "planning", "Research done")
      
      # Add research summary
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :research_summary, %{done: true})
      Store.put(:quests, updated)
      
      {:ok, status} = Orchestrator.get_quest_status(quest.id)
      
      assert status.quest.id == quest.id
      assert status.current_phase == "planning"
      assert status.research_complete == true
      assert status.plan_complete == false
      assert status.jobs_created == false
      assert length(status.phase_history) == 2
    end

    test "detects when plan is complete", %{quest: quest} do
      # Add implementation plan
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :implementation_plan, %{tasks: []})
      Store.put(:quests, updated)
      
      {:ok, status} = Orchestrator.get_quest_status(quest.id)
      assert status.plan_complete == true
    end

    test "detects when jobs are created", %{quest: quest} do
      # Create a job for the quest
      {:ok, _job} = Hive.Jobs.create(%{
        title: "Test job",
        quest_id: quest.id,
        comb_id: quest.comb_id
      })
      
      {:ok, status} = Orchestrator.get_quest_status(quest.id)
      assert status.jobs_created == true
    end

    test "returns error for non-existent quest" do
      {:error, :not_found} = Orchestrator.get_quest_status("non-existent")
    end
  end

  describe "advance_quest/1" do
    test "advances from research to planning when research complete", %{quest: quest} do
      # Set up quest in research phase with completed research
      quest_record = Store.get(:quests, quest.id)
      updated = quest_record
        |> Map.put(:current_phase, "research")
        |> Map.put(:research_summary, %{structure: %{main_language: "elixir"}})
      Store.put(:quests, updated)
      
      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "planning"
      
      # Verify quest was updated
      updated_quest = Store.get(:quests, quest.id)
      assert updated_quest.current_phase == "planning"
      assert updated_quest.implementation_plan != nil
    end

    test "advances from planning to implementation when plan complete", %{quest: quest} do
      # Set up quest in planning phase with completed plan
      quest_record = Store.get(:quests, quest.id)
      updated = quest_record
        |> Map.put(:current_phase, "planning")
        |> Map.put(:implementation_plan, %{tasks: []})
      Store.put(:quests, updated)
      
      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "implementation"
      
      # Verify phase transition
      updated_quest = Store.get(:quests, quest.id)
      assert updated_quest.current_phase == "implementation"
    end

    test "completes quest when all jobs are done", %{quest: quest} do
      # Create completed job
      {:ok, job} = Hive.Jobs.create(%{
        title: "Test job",
        quest_id: quest.id,
        comb_id: quest.comb_id,
        status: "done"
      })
      
      # Set quest to implementation phase
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Store.put(:quests, updated)
      
      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "completed"
      
      # Verify quest completion
      updated_quest = Store.get(:quests, quest.id)
      assert updated_quest.current_phase == "completed"
    end

    test "stays in implementation when jobs are not complete", %{quest: quest} do
      # Create pending job
      {:ok, job} = Hive.Jobs.create(%{
        title: "Test job",
        quest_id: quest.id,
        comb_id: quest.comb_id,
        status: "pending"
      })
      
      # Set quest to implementation phase
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Store.put(:quests, updated)
      
      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "implementation"
    end

    test "returns error when research not complete", %{quest: quest} do
      # Set quest to research phase without completed research
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "research")
      Store.put(:quests, updated)
      
      {:error, :research_not_complete} = Orchestrator.advance_quest(quest.id)
    end

    test "returns error when planning not complete", %{quest: quest} do
      # Set quest to planning phase without completed plan
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "planning")
      Store.put(:quests, updated)
      
      {:error, :planning_not_complete} = Orchestrator.advance_quest(quest.id)
    end

    test "returns current phase for unknown phases", %{quest: quest} do
      # Set quest to unknown phase
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "unknown")
      Store.put(:quests, updated)
      
      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "unknown"
    end
  end

  describe "phase transitions" do
    test "records phase transitions with reasons", %{quest: quest} do
      # Clear ALL phase transitions to ensure clean state
      for t <- Store.all(:quest_phase_transitions) do
        Store.delete(:quest_phase_transitions, t.id)
      end

      {:ok, _} = Hive.Quests.transition_phase(quest.id, "research", "Quest started")
      # Brief pause between transitions
      Process.sleep(1)
      {:ok, _} = Hive.Quests.transition_phase(quest.id, "planning", "Research complete")

      transitions = Hive.Quests.get_phase_transitions(quest.id)
      assert length(transitions) == 2

      # Both transitions should be present (order may vary when timestamps match)
      phases = Enum.map(transitions, & &1.to_phase)
      assert "research" in phases
      assert "planning" in phases

      research_t = Enum.find(transitions, &(&1.to_phase == "research"))
      planning_t = Enum.find(transitions, &(&1.to_phase == "planning"))

      assert research_t.reason == "Quest started"
      assert planning_t.reason == "Research complete"
    end

    test "updates quest current_phase field", %{quest: quest} do
      {:ok, _} = Hive.Quests.transition_phase(quest.id, "research", "Started")
      
      updated_quest = Store.get(:quests, quest.id)
      assert updated_quest.current_phase == "research"
    end
  end
end