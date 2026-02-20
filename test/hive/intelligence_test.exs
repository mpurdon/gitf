defmodule Hive.IntelligenceTest do
  use ExUnit.Case, async: false

  alias Hive.Intelligence
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-intelligence-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    start_supervised!({Store, data_dir: store_dir})
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    %{store_dir: store_dir}
  end

  describe "analyze_and_suggest/1" do
    test "provides analysis and suggestions" do
      job = %{
        id: "job-analyze",
        comb_id: "comb-test",
        status: "failed",
        error_message: "test failed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      {:ok, result} = Intelligence.analyze_and_suggest(job.id)
      
      assert result.analysis
      assert result.recommended_strategy
      assert is_list(result.suggestions)
    end
  end

  describe "get_insights/1" do
    test "provides intelligence insights for comb" do
      comb_id = "comb-insights"
      
      # Create some jobs
      for i <- 1..5 do
        status = if rem(i, 2) == 0, do: "done", else: "failed"
        job = %{
          id: "job-#{i}",
          comb_id: comb_id,
          status: status,
          error_message: if(status == "failed", do: "timeout", else: ""),
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Store.insert(:jobs, job)
      end
      
      insights = Intelligence.get_insights(comb_id)
      
      assert insights.comb_id == comb_id
      assert insights.total_jobs == 5
      assert insights.failed_jobs == 3
      assert insights.success_rate == 40.0
    end
  end
end
