defmodule GiTF.CellTest do
  use ExUnit.Case, async: false

  alias GiTF.Cell
  alias GiTF.Store

  @tmp_dir System.tmp_dir!()

  setup do
    store_dir = Path.join(@tmp_dir, "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    # Create a temp git repo to serve as a comb
    repo_path = create_temp_git_repo()

    # Register the comb in the database
    {:ok, comb} =
      GiTF.Comb.add(repo_path, name: "cell-test-comb-#{:erlang.unique_integer([:positive])}")

    # Create a ghost record
    {:ok, ghost} = Store.insert(:ghosts, %{name: "test-ghost", status: "starting"})

    %{comb: comb, ghost: ghost, repo_path: repo_path}
  end

  defp create_temp_git_repo do
    name = "gitf_cell_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    readme = Path.join(path, "README.md")
    File.write!(readme, "# Test\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)

    # Resolve real path (macOS /var -> /private/var symlink)
    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"],
        cd: path,
        stderr_to_stdout: true
      )

    real_path = String.trim(real_path)

    on_exit(fn -> File.rm_rf!(path) end)
    real_path
  end

  describe "create/3" do
    test "creates a cell with worktree and database record", %{comb: comb, ghost: ghost} do
      assert {:ok, cell} = Cell.create(comb.id, ghost.id)

      assert cell.comb_id == comb.id
      assert cell.ghost_id == ghost.id
      assert cell.branch == "ghost/#{ghost.id}"
      assert cell.status == "active"
      assert String.starts_with?(cell.id, "cel-")

      expected_path = Path.join([comb.path, "ghosts", ghost.id])
      assert cell.worktree_path == expected_path
      assert File.dir?(expected_path)
    end

    test "accepts custom branch name", %{comb: comb, ghost: ghost} do
      assert {:ok, cell} = Cell.create(comb.id, ghost.id, branch: "feature/custom")
      assert cell.branch == "feature/custom"
    end

    test "returns error for nonexistent comb", %{ghost: ghost} do
      assert {:error, :not_found} = Cell.create("cmb-000000", ghost.id)
    end

    test "returns error for comb without a path", %{ghost: ghost} do
      # Insert a comb with nil path
      {:ok, remote_comb} =
        Store.insert(:combs, %{
          name: "remote-only-#{:erlang.unique_integer([:positive])}",
          repo_url: "https://example.com/repo",
          path: nil
        })

      assert {:error, :comb_has_no_path} = Cell.create(remote_comb.id, ghost.id)
    end
  end

  describe "get/1" do
    test "retrieves a cell by ID", %{comb: comb, ghost: ghost} do
      {:ok, created} = Cell.create(comb.id, ghost.id)
      assert {:ok, found} = Cell.get(created.id)
      assert found.id == created.id
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Cell.get("cel-000000")
    end
  end

  describe "list/1" do
    test "lists all cells", %{comb: comb, ghost: ghost} do
      {:ok, _} = Cell.create(comb.id, ghost.id)

      cells = Cell.list()
      assert length(cells) >= 1
    end

    test "filters by comb_id", %{comb: comb, ghost: ghost} do
      {:ok, _} = Cell.create(comb.id, ghost.id)

      cells = Cell.list(comb_id: comb.id)
      assert length(cells) >= 1
      assert Enum.all?(cells, &(&1.comb_id == comb.id))
    end

    test "filters by status", %{comb: comb, ghost: ghost} do
      {:ok, _} = Cell.create(comb.id, ghost.id)

      active = Cell.list(status: "active")
      assert length(active) >= 1

      removed = Cell.list(status: "removed")
      # Could be 0 if no cells removed yet in this test
      assert is_list(removed)
    end
  end

  describe "remove/2" do
    test "removes worktree and marks record as removed", %{comb: comb, ghost: ghost} do
      {:ok, cell} = Cell.create(comb.id, ghost.id)
      assert File.dir?(cell.worktree_path)

      assert {:ok, removed} = Cell.remove(cell.id)
      assert removed.status == "removed"
      assert removed.removed_at != nil
      refute File.dir?(cell.worktree_path)
    end

    test "returns error for nonexistent cell" do
      assert {:error, :not_found} = Cell.remove("cel-000000")
    end
  end

  describe "cleanup_orphans/0" do
    test "marks cells as removed when ghost is stopped", %{comb: comb} do
      # Create a ghost that is stopped
      {:ok, stopped_bee} = Store.insert(:ghosts, %{name: "stopped-ghost", status: "stopped"})

      {:ok, _cell} = Cell.create(comb.id, stopped_ghost.id)

      assert {:ok, count} = Cell.cleanup_orphans()
      assert count >= 1
    end

    test "does not touch cells with active ghosts", %{comb: comb, ghost: ghost} do
      # ghost defaults to "starting" status which is active
      {:ok, cell} = Cell.create(comb.id, ghost.id)

      {:ok, _count} = Cell.cleanup_orphans()

      {:ok, still_active} = Cell.get(cell.id)
      assert still_active.status == "active"
    end
  end
end
