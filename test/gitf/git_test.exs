defmodule GiTF.GitTest do
  use ExUnit.Case, async: true

  alias GiTF.Git

  # Absolute path so subprocess spawns survive other tests' temporary
  # PATH narrowing (env vars are process-global; System.cmd raises
  # :enoent when the executable can't be resolved).
  @git System.find_executable("git")

  describe "local_path?/1" do
    test "recognizes absolute paths" do
      assert Git.local_path?("/home/user/repo")
      assert Git.local_path?("/tmp/project")
    end

    test "recognizes relative paths starting with dot" do
      assert Git.local_path?("./my-repo")
      assert Git.local_path?("../parent-repo")
    end

    test "recognizes home-relative paths" do
      assert Git.local_path?("~/projects/repo")
    end

    test "recognizes bare directory names as local" do
      assert Git.local_path?("my-project")
      assert Git.local_path?("some/nested/path")
    end

    test "rejects HTTPS URLs" do
      refute Git.local_path?("https://github.com/user/repo.git")
      refute Git.local_path?("http://example.com/repo")
    end

    test "rejects SSH URLs" do
      refute Git.local_path?("git@github.com:user/repo.git")
    end

    test "rejects git:// protocol" do
      refute Git.local_path?("git://example.com/repo.git")
    end
  end

  describe "git_version/0" do
    test "returns a version string when git is installed" do
      assert {:ok, version} = Git.git_version()
      assert version =~ ~r/\d+\.\d+/
    end
  end

  describe "merge_union/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gitf_mu_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      run = fn args -> System.cmd(@git, args, cd: tmp, stderr_to_stdout: true) end
      run.(["init", "-q", "-b", "main"])
      run.(["config", "user.email", "t@t.dev"])
      run.(["config", "user.name", "t"])
      File.write!(Path.join(tmp, "shared.txt"), "line1\nline2\nline3\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp, run: run}
    end

    test "clean merge returns :ok", %{repo: repo, run: run} do
      run.(["checkout", "-q", "-b", "feature"])
      File.write!(Path.join(repo, "feature.txt"), "new\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "feature"])
      run.(["checkout", "-q", "main"])

      assert Git.merge_union(repo, "feature") == :ok
      assert File.exists?(Path.join(repo, "feature.txt"))
    end

    test "content conflict commits WITH markers — no work is lost", %{repo: repo, run: run} do
      # Two branches editing the same line — guaranteed content conflict.
      run.(["checkout", "-q", "-b", "side-a"])
      File.write!(Path.join(repo, "shared.txt"), "line1\nA-CHANGE\nline3\n")
      run.(["commit", "-q", "-am", "a"])
      run.(["checkout", "-q", "main"])
      File.write!(Path.join(repo, "shared.txt"), "line1\nB-CHANGE\nline3\n")
      run.(["commit", "-q", "-am", "b"])

      assert {:conflicted, ["shared.txt"]} = Git.merge_union(repo, "side-a")

      # The merge is COMMITTED (clean status, no MERGE_HEAD)…
      {status, 0} = run.(["status", "--porcelain"])
      assert String.trim(status) == ""
      refute File.exists?(Path.join(repo, ".git/MERGE_HEAD"))

      # …and BOTH sides survive in the file, wrapped in markers.
      content = File.read!(Path.join(repo, "shared.txt"))
      assert content =~ "A-CHANGE"
      assert content =~ "B-CHANGE"
      assert content =~ "<<<<<<<"
      assert content =~ ">>>>>>>"
    end

    test "unknown branch aborts and returns error", %{repo: repo} do
      assert {:error, _} = Git.merge_union(repo, "no-such-branch")
      refute File.exists?(Path.join(repo, ".git/MERGE_HEAD"))
    end

    test "already up to date is :ok", %{repo: repo, run: run} do
      run.(["branch", "twin"])
      assert Git.merge_union(repo, "twin") == :ok
    end
  end

  describe "safe_rollback/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gitf_safe_rb_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      run = fn args -> System.cmd(@git, args, cd: tmp, stderr_to_stdout: true) end
      run.(["init", "-q"])
      run.(["config", "user.email", "t@t.dev"])
      run.(["config", "user.name", "t"])
      File.write!(Path.join(tmp, "committed.txt"), "v1\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp, run: run}
    end

    test "preserves uncommitted human WIP instead of deleting it", %{repo: repo} do
      # Modify a tracked file and add an untracked one — the kind of WIP that
      # `reset --hard` + `clean -fd` would silently destroy.
      File.write!(Path.join(repo, "committed.txt"), "human-edit\n")
      File.write!(Path.join(repo, "untracked.txt"), "human-new\n")

      assert {:ok, {:stashed, _label}} = Git.safe_rollback(repo, "mission-1")

      # Working tree is clean now (changes moved to a stash)...
      {status, 0} = System.cmd(@git, ["status", "--porcelain"], cd: repo, stderr_to_stdout: true)
      assert String.trim(status) == ""

      # ...but nothing was destroyed: the stash holds the tracked + untracked work.
      {stash_list, 0} = System.cmd(@git, ["stash", "list"], cd: repo, stderr_to_stdout: true)
      assert stash_list =~ "gitf-failed-mission-1"

      {_, 0} = System.cmd(@git, ["stash", "pop"], cd: repo, stderr_to_stdout: true)
      assert File.read!(Path.join(repo, "committed.txt")) == "human-edit\n"
      assert File.read!(Path.join(repo, "untracked.txt")) == "human-new\n"
    end

    test "is a no-op on a clean tree", %{repo: repo} do
      assert :ok = Git.safe_rollback(repo, "mission-2")
    end

    test "aborts an in-progress merge without touching WIP", %{repo: repo, run: run} do
      # Create divergent branches that conflict on the same file.
      run.(["checkout", "-q", "-b", "feature"])
      File.write!(Path.join(repo, "committed.txt"), "feature\n")
      run.(["commit", "-qam", "feature"])
      run.(["checkout", "-q", "main"]) |> elem(1) == 0 || run.(["checkout", "-q", "master"])
      File.write!(Path.join(repo, "committed.txt"), "mainline\n")
      run.(["commit", "-qam", "mainline"])

      # Start a merge that conflicts (leaves MERGE_HEAD / in-progress state).
      run.(["merge", "feature"])

      assert :ok = Git.safe_rollback(repo, "mission-3")
      refute File.exists?(Path.join(repo, ".git/MERGE_HEAD"))
    end
  end

  describe "repo?/1" do
    test "returns false for a non-repo directory" do
      tmp = Path.join(System.tmp_dir!(), "gitf_git_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      refute Git.repo?(tmp)
    end

    test "returns false for a non-existent path" do
      refute Git.repo?("/nonexistent/path/#{:erlang.unique_integer([:positive])}")
    end
  end
end
