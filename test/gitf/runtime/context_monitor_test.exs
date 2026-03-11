defmodule GiTF.Runtime.ContextMonitorTest do
  use ExUnit.Case, async: false

  alias GiTF.Runtime.ContextMonitor
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    # Create a temporary store for testing
    store_dir = Path.join(System.tmp_dir!(), "gitf_context_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)

    on_exit(fn -> File.rm_rf!(store_dir) end)

    GiTF.Test.StoreHelper.stop_store()
    {:ok, _pid} = Archive.start_link(data_dir: store_dir)
    
    # Create a test ghost
    {:ok, ghost} = Archive.insert(:ghosts, %{
      name: "test-ghost",
      status: "working",
      op_id: "op-123",
      assigned_model: "claude-sonnet",
      context_tokens_used: 0,
      context_tokens_limit: nil,
      context_percentage: 0.0
    })
    
    %{ghost_id: ghost.id, store_dir: store_dir}
  end

  describe "record_usage/3" do
    test "records token usage and calculates percentage", %{ghost_id: ghost_id} do
      # Record 40k tokens (20% of 200k limit)
      assert {:ok, :normal} = ContextMonitor.record_usage(ghost_id, 20_000, 20_000)
      
      ghost = Archive.get(:ghosts, ghost_id)
      assert ghost.context_tokens_used == 40_000
      assert ghost.context_tokens_limit == 200_000
      assert ghost.context_percentage == 0.2
    end

    test "returns warning status at 40% threshold", %{ghost_id: ghost_id} do
      # Record 80k tokens (40% of 200k)
      assert {:ok, :warning} = ContextMonitor.record_usage(ghost_id, 40_000, 40_000)
      
      ghost = Archive.get(:ghosts, ghost_id)
      assert ghost.context_percentage == 0.4
    end

    test "returns critical status at 45% threshold", %{ghost_id: ghost_id} do
      # Record 90k tokens (45% of 200k)
      assert {:ok, :critical} = ContextMonitor.record_usage(ghost_id, 45_000, 45_000)
      
      ghost = Archive.get(:ghosts, ghost_id)
      assert ghost.context_percentage == 0.45
    end

    test "returns transfer_needed at 50% threshold", %{ghost_id: ghost_id} do
      # Record 100k tokens (50% of 200k)
      assert {:ok, :transfer_needed} = ContextMonitor.record_usage(ghost_id, 50_000, 50_000)
      
      ghost = Archive.get(:ghosts, ghost_id)
      assert ghost.context_percentage == 0.5
    end

    test "accumulates token usage across multiple calls", %{ghost_id: ghost_id} do
      assert {:ok, :normal} = ContextMonitor.record_usage(ghost_id, 10_000, 10_000)
      assert {:ok, :normal} = ContextMonitor.record_usage(ghost_id, 10_000, 10_000)
      assert {:ok, :warning} = ContextMonitor.record_usage(ghost_id, 20_000, 20_000)
      
      ghost = Archive.get(:ghosts, ghost_id)
      assert ghost.context_tokens_used == 80_000
      assert ghost.context_percentage == 0.4
    end
  end

  describe "needs_handoff?/1" do
    test "returns false for normal usage", %{ghost_id: ghost_id} do
      ContextMonitor.record_usage(ghost_id, 20_000, 20_000)
      refute ContextMonitor.needs_handoff?(ghost_id)
    end

    test "returns true at critical threshold", %{ghost_id: ghost_id} do
      ContextMonitor.record_usage(ghost_id, 45_000, 45_000)
      assert ContextMonitor.needs_handoff?(ghost_id)
    end

    test "returns false for non-existent ghost" do
      refute ContextMonitor.needs_handoff?("nonexistent")
    end
  end

  describe "get_usage_percentage/1" do
    test "returns current percentage", %{ghost_id: ghost_id} do
      ContextMonitor.record_usage(ghost_id, 30_000, 30_000)
      assert ContextMonitor.get_usage_percentage(ghost_id) == 0.3
    end

    test "returns 0.0 for non-existent ghost" do
      assert ContextMonitor.get_usage_percentage("nonexistent") == 0.0
    end
  end

  describe "get_usage_stats/1" do
    test "returns complete usage statistics", %{ghost_id: ghost_id} do
      ContextMonitor.record_usage(ghost_id, 40_000, 40_000)
      
      assert {:ok, stats} = ContextMonitor.get_usage_stats(ghost_id)
      assert stats.tokens_used == 80_000
      assert stats.tokens_limit == 200_000
      assert stats.percentage == 0.4
      assert stats.status == :warning
      refute stats.needs_handoff
    end

    test "returns error for non-existent ghost" do
      assert {:error, :not_found} = ContextMonitor.get_usage_stats("nonexistent")
    end
  end

  describe "create_snapshot/1" do
    test "creates a context snapshot", %{ghost_id: ghost_id} do
      # Create a op for the ghost
      {:ok, op} = Archive.insert(:ops, %{
        title: "Test op",
        status: "running",
        mission_id: "mission-123",
        sector_id: "sector-456"
      })
      
      # Update ghost with op
      ghost = Archive.get(:ghosts, ghost_id)
      Archive.put(:ghosts, %{ghost | op_id: op.id})
      
      # Record some usage
      ContextMonitor.record_usage(ghost_id, 40_000, 40_000)
      
      # Create snapshot
      assert {:ok, snapshot} = ContextMonitor.create_snapshot(ghost_id)
      assert snapshot.ghost_id == ghost_id
      assert snapshot.tokens_used == 80_000
      assert snapshot.percentage == 0.4
      assert snapshot.op_id == op.id
    end
  end

  describe "get_latest_snapshot/1" do
    test "returns most recent snapshot", %{ghost_id: ghost_id} do
      # Create op
      {:ok, op} = Archive.insert(:ops, %{
        title: "Test op",
        status: "running",
        mission_id: "mission-123",
        sector_id: "sector-456"
      })
      
      ghost = Archive.get(:ghosts, ghost_id)
      Archive.put(:ghosts, %{ghost | op_id: op.id})
      
      # Create multiple snapshots
      ContextMonitor.record_usage(ghost_id, 20_000, 20_000)
      {:ok, _snap1} = ContextMonitor.create_snapshot(ghost_id)
      
      :timer.sleep(10)
      
      ContextMonitor.record_usage(ghost_id, 20_000, 20_000)
      {:ok, snap2} = ContextMonitor.create_snapshot(ghost_id)
      
      # Get latest
      assert {:ok, latest} = ContextMonitor.get_latest_snapshot(ghost_id)
      assert latest.id == snap2.id
      assert latest.tokens_used == 80_000
    end

    test "returns error when no snapshots exist", %{ghost_id: ghost_id} do
      assert {:error, :not_found} = ContextMonitor.get_latest_snapshot(ghost_id)
    end
  end
end
