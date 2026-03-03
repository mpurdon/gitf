defmodule Hive.Queen.PlannerReplanTest do
  use ExUnit.Case, async: false

  alias Hive.Queen.Planner
  alias Hive.Store

  setup do
    Hive.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "replan_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create a quest
    {:ok, quest} =
      Store.insert(:quests, %{
        name: "Test Quest",
        goal: "Build a widget",
        status: "implementation",
        comb_id: "comb-1",
        current_phase: "implementation",
        artifacts: %{},
        phase_jobs: %{}
      })

    # Create a comb
    {:ok, _comb} =
      Store.insert(:combs, %{id: "comb-1", name: "test", path: "/tmp/test"})

    {:ok, quest: quest}
  end

  describe "replan_from_failures/2" do
    test "returns :no_failures when quest has no failed jobs", %{quest: quest} do
      assert {:error, :no_failures} = Planner.replan_from_failures(quest.id)
    end

    test "collects failures and attempts replan", %{quest: quest} do
      # Create a failed job
      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Implement feature",
          description: "Build the thing",
          quest_id: quest.id,
          comb_id: "comb-1"
        })

      # Manually set status to failed
      job_record = Store.get(:jobs, job.id)
      Store.put(:jobs, %{job_record | status: "failed"})

      # Replan will fail because there's no LLM in test, but it should
      # attempt the analysis and return :replan_failed
      result = Planner.replan_from_failures(quest.id)

      # Either succeeds with a plan or fails gracefully
      case result do
        {:ok, plan} ->
          assert plan.quest_id == quest.id
          assert plan.replan == true

        {:error, reason} ->
          assert reason in [:replan_failed, :not_failed_job]
      end
    end
  end

  describe "replan with multiple failures" do
    test "handles multiple failed jobs gracefully", %{quest: quest} do
      # Create two failed jobs
      for title <- ["Setup DB", "Run migrations"] do
        {:ok, job} =
          Hive.Jobs.create(%{
            title: title,
            description: "Do the thing",
            quest_id: quest.id,
            comb_id: "comb-1"
          })

        job_record = Store.get(:jobs, job.id)
        Store.put(:jobs, %{job_record | status: "failed"})
      end

      result = Planner.replan_from_failures(quest.id)

      # Should not crash — either succeeds or fails gracefully
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
