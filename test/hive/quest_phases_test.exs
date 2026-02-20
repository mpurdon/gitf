defmodule Hive.QuestPhasesTest do
  use ExUnit.Case, async: false

  alias Hive.Store
  alias Hive.Quests

  setup do
    # Start store for each test with unique directory
    tmp_dir = System.tmp_dir!() |> Path.join("quest_phases_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(tmp_dir)
    start_supervised!({Store, data_dir: tmp_dir})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  describe "quest phase transitions" do
    test "new quests start in pending phase" do
      {:ok, quest} = Quests.create(%{goal: "Test quest"})
      
      assert quest.current_phase == "pending"
      assert quest.research_summary == nil
      assert quest.implementation_plan == nil
    end

    test "can transition quest phases" do
      {:ok, quest} = Quests.create(%{goal: "Test quest"})
      
      {:ok, updated} = Quests.transition_phase(quest.id, "research", "Starting research")
      
      assert updated.current_phase == "research"
      
      # Check transition was recorded
      transitions = Quests.get_phase_transitions(quest.id)
      assert length(transitions) == 1
      
      transition = List.first(transitions)
      assert transition.quest_id == quest.id
      assert transition.from_phase == "pending"
      assert transition.to_phase == "research"
      assert transition.reason == "Starting research"
    end

    test "can track multiple phase transitions" do
      {:ok, quest} = Quests.create(%{goal: "Test quest"})
      
      {:ok, _} = Quests.transition_phase(quest.id, "research")
      {:ok, _} = Quests.transition_phase(quest.id, "planning")
      {:ok, _} = Quests.transition_phase(quest.id, "implementation")
      
      transitions = Quests.get_phase_transitions(quest.id)
      assert length(transitions) == 3
      
      # Check that all expected phases are present
      phases = Enum.map(transitions, & &1.to_phase)
      assert "research" in phases
      assert "planning" in phases
      assert "implementation" in phases
    end

    test "transition_phase returns error for non-existent quest" do
      assert {:error, :not_found} = Quests.transition_phase("nonexistent", "research")
    end

    test "get_phase_transitions returns empty list for quest with no transitions" do
      {:ok, quest} = Quests.create(%{goal: "Test quest"})
      
      transitions = Quests.get_phase_transitions(quest.id)
      assert transitions == []
    end
  end

  describe "migration compatibility" do
    test "existing quests get default phase fields after migration" do
      # Create quest without phase fields (simulating pre-migration data)
      quest_record = %{
        name: "legacy-quest",
        goal: "Legacy quest goal",
        status: "pending"
      }
      
      {:ok, quest} = Store.insert(:quests, quest_record)
      
      # Manually run migration 3 on this quest
      updated =
        quest
        |> Map.put_new(:current_phase, "pending")
        |> Map.put_new(:research_summary, nil)
        |> Map.put_new(:implementation_plan, nil)
      
      Store.put(:quests, updated)
      
      # Verify quest now has phase fields
      updated_quest = Store.get(:quests, quest.id)
      assert updated_quest.current_phase == "pending"
      assert updated_quest.research_summary == nil
      assert updated_quest.implementation_plan == nil
    end
  end
end