defmodule GiTF.Intelligence.SuccessPatternsTest do
  use ExUnit.Case, async: false

  alias GiTF.Intelligence.SuccessPatterns
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-success-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_success/1" do
    test "analyzes a successful op" do
      op = %{
        id: "op-success",
        sector_id: "sector-test",
        status: "done",
        model: "claude-sonnet",
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      {:ok, pattern} = SuccessPatterns.analyze_success(op.id)
      
      assert pattern.op_id == op.id
      assert pattern.sector_id == op.sector_id
      assert is_list(pattern.success_factors)
      assert pattern.model_used == "claude-sonnet"
    end

    test "identifies success factors" do
      op = %{
        id: "op-factors",
        sector_id: "sector-test",
        status: "done",
        model: "claude-opus",
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      {:ok, pattern} = SuccessPatterns.analyze_success(op.id)
      
      assert "verification_passed" in pattern.success_factors
      assert "first_attempt_success" in pattern.success_factors
    end

    test "returns error for non-successful op" do
      op = %{
        id: "op-failed",
        status: "failed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Archive.insert(:ops, op)
      
      assert {:error, :not_successful_job} = SuccessPatterns.analyze_success(op.id)
    end
  end

  describe "get_best_practices/1" do
    test "returns empty for sector with no successes" do
      practices = SuccessPatterns.get_best_practices("nonexistent")
      
      assert practices == []
    end

    test "identifies common success factors" do
      sector_id = "sector-practices"
      
      # Create multiple successful ops
      for i <- 1..3 do
        op = %{
          id: "op-#{i}",
          sector_id: sector_id,
          status: "done",
          model: "claude-sonnet",
          verification_status: "passed",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Archive.insert(:ops, op)
        SuccessPatterns.analyze_success(op.id)
      end
      
      practices = SuccessPatterns.get_best_practices(sector_id)
      
      assert is_list(practices.common_factors)
      assert length(practices.common_factors) > 0
    end
  end

  describe "recommend_approach/2" do
    test "provides recommendations based on patterns" do
      sector_id = "sector-recommend"
      
      # Create multiple successful ops to establish pattern
      for i <- 1..3 do
        op = %{
          id: "op-recommend-#{i}",
          sector_id: sector_id,
          status: "done",
          model: "claude-opus",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Archive.insert(:ops, op)
        SuccessPatterns.analyze_success(op.id)
      end
      
      recommendation = SuccessPatterns.recommend_approach(sector_id, "test task")
      
      # Should recommend the model that was used successfully
      assert is_binary(recommendation.model)
      assert recommendation.confidence in [:low, :medium, :high]
      assert is_list(recommendation.suggestions)
      assert length(recommendation.suggestions) > 0
    end

    test "provides default recommendation with no data" do
      recommendation = SuccessPatterns.recommend_approach("nonexistent", "test")
      
      assert recommendation.model == "claude-sonnet"
      assert recommendation.confidence == :low
      assert "No historical data available" in recommendation.suggestions
    end
  end
end
