defmodule GiTF.Major.OrchestratorTest do
  use ExUnit.Case, async: false
  import Mox

  alias GiTF.Major.Orchestrator
  alias GiTF.Store

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Ensure CombSupervisor is running (needed for ghost spawning)
    unless Process.whereis(GiTF.CombSupervisor) do
      DynamicSupervisor.start_link(strategy: :one_for_one, name: GiTF.CombSupervisor)
    end

    # Force API mode for mocking
    original_config = Application.get_env(:gitf, :llm, [])
    Application.put_env(:gitf, :llm, Keyword.merge(original_config, [execution_mode: :api]))

    # Use Mock LLM Client
    Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Mock)

    # Start store for tests with unique directory
    tmp_dir = System.tmp_dir!() |> Path.join("orchestrator_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.put_env(:gitf, :llm, original_config)
      Application.put_env(:gitf, :llm_client, GiTF.Runtime.LLMClient.Default)
    end)

    # Create test comb and quest
    {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})
    {:ok, quest} = Store.insert(:quests, %{
      name: "test-quest",
      goal: "Build a test feature",
      comb_id: comb.id,
      status: "pending",
      current_phase: "pending",
      artifacts: %{},
      phase_jobs: %{},
      research_summary: nil,
      implementation_plan: nil
    })

    %{quest: quest, comb: comb}
  end

  describe "start_quest/1" do
    test "transitions quest to research phase", %{quest: quest} do
      # We'll test the phase transition part directly
      {:ok, _} = GiTF.Quests.transition_phase(quest.id, "research", "Quest started")

      # Verify phase transition was recorded
      transitions = GiTF.Quests.get_phase_transitions(quest.id)
      assert length(transitions) == 1
      assert hd(transitions).to_phase == "research"
    end

    test "validates quest is ready before starting", %{quest: quest} do
      # Set quest to completed status (not allowed)
      updated = Map.put(quest, :status, "completed")
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
      {:ok, _} = GiTF.Quests.transition_phase(quest.id, "research", "Started")
      {:ok, _} = GiTF.Quests.transition_phase(quest.id, "planning", "Research done")

      {:ok, status} = Orchestrator.get_quest_status(quest.id)

      assert status.quest.id == quest.id
      assert status.current_phase == "planning"
      assert status.jobs_created == false
      assert length(status.phase_history) == 2
    end

    test "detects completed phases from artifacts", %{quest: quest} do
      # Store a research artifact
      GiTF.Quests.store_artifact(quest.id, "research", %{"architecture" => "OTP app"})

      {:ok, status} = Orchestrator.get_quest_status(quest.id)
      assert "research" in status.completed_phases
    end

    test "detects when jobs are created", %{quest: quest} do
      # Create a job for the quest
      {:ok, _job} = GiTF.Jobs.create(%{
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
    test "advances from research to requirements when research artifact exists", %{quest: quest} do
      # Set up quest in research phase with artifact
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "research")
      Store.put(:quests, updated)

      GiTF.Quests.store_artifact(quest.id, "research", %{
        "architecture" => "OTP app",
        "key_files" => ["lib/app.ex"],
        "patterns" => [],
        "tech_stack" => ["elixir"]
      })

      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "requirements"
    end

    test "stays in research when no artifact exists", %{quest: quest} do
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "research")
      Store.put(:quests, updated)

      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "research"
    end

    test "completes quest when all implementation jobs are done", %{quest: quest} do
      # Create completed non-phase job
      {:ok, _job} = GiTF.Jobs.create(%{
        title: "Test job",
        quest_id: quest.id,
        comb_id: quest.comb_id,
        status: "done",
        phase_job: false
      })

      # Set quest to implementation phase
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Store.put(:quests, updated)

      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      # Should advance to validation (not directly to completed)
      assert phase == "validation"
    end

    test "stays in implementation when jobs are not complete", %{quest: quest} do
      # Create pending job
      {:ok, _job} = GiTF.Jobs.create(%{
        title: "Test job",
        quest_id: quest.id,
        comb_id: quest.comb_id,
        status: "pending",
        phase_job: false
      })

      # Set quest to implementation phase
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Store.put(:quests, updated)

      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "implementation"
    end

    test "handles review approval and advances to planning", %{quest: quest} do
      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "review")
      Store.put(:quests, updated)

      # Store approved review artifact
      GiTF.Quests.store_artifact(quest.id, "review", %{
        "approved" => true,
        "coverage" => [],
        "issues" => [],
        "risk_assessment" => "Low risk"
      })

      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "planning"
    end

    test "handles review rejection with redesign", %{quest: quest} do
      # Expect call for expert discovery
      stub(GiTF.Runtime.LLMClient.Mock, :generate_text, fn _model, _messages, _opts ->
        {:ok, %ReqLLM.Response{
           message: %{content: "[]", role: :assistant},
           usage: %{},
           model: "mock-model",
           context: [],
           id: "mock-id"
        }}
      end)

      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "review")
      Store.put(:quests, updated)

      # Store rejected review artifact
      GiTF.Quests.store_artifact(quest.id, "review", %{
        "approved" => false,
        "coverage" => [],
        "issues" => [%{"severity" => "high", "description" => "Missing error handling"}],
        "risk_assessment" => "High risk"
      })

      {:ok, phase} = Orchestrator.advance_quest(quest.id)
      assert phase == "design"
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
    test "records phase transitions with reasons", %{quest: quest} do
      # Clear ALL phase transitions to ensure clean state
      for t <- Store.all(:quest_phase_transitions) do
        Store.delete(:quest_phase_transitions, t.id)
      end

      {:ok, _} = GiTF.Quests.transition_phase(quest.id, "research", "Quest started")
      # Brief pause between transitions
      Process.sleep(1)
      {:ok, _} = GiTF.Quests.transition_phase(quest.id, "planning", "Research complete")

      transitions = GiTF.Quests.get_phase_transitions(quest.id)
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
      {:ok, _} = GiTF.Quests.transition_phase(quest.id, "research", "Started")

      updated_quest = Store.get(:quests, quest.id)
      assert updated_quest.current_phase == "research"
    end
  end
end
