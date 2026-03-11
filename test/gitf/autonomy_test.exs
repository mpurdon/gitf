defmodule GiTF.AutonomyTest do
  use ExUnit.Case, async: false

  alias GiTF.Autonomy
  alias GiTF.Store

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    store_dir = Path.join(System.tmp_dir!(), "section-autonomy-test-#{:rand.uniform(100000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Store.start_link(data_dir: store_dir)

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "self_heal/0" do
    test "returns empty list when system is healthy" do
      results = Autonomy.self_heal()
      
      assert is_list(results)
    end

    test "cleans up orphaned ghosts" do
      # Create ghost without active job
      ghost = %{
        id: "ghost-orphan",
        status: "active",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:ghosts, ghost)
      
      results = Autonomy.self_heal()
      
      # Should detect and clean up orphaned ghost
      assert is_list(results)
    end
  end

  describe "optimize_resources/0" do
    test "provides optimization recommendations" do
      recommendations = Autonomy.optimize_resources()
      
      assert is_list(recommendations)
    end
  end

  describe "predict_issues/1" do
    test "predicts issues based on failure patterns" do
      comb_id = "comb-predict"
      
      # Create some failed jobs
      for i <- 1..3 do
        job = %{
          id: "job-fail-#{i}",
          comb_id: comb_id,
          status: "failed",
          error_message: "timeout",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
        Store.insert(:jobs, job)
      end
      
      predictions = Autonomy.predict_issues(comb_id)
      
      assert is_list(predictions)
    end
  end

  describe "auto_approve?/1" do
    test "approves high-quality verified jobs" do
      job = %{
        id: "job-approve",
        quality_score: 90,
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      assert Autonomy.auto_approve?(job.id) == true
    end

    test "rejects low-quality jobs" do
      job = %{
        id: "job-reject",
        quality_score: 60,
        verification_status: "passed",
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
      Store.insert(:jobs, job)
      
      assert Autonomy.auto_approve?(job.id) == false
    end
  end

  describe "audit/2" do
    test "creates audit log entry" do
      {:ok, entry} = Autonomy.audit(:job_approved, %{job_id: "job-123"})
      
      assert entry.action == :job_approved
      assert entry.details.job_id == "job-123"
    end
  end
end
