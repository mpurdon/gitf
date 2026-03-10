defmodule Hive.ReputationTest do
  use ExUnit.Case, async: false

  alias Hive.{Reputation, Store}

  setup do
    Hive.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "reputation_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    Hive.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create test comb and quest
    {:ok, comb} = Store.insert(:combs, %{name: "test-comb", path: "/tmp/test"})

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "test-quest",
        goal: "Test reputation",
        comb_id: comb.id,
        status: "completed",
        current_phase: "completed",
        artifacts: %{},
        phase_jobs: %{}
      })

    %{comb: comb, quest: quest}
  end

  describe "model_reputation/2" do
    test "returns nil when no data exists" do
      assert Reputation.model_reputation("sonnet", :implementation) == nil
    end

    test "computes success rate from job history", %{quest: quest, comb: comb} do
      # Create some completed jobs
      for _ <- 1..3 do
        {:ok, _} =
          Hive.Jobs.create(%{
            title: "Impl task",
            quest_id: quest.id,
            comb_id: comb.id,
            job_type: :implementation,
            recommended_model: "sonnet",
            assigned_model: "sonnet",
            status: "done"
          })
      end

      # Create one failed job
      {:ok, _} =
        Hive.Jobs.create(%{
          title: "Failed task",
          quest_id: quest.id,
          comb_id: comb.id,
          job_type: :implementation,
          recommended_model: "sonnet",
          assigned_model: "sonnet",
          status: "failed"
        })

      rep = Reputation.model_reputation("sonnet", :implementation)
      assert rep != nil
      assert rep.success_rate == 0.75
      assert rep.total_jobs == 4
    end

    test "caches results and returns from cache", %{quest: quest, comb: comb} do
      {:ok, _} =
        Hive.Jobs.create(%{
          title: "Cached task",
          quest_id: quest.id,
          comb_id: comb.id,
          job_type: :research,
          recommended_model: "haiku",
          assigned_model: "haiku",
          status: "done"
        })

      # First call computes
      rep1 = Reputation.model_reputation("haiku", :research)
      assert rep1.success_rate == 1.0

      # Second call should return cached
      rep2 = Reputation.model_reputation("haiku", :research)
      assert rep2.computed_at == rep1.computed_at
    end
  end

  describe "recommend_model/2" do
    test "falls back to ModelSelector when no reputation data" do
      model = Reputation.recommend_model(:implementation, :complex)
      # Should return something valid
      assert model in ["opus", "sonnet", "haiku"]
    end

    test "uses reputation data when available", %{quest: quest, comb: comb} do
      # Create many successful haiku jobs for research
      for _ <- 1..10 do
        {:ok, _} =
          Hive.Jobs.create(%{
            title: "Research task",
            quest_id: quest.id,
            comb_id: comb.id,
            job_type: :research,
            recommended_model: "haiku",
            assigned_model: "haiku",
            status: "done"
          })
      end

      model = Reputation.recommend_model(:research, :simple)
      assert model == "haiku"
    end
  end

  describe "update_after_job/1" do
    test "invalidates cached reputation", %{quest: quest, comb: comb} do
      {:ok, job} =
        Hive.Jobs.create(%{
          title: "Update test",
          quest_id: quest.id,
          comb_id: comb.id,
          job_type: :implementation,
          recommended_model: "sonnet",
          assigned_model: "sonnet",
          status: "done"
        })

      # Compute reputation to cache it
      _rep = Reputation.model_reputation("sonnet", :implementation)

      # Invalidate
      assert :ok == Reputation.update_after_job(job.id)

      # Next call should recompute (may return same data but with fresh timestamp)
      rep2 = Reputation.model_reputation("sonnet", :implementation)
      assert rep2 != nil
    end

    test "handles non-existent job gracefully" do
      assert :ok == Reputation.update_after_job("non-existent")
    end
  end
end
