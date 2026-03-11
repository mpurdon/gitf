defmodule GiTF.ReputationTest do
  use ExUnit.Case, async: false

  alias GiTF.{Reputation, Archive}

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    tmp_dir = Path.join(System.tmp_dir!(), "reputation_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Create test sector and mission
    {:ok, sector} = Archive.insert(:sectors, %{name: "test-sector", path: "/tmp/test"})

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "test-mission",
        goal: "Test reputation",
        sector_id: sector.id,
        status: "completed",
        current_phase: "completed",
        artifacts: %{},
        phase_jobs: %{}
      })

    %{sector: sector, mission: mission}
  end

  describe "model_reputation/2" do
    test "returns nil when no data exists" do
      assert Reputation.model_reputation("sonnet", :implementation) == nil
    end

    test "computes success rate from op history", %{mission: mission, sector: sector} do
      # Create some completed ops
      for _ <- 1..3 do
        {:ok, _} =
          GiTF.Ops.create(%{
            title: "Impl task",
            mission_id: mission.id,
            sector_id: sector.id,
            op_type: :implementation,
            recommended_model: "sonnet",
            assigned_model: "sonnet",
            status: "done"
          })
      end

      # Create one failed op
      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Failed task",
          mission_id: mission.id,
          sector_id: sector.id,
          op_type: :implementation,
          recommended_model: "sonnet",
          assigned_model: "sonnet",
          status: "failed"
        })

      rep = Reputation.model_reputation("sonnet", :implementation)
      assert rep != nil
      assert rep.success_rate == 0.75
      assert rep.total_jobs == 4
    end

    test "caches results and returns from cache", %{mission: mission, sector: sector} do
      {:ok, _} =
        GiTF.Ops.create(%{
          title: "Cached task",
          mission_id: mission.id,
          sector_id: sector.id,
          op_type: :research,
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

    test "uses reputation data when available", %{mission: mission, sector: sector} do
      # Create many successful haiku ops for research
      for _ <- 1..10 do
        {:ok, _} =
          GiTF.Ops.create(%{
            title: "Research task",
            mission_id: mission.id,
            sector_id: sector.id,
            op_type: :research,
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
    test "invalidates cached reputation", %{mission: mission, sector: sector} do
      {:ok, op} =
        GiTF.Ops.create(%{
          title: "Update test",
          mission_id: mission.id,
          sector_id: sector.id,
          op_type: :implementation,
          recommended_model: "sonnet",
          assigned_model: "sonnet",
          status: "done"
        })

      # Compute reputation to cache it
      _rep = Reputation.model_reputation("sonnet", :implementation)

      # Invalidate
      assert :ok == Reputation.update_after_job(op.id)

      # Next call should recompute (may return same data but with fresh timestamp)
      rep2 = Reputation.model_reputation("sonnet", :implementation)
      assert rep2 != nil
    end

    test "handles non-existent op gracefully" do
      assert :ok == Reputation.update_after_job("non-existent")
    end
  end
end
