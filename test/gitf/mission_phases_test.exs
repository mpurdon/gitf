defmodule GiTF.QuestPhasesTest do
  use ExUnit.Case, async: false

  alias GiTF.Archive
  alias GiTF.Missions

  setup do
    # Start store for each test with unique directory
    tmp_dir = System.tmp_dir!() |> Path.join("mission_phases_test_#{:rand.uniform(1000000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: tmp_dir})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    :ok
  end

  describe "mission phase transitions" do
    test "new missions start in pending phase" do
      {:ok, mission} = Quests.create(%{goal: "Test mission"})
      
      assert mission.current_phase == "pending"
      assert mission.research_summary == nil
      assert mission.implementation_plan == nil
    end

    test "can transition mission phases" do
      {:ok, mission} = Quests.create(%{goal: "Test mission"})
      
      {:ok, updated} = Quests.transition_phase(mission.id, "research", "Starting research")
      
      assert updated.current_phase == "research"
      
      # Check transition was recorded
      transitions = Quests.get_phase_transitions(mission.id)
      assert length(transitions) == 1
      
      transition = List.first(transitions)
      assert transition.mission_id == mission.id
      assert transition.from_phase == "pending"
      assert transition.to_phase == "research"
      assert transition.reason == "Starting research"
    end

    test "can track multiple phase transitions" do
      {:ok, mission} = Quests.create(%{goal: "Test mission"})
      
      {:ok, _} = Quests.transition_phase(mission.id, "research")
      {:ok, _} = Quests.transition_phase(mission.id, "planning")
      {:ok, _} = Quests.transition_phase(mission.id, "implementation")
      
      transitions = Quests.get_phase_transitions(mission.id)
      assert length(transitions) == 3
      
      # Check that all expected phases are present
      phases = Enum.map(transitions, & &1.to_phase)
      assert "research" in phases
      assert "planning" in phases
      assert "implementation" in phases
    end

    test "transition_phase returns error for non-existent mission" do
      assert {:error, :not_found} = Quests.transition_phase("nonexistent", "research")
    end

    test "get_phase_transitions returns empty list for mission with no transitions" do
      {:ok, mission} = Quests.create(%{goal: "Test mission"})
      
      transitions = Quests.get_phase_transitions(mission.id)
      assert transitions == []
    end
  end

  describe "migration compatibility" do
    test "existing missions get default phase fields after migration" do
      # Create mission without phase fields (simulating pre-migration data)
      quest_record = %{
        name: "legacy-mission",
        goal: "Legacy mission goal",
        status: "pending"
      }
      
      {:ok, mission} = Archive.insert(:missions, quest_record)
      
      # Manually run migration 3 on this mission
      updated =
        mission
        |> Map.put_new(:current_phase, "pending")
        |> Map.put_new(:research_summary, nil)
        |> Map.put_new(:implementation_plan, nil)
      
      Archive.put(:missions, updated)
      
      # Verify mission now has phase fields
      updated_quest = Archive.get(:missions, mission.id)
      assert updated_quest.current_phase == "pending"
      assert updated_quest.research_summary == nil
      assert updated_quest.implementation_plan == nil
    end
  end
end