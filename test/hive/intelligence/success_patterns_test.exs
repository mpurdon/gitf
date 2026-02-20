defmodule Hive.Intelligence.SuccessPatternsTest do
  use ExUnit.Case, async: false

  alias Hive.Intelligence.SuccessPatterns
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-success-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_success/1" do
    test "analyzes a successful job" do
      job = %{
        id: "job-success",
        comb_id: "comb-test",
        status: "done",
        model: "claude-sonnet",
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      {:ok, pattern} = SuccessPatterns.analyze_success(job.id)
      
      assert pattern.job_id == job.id
      assert pattern.comb_id == job.comb_id
      assert is_list(pattern.success_factors)
      assert pattern.model_used == "claude-sonnet"
    end

    test "identifies success factors" do
      job = %{
        id: "job-factors",
        comb_id: "comb-test",
        status: "done",
        model: "claude-opus",
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      {:ok, pattern} = SuccessPatterns.analyze_success(job.id)
      
      assert "verification_passed" in pattern.success_factors
      assert "first_attempt_success" in pattern.success_factors
    end

    test "returns error for non-successful job" do
      job = %{
        id: "job-failed",
        status: "failed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      assert {:error, :not_successful_job} = SuccessPatterns.analyze_success(job.id)
    end
  end

  describe "get_best_practices/1" do
    test "returns empty for comb with no successes" do
      practices = SuccessPatterns.get_best_practices("nonexistent")
      
      assert practices == []
    end

    test "identifies common success factors" do
      comb_id = "comb-practices"
      
      # Create multiple successful jobs
      for i <- 1..3 do
        job = %{
          id: "job-#{i}",
          comb_id: comb_id,
          status: "done",
          model: "claude-sonnet",
          verification_status: "passed",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Store.insert(:jobs, job)
        SuccessPatterns.analyze_success(job.id)
      end
      
      practices = SuccessPatterns.get_best_practices(comb_id)
      
      assert is_list(practices.common_factors)
      assert length(practices.common_factors) > 0
    end
  end

  describe "recommend_approach/2" do
    test "provides recommendations based on patterns" do
      comb_id = "comb-recommend"
      
      # Create multiple successful jobs to establish pattern
      for i <- 1..3 do
        job = %{
          id: "job-recommend-#{i}",
          comb_id: comb_id,
          status: "done",
          model: "claude-opus",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Store.insert(:jobs, job)
        SuccessPatterns.analyze_success(job.id)
      end
      
      recommendation = SuccessPatterns.recommend_approach(comb_id, "test task")
      
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
