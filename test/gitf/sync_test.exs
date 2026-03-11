defmodule GiTF.SyncTest do
  use ExUnit.Case, async: false

  alias GiTF.Sync
  alias GiTF.Archive

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "sync-sector-#{:erlang.unique_integer([:positive])}",
        sync_strategy: "manual"
      })

    {:ok, mission} =
      Archive.insert(:missions, %{
        name: "sync-mission-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, op} =
      GiTF.Ops.create(%{
        title: "Sync test task",
        description: "Test the sync strategies",
        mission_id: mission.id,
        sector_id: sector.id
      })

    {:ok, ghost} =
      Archive.insert(:ghosts, %{name: "sync-ghost", status: "working", op_id: op.id})

    {:ok, shell} =
      Archive.insert(:shells, %{
        ghost_id: ghost.id,
        sector_id: sector.id,
        worktree_path: "/tmp/sync-worktree",
        branch: "ghost/#{ghost.id}",
        status: "active"
      })

    %{sector: sector, mission: mission, op: op, ghost: ghost, shell: shell}
  end

  describe "sync_back/1 with manual strategy" do
    test "returns {:ok, \"manual\"} for a sector with manual sync_strategy", ctx do
      assert {:ok, "manual"} = Sync.sync_back(ctx.shell.id)
    end
  end

  describe "sync_back/1 with pr_branch strategy" do
    test "returns {:ok, \"pr_branch\"} for a sector with pr_branch sync_strategy", ctx do
      # Create a sector with pr_branch strategy
      {:ok, pr_comb} =
        Archive.insert(:sectors, %{
          name: "pr-sector-#{:erlang.unique_integer([:positive])}",
          sync_strategy: "pr_branch"
        })

      # Create a shell pointing to this sector
      {:ok, pr_cell} =
        Archive.insert(:shells, %{
          ghost_id: ctx.ghost.id,
          sector_id: pr_comb.id,
          worktree_path: "/tmp/pr-worktree",
          branch: "ghost/pr-test",
          status: "active"
        })

      assert {:ok, "pr_branch"} = Sync.sync_back(pr_cell.id)
    end
  end

  describe "sync_back/1 with unknown shell_id" do
    test "returns {:error, :cell_not_found} for a non-existent shell" do
      assert {:error, :cell_not_found} = Sync.sync_back("cel-nonexistent")
    end
  end

  describe "sync_back/1 with nil sync_strategy on sector" do
    test "defaults to manual when sector has nil sync_strategy", ctx do
      # Set sync_strategy to nil directly, simulating an older sector record
      updated_comb = %{ctx.sector | sync_strategy: nil}
      Archive.put(:sectors, updated_comb)

      assert {:ok, "manual"} = Sync.sync_back(ctx.shell.id)
    end
  end

  describe "auto_merge rollback" do
    test "auto_merge with invalid repo path returns error", ctx do
      # Create a sector with auto_merge strategy but no valid git repo
      {:ok, auto_comb} =
        Archive.insert(:sectors, %{
          name: "auto-sector-#{:erlang.unique_integer([:positive])}",
          sync_strategy: "auto_merge",
          path: "/tmp/nonexistent-repo"
        })

      {:ok, auto_cell} =
        Archive.insert(:shells, %{
          ghost_id: ctx.ghost.id,
          sector_id: auto_comb.id,
          worktree_path: "/tmp/nonexistent-worktree",
          branch: "ghost/auto-test",
          status: "active"
        })

      # Should fail gracefully with merge_conflict error, not crash
      result = Sync.sync_back(auto_cell.id)
      assert match?({:error, _}, result)
    end
  end

  describe "sync_back_with_rebase/1" do
    test "returns error for non-existent shell" do
      assert {:error, :cell_not_found} = Sync.sync_back_with_rebase("cel-nonexistent")
    end
  end
end
