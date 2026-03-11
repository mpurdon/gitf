defmodule GiTF.Major.PlannerMultiPlanTest do
  use ExUnit.Case, async: false

  alias GiTF.Major.Planner
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "planner_multi_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} = Archive.insert(:sectors, %{name: "test-sector", path: "/tmp/test"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "test-mission",
        goal: "Build a feature",
        sector_id: sector.id,
        status: "active",
        current_phase: "planning",
        artifacts: %{},
        phase_jobs: %{}
      })

    %{mission: mission, sector: sector}
  end

  describe "score_plan/1" do
    test "scores empty plan as 0" do
      assert Planner.score_plan(%{tasks: []}) == 0.0
    end

    test "scores plan with tasks" do
      plan = %{
        tasks: [
          %{
            "title" => "Setup",
            "description" => "Initialize",
            "depends_on_indices" => [],
            "model_recommendation" => "haiku"
          },
          %{
            "title" => "Implement feature",
            "description" => "Core implementation",
            "depends_on_indices" => [0],
            "model_recommendation" => "sonnet"
          },
          %{
            "title" => "Add tests",
            "description" => "Write tests",
            "depends_on_indices" => [1],
            "model_recommendation" => "haiku"
          }
        ]
      }

      score = Planner.score_plan(plan)
      assert is_float(score)
      assert score > 0.0
      assert score <= 1.0
    end

    test "scores plans with more parallelism higher" do
      # Serial plan
      serial = %{
        tasks: [
          %{
            "title" => "Task 1",
            "depends_on_indices" => [],
            "model_recommendation" => "sonnet"
          },
          %{
            "title" => "Task 2",
            "depends_on_indices" => [0],
            "model_recommendation" => "sonnet"
          },
          %{
            "title" => "Task 3",
            "depends_on_indices" => [1],
            "model_recommendation" => "sonnet"
          }
        ]
      }

      # Parallel plan
      parallel = %{
        tasks: [
          %{
            "title" => "Task 1",
            "depends_on_indices" => [],
            "model_recommendation" => "sonnet"
          },
          %{
            "title" => "Task 2",
            "depends_on_indices" => [],
            "model_recommendation" => "sonnet"
          },
          %{
            "title" => "Task 3",
            "depends_on_indices" => [],
            "model_recommendation" => "sonnet"
          }
        ]
      }

      serial_score = Planner.score_plan(serial)
      parallel_score = Planner.score_plan(parallel)

      # Parallel should score higher (more parallelism)
      assert parallel_score > serial_score
    end

    test "cheaper plans score higher on cost dimension" do
      cheap = %{
        tasks: [
          %{
            "title" => "Task 1",
            "depends_on_indices" => [],
            "model_recommendation" => "haiku"
          }
        ]
      }

      expensive = %{
        tasks: [
          %{
            "title" => "Task 1",
            "depends_on_indices" => [],
            "model_recommendation" => "opus"
          }
        ]
      }

      cheap_score = Planner.score_plan(cheap)
      expensive_score = Planner.score_plan(expensive)
      assert cheap_score > expensive_score
    end
  end

  describe "select_fallback_plan/1" do
    test "returns error when no candidates exist", %{mission: mission} do
      assert {:error, :no_fallback} == Planner.select_fallback_plan(mission.id)
    end

    test "returns next untried candidate", %{mission: mission} do
      # Archive plan candidates on mission
      quest_record = Archive.get(:missions, mission.id)

      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: [%{"title" => "Minimal task"}]},
        %{strategy: "normal", score: 0.8, tasks: [%{"title" => "Normal task"}]},
        %{strategy: "complex", score: 0.7, tasks: [%{"title" => "Complex task"}]}
      ]

      updated =
        quest_record
        |> Map.put(:plan_candidates, candidates)
        |> Map.put(:tried_plans, [%{strategy: "normal"}])

      Archive.put(:missions, updated)

      {:ok, fallback} = Planner.select_fallback_plan(mission.id)
      # Should return complex (0.7) since normal was tried
      assert fallback.strategy == "complex"
    end

    test "returns error when all candidates tried", %{mission: mission} do
      quest_record = Archive.get(:missions, mission.id)

      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: []},
        %{strategy: "normal", score: 0.8, tasks: []}
      ]

      updated =
        quest_record
        |> Map.put(:plan_candidates, candidates)
        |> Map.put(:tried_plans, [
          %{strategy: "minimal"},
          %{strategy: "normal"}
        ])

      Archive.put(:missions, updated)

      assert {:error, :no_fallback} == Planner.select_fallback_plan(mission.id)
    end
  end

  describe "strategy_instruction/2" do
    test "returns empty string for nil name" do
      assert Planner.strategy_instruction(nil, nil) == ""
    end

    test "returns instruction with name and hint" do
      result = Planner.strategy_instruction("minimal", "Bare-minimum impl")
      assert result =~ "minimal"
      assert result =~ "Bare-minimum impl"
      assert result =~ "STRATEGY:"
    end

    test "works with alternative approach names" do
      result = Planner.strategy_instruction("electron", "Cross-platform Electron app")
      assert result =~ "electron"
      assert result =~ "Cross-platform Electron app"
    end

    test "returns empty string when hint is not a string" do
      assert Planner.strategy_instruction("minimal", nil) == ""
    end
  end

  describe "orchestrator fallback integration" do
    test "stays in implementation when less than 50% failed", %{mission: mission, sector: sector} do
      # 1 done, 1 failed = 50% (not >50%)
      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Done op",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "done",
          phase_job: false
        })

      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Failed op",
          mission_id: mission.id,
          sector_id: sector.id,
          status: "failed",
          phase_job: false
        })

      quest_record = Archive.get(:missions, mission.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Archive.put(:missions, updated)

      {:ok, phase} = GiTF.Major.Orchestrator.advance_quest(mission.id)
      assert phase == "implementation"
    end
  end
end
