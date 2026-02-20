defmodule Hive.Intelligence.FailureAnalysisTest do
  use ExUnit.Case, async: false

  alias Hive.Intelligence.FailureAnalysis
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-intel-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_failure/1" do
    test "analyzes a failed job" do
      job = %{
        id: "job-failed",
        comb_id: "comb-test",
        status: "failed",
        error_message: "compilation error: undefined function",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      {:ok, analysis} = FailureAnalysis.analyze_failure(job.id)
      
      assert analysis.job_id == job.id
      assert analysis.failure_type == :compilation_error
      assert is_binary(analysis.root_cause)
      assert is_list(analysis.suggestions)
      assert length(analysis.suggestions) > 0
    end

    test "classifies timeout failures" do
      job = %{
        id: "job-timeout",
        comb_id: "comb-test",
        status: "failed",
        error_message: "Job timeout after 30 minutes",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      {:ok, analysis} = FailureAnalysis.analyze_failure(job.id)
      
      assert analysis.failure_type == :timeout
    end

    test "returns error for non-failed job" do
      job = %{
        id: "job-success",
        status: "done",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      assert {:error, :not_failed_job} = FailureAnalysis.analyze_failure(job.id)
    end
  end

  describe "get_failure_patterns/1" do
    test "returns empty patterns for comb with no failures" do
      patterns = FailureAnalysis.get_failure_patterns("nonexistent")
      
      assert patterns == []
    end

    test "groups failures by type" do
      comb_id = "comb-patterns"
      
      # Create multiple failed jobs
      for i <- 1..3 do
        job = %{
          id: "job-#{i}",
          comb_id: comb_id,
          status: "failed",
          error_message: "timeout",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Store.insert(:jobs, job)
        FailureAnalysis.analyze_failure(job.id)
      end
      
      patterns = FailureAnalysis.get_failure_patterns(comb_id)
      
      assert length(patterns) > 0
      timeout_pattern = Enum.find(patterns, &(&1.type == :timeout))
      assert timeout_pattern
      assert timeout_pattern.count == 3
    end
  end

  describe "learn_from_failures/1" do
    test "creates learning from failure patterns" do
      comb_id = "comb-learn"
      
      job = %{
        id: "job-learn",
        comb_id: comb_id,
        status: "failed",
        error_message: "test failed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      FailureAnalysis.analyze_failure(job.id)
      
      {:ok, learning} = FailureAnalysis.learn_from_failures(comb_id)
      
      assert learning.comb_id == comb_id
      assert is_list(learning.patterns)
      assert learning.total_failures > 0
    end
  end
end
