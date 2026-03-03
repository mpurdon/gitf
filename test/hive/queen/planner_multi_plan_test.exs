defmodule Hive.Queen.PlannerMultiPlanTest do
  use ExUnit.Case, async: false

  alias Hive.Queen.Planner
  alias Hive.Store

  setup do
    Hive.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "planner_multi_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "test-quest",
        goal: "Build a feature",
        comb_id: comb.id,
        status: "active",
        current_phase: "planning",
        artifacts: %{},
        phase_jobs: %{}
      })

    %{quest: quest, comb: comb}
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
    test "returns error when no candidates exist", %{quest: quest} do
      assert {:error, :no_fallback} == Planner.select_fallback_plan(quest.id)
    end

    test "returns next untried candidate", %{quest: quest} do
      # Store plan candidates on quest
      quest_record = Store.get(:quests, quest.id)

      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: [%{"title" => "Minimal task"}]},
        %{strategy: "balanced", score: 0.8, tasks: [%{"title" => "Balanced task"}]},
        %{strategy: "thorough", score: 0.7, tasks: [%{"title" => "Thorough task"}]}
      ]

      updated =
        quest_record
        |> Map.put(:plan_candidates, candidates)
        |> Map.put(:tried_plans, [%{strategy: "balanced"}])

      Store.put(:quests, updated)

      {:ok, fallback} = Planner.select_fallback_plan(quest.id)
      # Should return thorough (0.7) since balanced was tried
      assert fallback.strategy == "thorough"
    end

    test "returns error when all candidates tried", %{quest: quest} do
      quest_record = Store.get(:quests, quest.id)

      candidates = [
        %{strategy: "minimal", score: 0.6, tasks: []},
        %{strategy: "balanced", score: 0.8, tasks: []}
      ]

      updated =
        quest_record
        |> Map.put(:plan_candidates, candidates)
        |> Map.put(:tried_plans, [
          %{strategy: "minimal"},
          %{strategy: "balanced"}
        ])

      Store.put(:quests, updated)

      assert {:error, :no_fallback} == Planner.select_fallback_plan(quest.id)
    end
  end

  describe "orchestrator fallback integration" do
    test "stays in implementation when less than 50% failed", %{quest: quest, comb: comb} do
      # 1 done, 1 failed = 50% (not >50%)
      {:ok, _} =
        Hive.Jobs.create(%{
          title: "Done job",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "done",
          phase_job: false
        })

      {:ok, _} =
        Hive.Jobs.create(%{
          title: "Failed job",
          quest_id: quest.id,
          comb_id: comb.id,
          status: "failed",
          phase_job: false
        })

      quest_record = Store.get(:quests, quest.id)
      updated = Map.put(quest_record, :current_phase, "implementation")
      Store.put(:quests, updated)

      {:ok, phase} = Hive.Queen.Orchestrator.advance_quest(quest.id)
      assert phase == "implementation"
    end
  end
end
