defmodule GiTF.Major.PlannerTest do
  use ExUnit.Case, async: false

  alias GiTF.Major.Planner
  alias GiTF.Archive

  setup do
    # Start store for tests with unique directory
    tmp_dir = System.tmp_dir!() |> Path.join("planner_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({GiTF.Archive, data_dir: tmp_dir})
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create test mission and sector
    {:ok, sector} = Archive.insert(:sectors, %{name: "test-sector", path: "/tmp/test"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "test-mission",
        goal: "Build a test feature",
        sector_id: sector.id
      })

    research_summary = %{
      structure: %{
        main_language: "elixir",
        total_files: 50,
        file_types: %{".ex" => 30, ".exs" => 10}
      }
    }

    %{mission: mission, sector: sector, research_summary: research_summary}
  end

  describe "generate_plan/2" do
    test "creates implementation plan from research summary", %{
      mission: mission,
      research_summary: research
    } do
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      assert plan.mission_id == mission.id
      assert plan.goal == mission.goal
      assert plan.research_input == research
      assert is_list(plan.tasks)
      assert length(plan.tasks) >= 2
      assert plan.verification_strategy == "automated_testing"
      assert %DateTime{} = plan.created_at
    end

    test "stores plan in mission record", %{mission: mission, research_summary: research} do
      {:ok, _plan} = Planner.generate_plan(mission.id, research)

      updated_quest = Archive.get(:missions, mission.id)
      assert updated_quest.implementation_plan != nil
      assert updated_quest.implementation_plan.mission_id == mission.id
    end

    test "generates language-specific tasks for elixir", %{
      mission: mission,
      research_summary: research
    } do
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      task_titles = Enum.map(plan.tasks, & &1.title)
      assert "Add tests" in task_titles
    end

    test "generates language-specific tasks for javascript", %{mission: mission} do
      research = %{structure: %{main_language: "javascript"}}
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      task_titles = Enum.map(plan.tasks, & &1.title)
      assert "Add tests" in task_titles
    end

    test "generates generic tasks for unknown language", %{mission: mission} do
      research = %{structure: %{main_language: "unknown"}}
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      task_titles = Enum.map(plan.tasks, & &1.title)
      assert "Add validation" in task_titles
    end

    test "returns error for non-existent mission" do
      {:error, :not_found} = Planner.generate_plan("non-existent", %{})
    end
  end

  describe "create_jobs_from_plan/2" do
    test "creates op records from plan tasks", %{mission: mission, research_summary: research} do
      {:ok, plan} = Planner.generate_plan(mission.id, research)
      {:ok, ops} = Planner.create_jobs_from_plan(mission.id, plan)

      assert length(ops) == length(plan.tasks)

      Enum.each(ops, fn op ->
        assert op.mission_id == mission.id
        assert op.sector_id == mission.sector_id
        assert op.op_type != nil
        assert op.complexity != nil
        assert op.recommended_model != nil
        assert is_list(op.verification_criteria)
        assert is_integer(op.estimated_context_tokens)
      end)
    end

    test "assigns correct op types based on task type", %{
      mission: mission,
      research_summary: research
    } do
      {:ok, plan} = Planner.generate_plan(mission.id, research)
      {:ok, ops} = Planner.create_jobs_from_plan(mission.id, plan)

      # Jobs are classified by the Classifier based on title keywords
      setup_job = Enum.find(ops, &(&1.title == "Setup and preparation"))
      # Could be either based on classification
      assert setup_job.op_type in [:implementation, :simple_fix]

      # Find the "Add tests" op which should be verification
      test_job = Enum.find(ops, &String.contains?(&1.title, "tests"))

      if test_job do
        assert test_job.op_type == :audit
      end
    end

    test "creates ops with verification criteria", %{mission: mission, research_summary: research} do
      {:ok, plan} = Planner.generate_plan(mission.id, research)
      {:ok, ops} = Planner.create_jobs_from_plan(mission.id, plan)

      Enum.each(ops, fn op ->
        assert is_list(op.verification_criteria)
        assert length(op.verification_criteria) > 0
      end)
    end

    test "creates sequential dependencies between ops", %{
      mission: mission,
      research_summary: research
    } do
      {:ok, plan} = Planner.generate_plan(mission.id, research)
      {:ok, ops} = Planner.create_jobs_from_plan(mission.id, plan)

      # Check that ops have dependencies (except the first one)
      [first_op | _rest_ops] = ops

      # First op should have no dependencies
      assert GiTF.Ops.dependencies(first_op.id) == []

      # Each subsequent op should depend on the previous one
      Enum.reduce(ops, nil, fn op, prev_job ->
        if prev_job do
          deps = GiTF.Ops.dependencies(op.id)
          assert length(deps) >= 1
          assert Enum.any?(deps, &(&1.id == prev_job.id))
        end

        op
      end)
    end

    test "returns error for non-existent mission" do
      plan = %{tasks: []}
      {:error, :not_found} = Planner.create_jobs_from_plan("non-existent", plan)
    end
  end

  describe "task generation" do
    test "always includes setup and core implementation tasks", %{mission: mission} do
      research = %{structure: %{main_language: "unknown"}}
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      task_titles = Enum.map(plan.tasks, & &1.title)
      assert "Setup and preparation" in task_titles
      assert "Core implementation" in task_titles
    end

    test "includes verification criteria for all tasks", %{
      mission: mission,
      research_summary: research
    } do
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      Enum.each(plan.tasks, fn task ->
        assert is_list(task.verification_criteria)
        assert length(task.verification_criteria) > 0
      end)
    end

    test "includes token estimates for all tasks", %{mission: mission, research_summary: research} do
      {:ok, plan} = Planner.generate_plan(mission.id, research)

      Enum.each(plan.tasks, fn task ->
        assert is_integer(task.estimated_tokens)
        assert task.estimated_tokens > 0
      end)
    end
  end

  describe "create_jobs_from_specs/3 — tournament variant" do
    test "tags every op with the supplied variant id", %{mission: mission} do
      specs = [
        %{"title" => "Step one", "description" => "do it", "target_files" => ["a.ex"]},
        %{"title" => "Step two", "description" => "more", "target_files" => ["b.ex"]}
      ]

      {:ok, ops} = Planner.create_jobs_from_specs(mission.id, specs, variant: "v1")

      assert length(ops) == 2
      assert Enum.all?(ops, &(&1.variant == "v1"))
      assert Enum.all?(ops, &String.starts_with?(&1.title, "[v1] "))
    end

    test "no variant key when called without the option", %{mission: mission} do
      {:ok, [op]} =
        Planner.create_jobs_from_specs(mission.id, [
          %{"title" => "Solo", "description" => "x", "target_files" => ["c.ex"]}
        ])

      assert op.variant == nil
      refute String.starts_with?(op.title, "[")
    end
  end

  describe "create_jobs_for_variants/3 — tournament fan-out" do
    test "creates an independent op set per variant id", %{mission: mission} do
      specs = [
        %{"title" => "Step", "description" => "x", "target_files" => ["a.ex"]}
      ]

      {:ok, by_variant} = Planner.create_jobs_for_variants(mission.id, specs, ["v1", "v2"])

      assert Map.keys(by_variant) |> Enum.sort() == ["v1", "v2"]
      assert [v1_op] = by_variant["v1"]
      assert [v2_op] = by_variant["v2"]
      assert v1_op.variant == "v1"
      assert v2_op.variant == "v2"
      # Distinct op records, not the same one.
      assert v1_op.id != v2_op.id
    end
  end
end
