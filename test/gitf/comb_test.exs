defmodule GiTF.CombTest do
  use ExUnit.Case, async: false

  alias GiTF.Comb
  alias GiTF.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "gitf_store_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Store.start_link(data_dir: store_dir)
    on_exit(fn -> File.rm_rf!(store_dir) end)

    tmp = Path.join(System.tmp_dir!(), "gitf_comb_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp}
  end

  describe "add/2 with a local path" do
    test "registers a comb from an existing directory", %{tmp: tmp} do
      assert {:ok, comb} = Comb.add(tmp)

      assert comb.name == Path.basename(tmp)
      assert comb.path == tmp
      assert String.starts_with?(comb.id, "cmb-")
    end

    test "uses a custom name when provided", %{tmp: tmp} do
      assert {:ok, comb} = Comb.add(tmp, name: "my-project")

      assert comb.name == "my-project"
    end

    test "returns error for non-existent path" do
      assert {:error, :path_not_found} = Comb.add("/nonexistent/path/#{System.unique_integer()}")
    end
  end

  describe "list/0" do
    test "returns empty list when no combs exist" do
      assert Comb.list() == []
    end

    test "returns all registered combs", %{tmp: tmp} do
      sub1 = Path.join(tmp, "project-a")
      sub2 = Path.join(tmp, "project-b")
      File.mkdir_p!(sub1)
      File.mkdir_p!(sub2)

      {:ok, _} = Comb.add(sub1, name: "project-a")
      {:ok, _} = Comb.add(sub2, name: "project-b")

      combs = Comb.list()
      names = Enum.map(combs, & &1.name) |> Enum.sort()

      assert names == ["project-a", "project-b"]
    end
  end

  describe "get/1" do
    test "finds a comb by name", %{tmp: tmp} do
      {:ok, created} = Comb.add(tmp, name: "findme")

      assert {:ok, found} = Comb.get("findme")
      assert found.id == created.id
    end

    test "finds a comb by ID", %{tmp: tmp} do
      {:ok, created} = Comb.add(tmp, name: "byid")

      assert {:ok, found} = Comb.get(created.id)
      assert found.name == "byid"
    end

    test "returns error for unknown name" do
      assert {:error, :not_found} = Comb.get("nonexistent")
    end
  end

  describe "remove/2" do
    test "removes a comb record by name", %{tmp: tmp} do
      {:ok, _} = Comb.add(tmp, name: "removeme")

      assert {:ok, removed} = Comb.remove("removeme")
      assert removed.name == "removeme"

      assert {:error, :not_found} = Comb.get("removeme")
    end

    test "returns error for unknown comb" do
      assert {:error, :not_found} = Comb.remove("ghost")
    end
  end

  describe "rename/2" do
    test "updates comb name in store", %{tmp: tmp} do
      dir = Path.join(tmp, "original")
      File.mkdir_p!(dir)
      {:ok, comb} = Comb.add(dir, name: "original")

      assert {:ok, renamed} = Comb.rename("original", "new-name")
      assert renamed.name == "new-name"
      assert renamed.id == comb.id

      # Verify lookup by new name works
      assert {:ok, found} = Comb.get("new-name")
      assert found.id == comb.id

      # Old name no longer resolves
      assert {:error, :not_found} = Comb.get("original")
    end

    test "rejects duplicate name", %{tmp: tmp} do
      dir1 = Path.join(tmp, "alpha")
      dir2 = Path.join(tmp, "beta")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      {:ok, _} = Comb.add(dir1, name: "alpha")
      {:ok, _} = Comb.add(dir2, name: "beta")

      assert {:error, :name_already_taken} = Comb.rename("alpha", "beta")
    end

    test "moves directory when basename matches old name", %{tmp: tmp} do
      dir = Path.join(tmp, "moveme")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "marker.txt"), "hello")
      {:ok, _} = Comb.add(dir, name: "moveme")

      assert {:ok, renamed} = Comb.rename("moveme", "moved")

      new_dir = Path.join(tmp, "moved")
      assert renamed.path == new_dir
      assert File.dir?(new_dir)
      assert File.read!(Path.join(new_dir, "marker.txt")) == "hello"
      refute File.dir?(dir)
    end

    test "updates cell worktree_path and ghost cell_path when path changes", %{tmp: tmp} do
      dir = Path.join(tmp, "repo")
      File.mkdir_p!(dir)
      {:ok, comb} = Comb.add(dir, name: "repo")

      # Create a cell with a worktree_path under the comb
      {:ok, cell} =
        Store.insert(:cells, %{
          comb_id: comb.id,
          ghost_id: "ghost-1",
          branch: "feat",
          worktree_path: Path.join(dir, "worktrees/ghost-1"),
          status: "active"
        })

      # Create a ghost with a cell_path under the comb
      {:ok, ghost} =
        Store.insert(:ghosts, %{
          name: "worker",
          status: "running",
          cell_path: Path.join(dir, "worktrees/ghost-1"),
          job_id: nil
        })

      assert {:ok, _} = Comb.rename("repo", "renamed-repo")

      new_dir = Path.join(tmp, "renamed-repo")
      updated_cell = Store.get(:cells, cell.id)
      assert updated_cell.worktree_path == Path.join(new_dir, "worktrees/ghost-1")

      updated_bee = Store.get(:ghosts, ghost.id)
      assert updated_bee.cell_path == Path.join(new_dir, "worktrees/ghost-1")
    end

    test "does NOT move directory when basename doesn't match old name", %{tmp: tmp} do
      # Add a comb with a custom name different from the directory basename
      dir = Path.join(tmp, "actual-dir")
      File.mkdir_p!(dir)
      {:ok, comb} = Comb.add(dir, name: "custom-name")

      assert {:ok, renamed} = Comb.rename("custom-name", "new-custom")
      assert renamed.name == "new-custom"
      # Path stays the same since basename("actual-dir") != "custom-name"
      assert renamed.path == comb.path
      assert File.dir?(dir)
    end
  end

  describe "merge_strategy field" do
    test "defaults to manual when not specified", %{tmp: tmp} do
      assert {:ok, comb} = Comb.add(tmp, name: "default-strategy")

      assert comb.merge_strategy == "manual"
    end

    test "can create comb with specific merge_strategy" do
      # Test that valid merge strategies are accepted as plain map fields
      {:ok, pr_comb} =
        Store.insert(:combs, %{name: "pr-comb", merge_strategy: "pr_branch"})

      assert pr_comb.merge_strategy == "pr_branch"

      {:ok, auto_comb} =
        Store.insert(:combs, %{name: "auto-comb", merge_strategy: "auto_merge"})

      assert auto_comb.merge_strategy == "auto_merge"
    end
  end
end
