defmodule GiTF.ShellTest do
  use GiTF.StoreCase

  alias GiTF.Shell
  alias GiTF.Archive

  @tmp_dir System.tmp_dir!()

  setup do
    # Create a temp git repo to serve as a sector
    repo_path = create_temp_git_repo()

    # Register the sector in the database
    {:ok, sector} =
      GiTF.Sector.add(repo_path, name: "shell-test-sector-#{:erlang.unique_integer([:positive])}")

    # Create a ghost record
    {:ok, ghost} = Archive.insert(:ghosts, %{name: "test-ghost", status: "starting"})

    %{sector: sector, ghost: ghost, repo_path: repo_path}
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
    test "creates a shell with worktree and database record", %{sector: sector, ghost: ghost} do
      assert {:ok, shell} = Shell.create(sector.id, ghost.id)

      assert shell.sector_id == sector.id
      assert shell.ghost_id == ghost.id
      assert shell.branch == "ghost/#{ghost.id}"
      assert shell.status == "active"
      assert String.starts_with?(shell.id, "cel-")

      expected_path = Path.join([sector.path, "ghosts", ghost.id])
      assert shell.worktree_path == expected_path
      assert File.dir?(expected_path)
    end

    test "accepts custom branch name", %{sector: sector, ghost: ghost} do
      assert {:ok, shell} = Shell.create(sector.id, ghost.id, branch: "feature/custom")
      assert shell.branch == "feature/custom"
    end

    test "returns error for nonexistent sector", %{ghost: ghost} do
      assert {:error, :not_found} = Shell.create("sec-000000", ghost.id)
    end

    test "returns error for sector without a path", %{ghost: ghost} do
      # Insert a sector with nil path
      {:ok, remote_sector} =
        Archive.insert(:sectors, %{
          name: "remote-only-#{:erlang.unique_integer([:positive])}",
          repo_url: "https://example.com/repo",
          path: nil
        })

      assert {:error, :sector_has_no_path} = Shell.create(remote_sector.id, ghost.id)
    end
  end

  describe "get/1" do
    test "retrieves a shell by ID", %{sector: sector, ghost: ghost} do
      {:ok, created} = Shell.create(sector.id, ghost.id)
      assert {:ok, found} = Shell.get(created.id)
      assert found.id == created.id
    end

    test "returns error for unknown ID" do
      assert {:error, :not_found} = Shell.get("cel-000000")
    end
  end

  describe "list/1" do
    test "lists all shells", %{sector: sector, ghost: ghost} do
      {:ok, _} = Shell.create(sector.id, ghost.id)

      shells = Shell.list()
      assert length(shells) >= 1
    end

    test "filters by sector_id", %{sector: sector, ghost: ghost} do
      {:ok, _} = Shell.create(sector.id, ghost.id)

      shells = Shell.list(sector_id: sector.id)
      assert length(shells) >= 1
      assert Enum.all?(shells, &(&1.sector_id == sector.id))
    end

    test "filters by status", %{sector: sector, ghost: ghost} do
      {:ok, _} = Shell.create(sector.id, ghost.id)

      active = Shell.list(status: "active")
      assert length(active) >= 1

      removed = Shell.list(status: "removed")
      # Could be 0 if no shells removed yet in this test
      assert is_list(removed)
    end
  end

  describe "remove/2" do
    test "removes worktree and marks record as removed", %{sector: sector, ghost: ghost} do
      {:ok, shell} = Shell.create(sector.id, ghost.id)
      assert File.dir?(shell.worktree_path)

      assert {:ok, removed} = Shell.remove(shell.id)
      assert removed.status == "removed"
      assert removed.removed_at != nil
      refute File.dir?(shell.worktree_path)
    end

    test "returns error for nonexistent shell" do
      assert {:error, :not_found} = Shell.remove("cel-000000")
    end
  end

  describe "cleanup_orphans/0" do
    test "marks shells as removed when ghost is stopped", %{sector: sector} do
      # Create a ghost that is stopped
      {:ok, stopped_ghost} = Archive.insert(:ghosts, %{name: "stopped-ghost", status: "stopped"})

      {:ok, _shell} = Shell.create(sector.id, stopped_ghost.id)

      assert {:ok, count} = Shell.cleanup_orphans()
      assert count >= 1
    end

    test "does not touch shells with active ghosts", %{sector: sector, ghost: ghost} do
      # ghost defaults to "starting" status which is active
      {:ok, shell} = Shell.create(sector.id, ghost.id)

      {:ok, _count} = Shell.cleanup_orphans()

      {:ok, still_active} = Shell.get(shell.id)
      assert still_active.status == "active"
    end
  end
end
