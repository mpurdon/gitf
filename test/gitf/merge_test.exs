defmodule GiTF.MergeTest do
  use ExUnit.Case, async: false

  alias GiTF.Merge
  alias GiTF.Store

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()

    tmp_dir = Path.join(System.tmp_dir!(), "gitf_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, comb} =
      Store.insert(:combs, %{
        name: "merge-comb-#{:erlang.unique_integer([:positive])}",
        merge_strategy: "manual"
      })

    {:ok, quest} =
      Store.insert(:quests, %{
        name: "merge-quest-#{:erlang.unique_integer([:positive])}",
        status: "pending"
      })

    {:ok, job} =
      GiTF.Jobs.create(%{
        title: "Merge test task",
        description: "Test the merge strategies",
        quest_id: quest.id,
        comb_id: comb.id
      })

    {:ok, ghost} =
      Store.insert(:ghosts, %{name: "merge-ghost", status: "working", job_id: job.id})

    {:ok, cell} =
      Store.insert(:cells, %{
        ghost_id: ghost.id,
        comb_id: comb.id,
        worktree_path: "/tmp/merge-worktree",
        branch: "ghost/#{ghost.id}",
        status: "active"
      })

    %{comb: comb, quest: quest, job: job, ghost: ghost, cell: cell}
  end

  describe "merge_back/1 with manual strategy" do
    test "returns {:ok, \"manual\"} for a comb with manual merge_strategy", ctx do
      assert {:ok, "manual"} = Merge.merge_back(ctx.cell.id)
    end
  end

  describe "merge_back/1 with pr_branch strategy" do
    test "returns {:ok, \"pr_branch\"} for a comb with pr_branch merge_strategy", ctx do
      # Create a comb with pr_branch strategy
      {:ok, pr_comb} =
        Store.insert(:combs, %{
          name: "pr-comb-#{:erlang.unique_integer([:positive])}",
          merge_strategy: "pr_branch"
        })

      # Create a cell pointing to this comb
      {:ok, pr_cell} =
        Store.insert(:cells, %{
          ghost_id: ctx.ghost.id,
          comb_id: pr_comb.id,
          worktree_path: "/tmp/pr-worktree",
          branch: "ghost/pr-test",
          status: "active"
        })

      assert {:ok, "pr_branch"} = Merge.merge_back(pr_cell.id)
    end
  end

  describe "merge_back/1 with unknown cell_id" do
    test "returns {:error, :cell_not_found} for a non-existent cell" do
      assert {:error, :cell_not_found} = Merge.merge_back("cel-nonexistent")
    end
  end

  describe "merge_back/1 with nil merge_strategy on comb" do
    test "defaults to manual when comb has nil merge_strategy", ctx do
      # Set merge_strategy to nil directly, simulating an older comb record
      updated_comb = %{ctx.comb | merge_strategy: nil}
      Store.put(:combs, updated_comb)

      assert {:ok, "manual"} = Merge.merge_back(ctx.cell.id)
    end
  end

  describe "auto_merge rollback" do
    test "auto_merge with invalid repo path returns error", ctx do
      # Create a comb with auto_merge strategy but no valid git repo
      {:ok, auto_comb} =
        Store.insert(:combs, %{
          name: "auto-comb-#{:erlang.unique_integer([:positive])}",
          merge_strategy: "auto_merge",
          path: "/tmp/nonexistent-repo"
        })

      {:ok, auto_cell} =
        Store.insert(:cells, %{
          ghost_id: ctx.ghost.id,
          comb_id: auto_comb.id,
          worktree_path: "/tmp/nonexistent-worktree",
          branch: "ghost/auto-test",
          status: "active"
        })

      # Should fail gracefully with merge_conflict error, not crash
      result = Merge.merge_back(auto_cell.id)
      assert match?({:error, _}, result)
    end
  end

  describe "merge_back_with_rebase/1" do
    test "returns error for non-existent cell" do
      assert {:error, :cell_not_found} = Merge.merge_back_with_rebase("cel-nonexistent")
    end
  end
end
