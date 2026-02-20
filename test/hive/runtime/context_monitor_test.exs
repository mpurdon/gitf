defmodule Hive.Runtime.ContextMonitorTest do
  use ExUnit.Case, async: false

  alias Hive.Runtime.ContextMonitor
  alias Hive.Store

  setup do
    # Create a temporary store for testing
    store_dir = Path.join(System.tmp_dir!(), "hive_context_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    
    on_exit(fn -> File.rm_rf!(store_dir) end)
    
    {:ok, _pid} = Store.start_link(data_dir: store_dir)
    
    # Create a test bee
    {:ok, bee} = Store.insert(:bees, %{
      name: "test-bee",
      status: "working",
      job_id: "job-123",
      assigned_model: "claude-sonnet",
      context_tokens_used: 0,
      context_tokens_limit: nil,
      context_percentage: 0.0
    })
    
    %{bee_id: bee.id, store_dir: store_dir}
  end

  describe "record_usage/3" do
    test "records token usage and calculates percentage", %{bee_id: bee_id} do
      # Record 40k tokens (20% of 200k limit)
      assert {:ok, :normal} = ContextMonitor.record_usage(bee_id, 20_000, 20_000)
      
      bee = Store.get(:bees, bee_id)
      assert bee.context_tokens_used == 40_000
      assert bee.context_tokens_limit == 200_000
      assert bee.context_percentage == 0.2
    end

    test "returns warning status at 40% threshold", %{bee_id: bee_id} do
      # Record 80k tokens (40% of 200k)
      assert {:ok, :warning} = ContextMonitor.record_usage(bee_id, 40_000, 40_000)
      
      bee = Store.get(:bees, bee_id)
      assert bee.context_percentage == 0.4
    end

    test "returns critical status at 45% threshold", %{bee_id: bee_id} do
      # Record 90k tokens (45% of 200k)
      assert {:ok, :critical} = ContextMonitor.record_usage(bee_id, 45_000, 45_000)
      
      bee = Store.get(:bees, bee_id)
      assert bee.context_percentage == 0.45
    end

    test "returns handoff_needed at 50% threshold", %{bee_id: bee_id} do
      # Record 100k tokens (50% of 200k)
      assert {:ok, :handoff_needed} = ContextMonitor.record_usage(bee_id, 50_000, 50_000)
      
      bee = Store.get(:bees, bee_id)
      assert bee.context_percentage == 0.5
    end

    test "accumulates token usage across multiple calls", %{bee_id: bee_id} do
      assert {:ok, :normal} = ContextMonitor.record_usage(bee_id, 10_000, 10_000)
      assert {:ok, :normal} = ContextMonitor.record_usage(bee_id, 10_000, 10_000)
      assert {:ok, :warning} = ContextMonitor.record_usage(bee_id, 20_000, 20_000)
      
      bee = Store.get(:bees, bee_id)
      assert bee.context_tokens_used == 80_000
      assert bee.context_percentage == 0.4
    end
  end

  describe "needs_handoff?/1" do
    test "returns false for normal usage", %{bee_id: bee_id} do
      ContextMonitor.record_usage(bee_id, 20_000, 20_000)
      refute ContextMonitor.needs_handoff?(bee_id)
    end

    test "returns true at critical threshold", %{bee_id: bee_id} do
      ContextMonitor.record_usage(bee_id, 45_000, 45_000)
      assert ContextMonitor.needs_handoff?(bee_id)
    end

    test "returns false for non-existent bee" do
      refute ContextMonitor.needs_handoff?("nonexistent")
    end
  end

  describe "get_usage_percentage/1" do
    test "returns current percentage", %{bee_id: bee_id} do
      ContextMonitor.record_usage(bee_id, 30_000, 30_000)
      assert ContextMonitor.get_usage_percentage(bee_id) == 0.3
    end

    test "returns 0.0 for non-existent bee" do
      assert ContextMonitor.get_usage_percentage("nonexistent") == 0.0
    end
  end

  describe "get_usage_stats/1" do
    test "returns complete usage statistics", %{bee_id: bee_id} do
      ContextMonitor.record_usage(bee_id, 40_000, 40_000)
      
      assert {:ok, stats} = ContextMonitor.get_usage_stats(bee_id)
      assert stats.tokens_used == 80_000
      assert stats.tokens_limit == 200_000
      assert stats.percentage == 0.4
      assert stats.status == :warning
      refute stats.needs_handoff
    end

    test "returns error for non-existent bee" do
      assert {:error, :not_found} = ContextMonitor.get_usage_stats("nonexistent")
    end
  end

  describe "create_snapshot/1" do
    test "creates a context snapshot", %{bee_id: bee_id} do
      # Create a job for the bee
      {:ok, job} = Store.insert(:jobs, %{
        title: "Test job",
        status: "running",
        quest_id: "quest-123",
        comb_id: "comb-456"
      })
      
      # Update bee with job
      bee = Store.get(:bees, bee_id)
      Store.put(:bees, %{bee | job_id: job.id})
      
      # Record some usage
      ContextMonitor.record_usage(bee_id, 40_000, 40_000)
      
      # Create snapshot
      assert {:ok, snapshot} = ContextMonitor.create_snapshot(bee_id)
      assert snapshot.bee_id == bee_id
      assert snapshot.tokens_used == 80_000
      assert snapshot.percentage == 0.4
      assert snapshot.job_id == job.id
    end
  end

  describe "get_latest_snapshot/1" do
    test "returns most recent snapshot", %{bee_id: bee_id} do
      # Create job
      {:ok, job} = Store.insert(:jobs, %{
        title: "Test job",
        status: "running",
        quest_id: "quest-123",
        comb_id: "comb-456"
      })
      
      bee = Store.get(:bees, bee_id)
      Store.put(:bees, %{bee | job_id: job.id})
      
      # Create multiple snapshots
      ContextMonitor.record_usage(bee_id, 20_000, 20_000)
      {:ok, _snap1} = ContextMonitor.create_snapshot(bee_id)
      
      :timer.sleep(10)
      
      ContextMonitor.record_usage(bee_id, 20_000, 20_000)
      {:ok, snap2} = ContextMonitor.create_snapshot(bee_id)
      
      # Get latest
      assert {:ok, latest} = ContextMonitor.get_latest_snapshot(bee_id)
      assert latest.id == snap2.id
      assert latest.tokens_used == 80_000
    end

    test "returns error when no snapshots exist", %{bee_id: bee_id} do
      assert {:error, :not_found} = ContextMonitor.get_latest_snapshot(bee_id)
    end
  end
end
