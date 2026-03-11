defmodule GiTF.ConflictTest do
  use ExUnit.Case, async: false

  alias GiTF.Conflict
  alias GiTF.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    # Create a temporary git repo for testing
    tmp_dir =
      Path.join(System.tmp_dir!(), "gitf_conflict_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    System.cmd("git", ["init"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)
    File.write!(Path.join(tmp_dir, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: tmp_dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: tmp_dir)

    {:ok, comb} =
      Store.insert(:combs, %{
        name: "conflict-comb-#{:erlang.unique_integer([:positive])}",
        path: tmp_dir
      })

    {:ok, ghost} =
      Store.insert(:ghosts, %{
        name: "conflict-ghost-#{:erlang.unique_integer([:positive])}",
        status: "starting"
      })

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{comb: comb, ghost: ghost, tmp_dir: tmp_dir}
  end

  describe "check/1" do
    test "returns clean when no conflicts exist", %{comb: comb, ghost: ghost, tmp_dir: tmp_dir} do
      # Create a branch with non-conflicting changes
      System.cmd("git", ["checkout", "-b", "test-branch"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "new_file.txt"), "new content")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "add new file"], cd: tmp_dir)
      System.cmd("git", ["checkout", "main"], cd: tmp_dir)

      {:ok, cell} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: ghost.id,
          branch: "test-branch",
          worktree_path: tmp_dir,
          status: "active"
        })

      assert {:ok, :clean} = Conflict.check(cell.id)
    end

    test "returns error for non-existent cell" do
      assert {:error, :cell_not_found} = Conflict.check("cel-nonexistent")
    end
  end

  describe "check_all_active/0" do
    test "returns empty list when no active cells" do
      assert Conflict.check_all_active() == []
    end
  end

  describe "resolve/2" do
    test "returns error for non-existent cell" do
      assert {:error, :cell_not_found} = Conflict.resolve("cel-nonexistent", :rebase)
    end

    test "defer strategy marks cell for manual merge", %{comb: comb, ghost: ghost, tmp_dir: tmp_dir} do
      {:ok, cell} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: ghost.id,
          branch: "test-branch",
          worktree_path: tmp_dir,
          status: "active"
        })

      assert {:ok, :resolved} = Conflict.resolve(cell.id, :defer)

      # Verify cell was marked for manual merge
      updated_cell = Store.get(:cells, cell.id)
      assert updated_cell.needs_manual_merge == true
    end

    test "rebase strategy on clean branch succeeds", %{comb: comb, ghost: ghost, tmp_dir: tmp_dir} do
      # Create a feature branch
      System.cmd("git", ["checkout", "-b", "feature-branch"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "feature.txt"), "feature content")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "add feature"], cd: tmp_dir)

      {:ok, cell} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: ghost.id,
          branch: "feature-branch",
          worktree_path: tmp_dir,
          status: "active"
        })

      assert {:ok, :resolved} = Conflict.resolve(cell.id, :rebase)
    end
  end

  describe "check_between_cells/2" do
    test "returns clean when cells touch different files", %{comb: comb, tmp_dir: tmp_dir} do
      # Create two branches with different files
      System.cmd("git", ["checkout", "-b", "branch-a"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "file_a.txt"), "content a")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "add file_a"], cd: tmp_dir)
      System.cmd("git", ["checkout", "main"], cd: tmp_dir)

      System.cmd("git", ["checkout", "-b", "branch-b"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "file_b.txt"), "content b")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "add file_b"], cd: tmp_dir)
      System.cmd("git", ["checkout", "main"], cd: tmp_dir)

      {:ok, bee_a} = Store.insert(:ghosts, %{name: "ghost-a", status: "working"})
      {:ok, bee_b} = Store.insert(:ghosts, %{name: "ghost-b", status: "working"})

      {:ok, cell_a} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: bee_a.id,
          branch: "branch-a",
          worktree_path: tmp_dir,
          status: "active"
        })

      {:ok, cell_b} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: bee_b.id,
          branch: "branch-b",
          worktree_path: tmp_dir,
          status: "active"
        })

      assert {:ok, :clean} = Conflict.check_between_cells(cell_a.id, cell_b.id)
    end

    test "returns conflicts when cells touch same files", %{comb: comb, tmp_dir: tmp_dir} do
      # Create two branches modifying the same file
      System.cmd("git", ["checkout", "-b", "branch-c"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "# Modified by branch C")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "modify readme c"], cd: tmp_dir)
      System.cmd("git", ["checkout", "main"], cd: tmp_dir)

      System.cmd("git", ["checkout", "-b", "branch-d"], cd: tmp_dir)
      File.write!(Path.join(tmp_dir, "README.md"), "# Modified by branch D")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "modify readme d"], cd: tmp_dir)
      System.cmd("git", ["checkout", "main"], cd: tmp_dir)

      {:ok, bee_c} = Store.insert(:ghosts, %{name: "ghost-c", status: "working"})
      {:ok, bee_d} = Store.insert(:ghosts, %{name: "ghost-d", status: "working"})

      {:ok, cell_c} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: bee_c.id,
          branch: "branch-c",
          worktree_path: tmp_dir,
          status: "active"
        })

      {:ok, cell_d} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: bee_d.id,
          branch: "branch-d",
          worktree_path: tmp_dir,
          status: "active"
        })

      assert {:error, :conflicts, files} = Conflict.check_between_cells(cell_c.id, cell_d.id)
      assert "README.md" in files
    end

    test "returns error for non-existent cell" do
      assert {:error, :cell_not_found} = Conflict.check_between_cells("cel-nonexistent", "cel-other")
    end
  end
end
