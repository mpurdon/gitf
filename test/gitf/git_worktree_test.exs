defmodule GiTF.Git.WorktreeTest do
  use ExUnit.Case, async: true

  alias GiTF.Git

  @tmp_dir System.tmp_dir!()

  # Each test gets a fresh git repo so worktree operations are isolated.
  #
  # On macOS, /var is a symlink to /private/var. Git's porcelain output
  # resolves symlinks, so we must compare against the real (resolved) path.
  # We use File.cwd! trick via git itself to get the canonical path.

  defp create_temp_git_repo do
    name = "gitf_wt_test_#{:erlang.unique_integer([:positive])}"
    path = Path.join(@tmp_dir, name)
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    # Need at least one commit for worktrees to function
    hello_file = Path.join(path, "README.md")
    File.write!(hello_file, "# Test\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)

    # Resolve the real path (handles macOS /var -> /private/var symlink)
    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"],
        cd: path,
        stderr_to_stdout: true
      )

    real_path = String.trim(real_path)

    on_exit(fn -> File.rm_rf!(path) end)
    real_path
  end

  describe "worktree_add/3" do
    test "creates a new worktree with a new branch" do
      repo = create_temp_git_repo()
      wt_path = Path.join(repo, "ghosts/ghost-test1")

      assert {:ok, ^wt_path} = Git.worktree_add(repo, wt_path, "ghost/ghost-test1")
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "README.md"))
    end

    test "returns error when branch already exists" do
      repo = create_temp_git_repo()
      wt1 = Path.join(repo, "ghosts/ghost-dup1")
      wt2 = Path.join(repo, "ghosts/ghost-dup2")

      {:ok, _} = Git.worktree_add(repo, wt1, "ghost/dup-branch")
      assert {:error, msg} = Git.worktree_add(repo, wt2, "ghost/dup-branch")
      assert is_binary(msg)
    end
  end

  describe "worktree_remove/3" do
    test "removes an existing worktree" do
      repo = create_temp_git_repo()
      wt_path = Path.join(repo, "ghosts/ghost-remove")
      {:ok, _} = Git.worktree_add(repo, wt_path, "ghost/ghost-remove")

      assert :ok = Git.worktree_remove(repo, wt_path)
      refute File.dir?(wt_path)
    end

    test "returns error for non-existent worktree" do
      repo = create_temp_git_repo()
      assert {:error, _msg} = Git.worktree_remove(repo, "/nonexistent/wt")
    end
  end

  describe "worktree_list/1" do
    test "lists the main worktree by default" do
      repo = create_temp_git_repo()

      assert {:ok, worktrees} = Git.worktree_list(repo)
      assert length(worktrees) >= 1
      assert hd(worktrees).path == repo
    end

    test "includes additional worktrees" do
      repo = create_temp_git_repo()
      wt_path = Path.join(repo, "ghosts/ghost-listed")
      {:ok, _} = Git.worktree_add(repo, wt_path, "ghost/ghost-listed")

      assert {:ok, worktrees} = Git.worktree_list(repo)
      assert length(worktrees) == 2

      paths = Enum.map(worktrees, & &1.path)
      assert wt_path in paths
    end

    test "parses branch information" do
      repo = create_temp_git_repo()
      wt_path = Path.join(repo, "ghosts/ghost-branch")
      {:ok, _} = Git.worktree_add(repo, wt_path, "ghost/ghost-branch")

      {:ok, worktrees} = Git.worktree_list(repo)
      wt = Enum.find(worktrees, &(&1.path == wt_path))

      assert wt != nil, "expected to find worktree at #{wt_path}"
      assert wt.branch == "refs/heads/ghost/ghost-branch"
      assert is_binary(wt.head)
    end
  end

  describe "branch_delete/2" do
    test "deletes a branch that is not checked out" do
      repo = create_temp_git_repo()
      # Create and remove a worktree so the branch exists but is not checked out
      wt_path = Path.join(repo, "ghosts/ghost-delb")
      {:ok, _} = Git.worktree_add(repo, wt_path, "ghost/ghost-delb")
      :ok = Git.worktree_remove(repo, wt_path)

      assert :ok = Git.branch_delete(repo, "ghost/ghost-delb")
    end

    test "returns error for non-existent branch" do
      repo = create_temp_git_repo()
      assert {:error, _msg} = Git.branch_delete(repo, "no-such-branch")
    end
  end
end
