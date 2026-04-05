defmodule GiTF.Major.OrchestratorTest do
  use GiTF.StoreCase
  import Mox

  alias GiTF.Major.Orchestrator
  alias GiTF.Archive

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    # Ensure SectorSupervisor is running (needed for ghost spawning)
    unless Process.whereis(GiTF.SectorSupervisor) do
      DynamicSupervisor.start_link(strategy: :one_for_one, name: GiTF.SectorSupervisor)
    end

    # Force API mode for mocking
    original_config = Application.get_env(:gitf, :llm, [])
    Application.put_env(:gitf, :llm, Keyword.merge(original_config, execution_mode: :api))

    # Use Mock LLM Client
    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)

    on_exit(fn ->
      Application.put_env(:gitf, :llm, original_config)
      Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Default)
    end)

    # Create test sector and mission
    {:ok, sector} = Archive.insert(:sectors, %{name: "test-sector", path: "/tmp/test"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "test-mission",
        goal: "Build a test feature",
        sector_id: sector.id,
        status: "pending",
        current_phase: "pending",
        artifacts: %{},
        phase_jobs: %{},
        research_summary: nil,
        implementation_plan: nil
      })

    %{mission: mission, sector: sector}
  end

  describe "start_quest/1" do
    test "transitions mission to research phase", %{mission: mission} do
      # We'll test the phase transition part directly
      {:ok, _} = GiTF.Missions.transition_phase(mission.id, "research", "Quest started")

      # Verify phase transition was recorded
      transitions = GiTF.Missions.get_phase_transitions(mission.id)
      assert length(transitions) == 1
      assert hd(transitions).to_phase == "research"
    end

    test "validates mission is ready before starting", %{mission: mission} do
      # Set mission to completed status (not allowed)
      updated = Map.put(mission, :status, "completed")
      Archive.put(:missions, updated)

      {:error, :mission_not_pending} = Orchestrator.start_quest(mission.id)
    end

    test "auto-assigns sector when sector_id is nil and a sector exists", %{mission: mission} do
      # Remove sector_id
      updated = Map.put(mission, :sector_id, nil)
      Archive.put(:missions, updated)

      # Should auto-assign the available sector and proceed
      {:ok, _phase} = Orchestrator.start_quest(mission.id)

      # Verify sector was assigned
      {:ok, refreshed} = GiTF.Missions.get(mission.id)
      assert refreshed.sector_id != nil
    end

    test "returns error for non-existent mission" do
      {:error, :not_found} = Orchestrator.start_quest("non-existent")
    end
  end

  describe "get_quest_status/1" do
    test "returns comprehensive mission status", %{mission: mission} do
      # Add some phase transitions
      {:ok, _} = GiTF.Missions.transition_phase(mission.id, "research", "Started")
      {:ok, _} = GiTF.Missions.transition_phase(mission.id, "planning", "Research done")

      {:ok, status} = Orchestrator.get_quest_status(mission.id)

      assert status.mission.id == mission.id
      assert status.current_phase == "planning"
      assert status.jobs_created == false
      assert length(status.phase_history) == 2
    end

    test "detects completed phases from artifacts", %{mission: mission} do
      # Archive a research artifact
      GiTF.Missions.store_artifact(mission.id, "research", %{"architecture" => "OTP app"})

      {:ok, status} = Orchestrator.get_quest_status(mission.id)
      assert "research" in status.completed_phases
    end

    test "detects when ops are created", %{mission: mission} do
      # Create a op for the mission
      {:ok, _job} =
        GiTF.Ops.create(%{
          title: "Test op",
          mission_id: mission.id,
          sector_id: mission.sector_id
        })

      {:ok, status} = Orchestrator.get_quest_status(mission.id)
      assert status.jobs_created == true
    end

    test "returns error for non-existent mission" do
      {:error, :not_found} = Orchestrator.get_quest_status("non-existent")
    end
  end

  describe "advance_quest/1" do
    test "advances from research to requirements when research artifact exists", %{
      mission: mission
    } do
      # Set up mission in research phase with artifact
      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "research")
      Archive.put(:missions, updated)

      GiTF.Missions.store_artifact(mission.id, "research", %{
        "architecture" => "OTP app",
        "key_files" => ["lib/app.ex"],
        "patterns" => [],
        "tech_stack" => ["elixir"]
      })

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      assert phase == "requirements"
    end

    test "stays in research when no artifact exists", %{mission: mission} do
      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "research")
      Archive.put(:missions, updated)

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      assert phase == "research"
    end

    test "completes mission when all implementation ops are done", %{mission: mission} do
      # Create completed non-phase op
      {:ok, _job} =
        GiTF.Ops.create(%{
          title: "Test op",
          mission_id: mission.id,
          sector_id: mission.sector_id,
          status: "done",
          phase_job: false
        })

      # Set mission to implementation phase
      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Archive.put(:missions, updated)

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      # Should advance to validation (not directly to completed)
      assert phase == "validation"
    end

    test "stays in implementation when ops are not complete", %{mission: mission} do
      # Create pending op
      {:ok, _job} =
        GiTF.Ops.create(%{
          title: "Test op",
          mission_id: mission.id,
          sector_id: mission.sector_id,
          status: "pending",
          phase_job: false
        })

      # Set mission to implementation phase
      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Archive.put(:missions, updated)

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      assert phase == "implementation"
    end

    test "handles review approval and advances to planning", %{mission: mission} do
      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "review")
      Archive.put(:missions, updated)

      # Archive approved review artifact
      GiTF.Missions.store_artifact(mission.id, "review", %{
        "approved" => true,
        "coverage" => [],
        "issues" => [],
        "risk_assessment" => "Low risk"
      })

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      assert phase == "planning"
    end

    test "handles review rejection with redesign", %{mission: mission} do
      # Expect call for expert discovery
      stub(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _model, _messages, _opts ->
        {:ok,
         %ReqLLM.Response{
           message: %{content: "[]", role: :assistant},
           usage: %{},
           model: "mock-model",
           context: [],
           id: "mock-id"
         }}
      end)

      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "review")
      Archive.put(:missions, updated)

      # Archive rejected review artifact
      GiTF.Missions.store_artifact(mission.id, "review", %{
        "approved" => false,
        "coverage" => [],
        "issues" => [%{"severity" => "high", "description" => "Missing error handling"}],
        "risk_assessment" => "High risk"
      })

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      assert phase == "design"
    end

    test "returns current phase for unknown phases", %{mission: mission} do
      # Set mission to unknown phase
      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "unknown")
      Archive.put(:missions, updated)

      {:ok, phase} = Orchestrator.advance_quest(mission.id)
      assert phase == "unknown"
    end
  end

  describe "phases/0" do
    test "returns ordered phase list" do
      phases = Orchestrator.phases()
      assert "research" in phases
      assert "requirements" in phases
      assert "design" in phases
      assert "review" in phases
      assert "planning" in phases
      assert "implementation" in phases
      assert "validation" in phases
    end
  end

  describe "phase transitions" do
    test "records phase transitions with reasons", %{mission: mission} do
      # Clear ALL phase transitions to ensure clean state
      for t <- Archive.all(:mission_phase_transitions) do
        Archive.delete(:mission_phase_transitions, t.id)
      end

      {:ok, _} = GiTF.Missions.transition_phase(mission.id, "research", "Quest started")
      # Brief pause between transitions
      Process.sleep(1)
      {:ok, _} = GiTF.Missions.transition_phase(mission.id, "planning", "Research complete")

      transitions = GiTF.Missions.get_phase_transitions(mission.id)
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

    test "updates mission current_phase field", %{mission: mission} do
      {:ok, _} = GiTF.Missions.transition_phase(mission.id, "research", "Started")

      updated_quest = Archive.get(:missions, mission.id)
      assert updated_quest.current_phase == "research"
    end
  end
end
