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

    test "conflict commit stages ONLY conflicted files, not worktree residue",
         %{repo: repo, run: run} do
      File.write!(Path.join(repo, "residue.txt"), "v1\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "add residue file"])

      run.(["checkout", "-q", "-b", "side"])
      File.write!(Path.join(repo, "shared.txt"), "line1\nSIDE\nline3\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "side"])
      run.(["checkout", "-q", "main"])
      File.write!(Path.join(repo, "shared.txt"), "line1\nMAIN\nline3\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "main"])

      # Install-style residue present at merge time: untracked build output.
      # (Tracked modifications would make git refuse the merge outright.)
      File.write!(Path.join(repo, "untracked-residue.log"), "npm noise\n")

      assert {:conflicted, ["shared.txt"]} = Git.merge_union(repo, "side")

      # The merge commit contains the conflicted file, not the residue.
      {committed, 0} =
        System.cmd(@git, ["show", "--name-only", "--format=", "HEAD"], cd: repo)

      assert committed =~ "shared.txt"
      refute committed =~ "untracked-residue.log"
      assert File.exists?(Path.join(repo, "untracked-residue.log"))
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

  describe "restore_tracked_residue/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gitf_rr_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      run = fn args -> System.cmd(@git, args, cd: tmp, stderr_to_stdout: true) end
      run.(["init", "-q", "-b", "main"])
      run.(["config", "user.email", "t@t.dev"])
      run.(["config", "user.name", "t"])
      File.write!(Path.join(tmp, "package-lock.json"), "v1\n")
      File.write!(Path.join(tmp, "src.js"), "code\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp, run: run}
    end

    test "reverts tracked modifications, keeps untracked files", %{repo: repo} do
      # Simulate validation residue: tracked lockfile rewritten, untracked
      # build output dropped alongside.
      File.write!(Path.join(repo, "package-lock.json"), "v2-residue\n")
      File.write!(Path.join(repo, "build.log"), "untracked\n")

      assert Git.restore_tracked_residue(repo) == ["package-lock.json"]
      assert File.read!(Path.join(repo, "package-lock.json")) == "v1\n"
      assert File.exists?(Path.join(repo, "build.log"))
    end

    test "clean tree is a no-op", %{repo: repo} do
      assert Git.restore_tracked_residue(repo) == []
    end

    test "also clears staged-but-uncommitted residue", %{repo: repo, run: run} do
      File.write!(Path.join(repo, "package-lock.json"), "v2-residue\n")
      run.(["add", "package-lock.json"])

      assert Git.restore_tracked_residue(repo) == ["package-lock.json"]
      {out, 0} = System.cmd(@git, ["status", "--porcelain"], cd: repo)
      assert out == ""
    end
  end

  describe "unstage_uninstructed_lockfiles/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gitf_lf_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      run = fn args -> System.cmd(@git, args, cd: tmp, stderr_to_stdout: true) end
      run.(["init", "-q", "-b", "main"])
      run.(["config", "user.email", "t@t.dev"])
      run.(["config", "user.name", "t"])
      File.write!(Path.join(tmp, "package.json"), ~s({"name":"app"}\n))
      File.write!(Path.join(tmp, "package-lock.json"), ~s({"v":1}\n))
      run.(["add", "."])
      run.(["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp, run: run}
    end

    defp staged(repo) do
      {out, 0} = System.cmd(@git, ["diff", "--cached", "--name-only"], cd: repo)
      String.split(out, "\n", trim: true)
    end

    test "lockfile staged without its manifest is unstaged (install residue)",
         %{repo: repo, run: run} do
      # The cora PR #11 shape: source change + lockfile rewrite, package.json untouched.
      File.write!(Path.join(repo, "app.js"), "code\n")
      File.write!(Path.join(repo, "package-lock.json"), ~s({"v":2}\n))
      run.(["add", "-A"])

      assert Git.unstage_uninstructed_lockfiles(repo) == ["package-lock.json"]
      assert staged(repo) == ["app.js"]
      # The working-tree change survives — only the commit is protected.
      assert File.read!(Path.join(repo, "package-lock.json")) == ~s({"v":2}\n)
    end

    test "lockfile staged WITH its manifest is kept (intentional dependency change)",
         %{repo: repo, run: run} do
      File.write!(Path.join(repo, "package.json"), ~s({"name":"app","dependencies":{}}\n))
      File.write!(Path.join(repo, "package-lock.json"), ~s({"v":2}\n))
      run.(["add", "-A"])

      assert Git.unstage_uninstructed_lockfiles(repo) == []
      assert Enum.sort(staged(repo)) == ["package-lock.json", "package.json"]
    end

    test "nested lockfiles pair with the manifest in their own directory",
         %{repo: repo, run: run} do
      sub = Path.join(repo, "frontend")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "package.json"), ~s({"name":"fe"}\n))
      File.write!(Path.join(sub, "yarn.lock"), "v1\n")
      run.(["add", "-A"])
      run.(["commit", "-q", "-m", "add frontend"])

      # Residue in the subdir, manifest untouched.
      File.write!(Path.join(sub, "yarn.lock"), "v2\n")
      run.(["add", "-A"])

      assert Git.unstage_uninstructed_lockfiles(repo) == ["frontend/yarn.lock"]
      assert staged(repo) == []
    end

    test "no staged lockfiles → no-op", %{repo: repo, run: run} do
      File.write!(Path.join(repo, "app.js"), "code\n")
      run.(["add", "-A"])

      assert Git.unstage_uninstructed_lockfiles(repo) == []
      assert staged(repo) == ["app.js"]
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

  describe "conflict_marker_files/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gitf_cm_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      run = fn args -> System.cmd(@git, args, cd: tmp, stderr_to_stdout: true) end
      run.(["init", "-q", "-b", "main"])
      run.(["config", "user.email", "t@t.dev"])
      run.(["config", "user.name", "t"])
      File.write!(Path.join(tmp, "clean.rs"), "fn main() {}\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp, run: run}
    end

    test "finds committed markers — the msn-7683ac tree shape", %{repo: repo, run: run} do
      File.write!(Path.join(repo, "models.rs"), """
      enum Priority {
      <<<<<<< HEAD
          High,
      =======
          Critical,
      >>>>>>> ghost/ghost-503ee3
      }
      """)

      run.(["add", "."])
      run.(["commit", "-q", "-m", "union merge with markers"])

      assert Git.conflict_marker_files(repo) == ["models.rs"]
    end

    test "clean tree yields nothing", %{repo: repo} do
      assert Git.conflict_marker_files(repo) == []
    end

    test "scoping to changed files ignores marker-like content elsewhere",
         %{repo: repo, run: run} do
      # A committed fixture that legitimately CONTAINS marker syntax…
      File.write!(Path.join(repo, "fixture.txt"), "<<<<<<< HEAD\n=======\n>>>>>>> x\n")
      # …and the mission's own file, marker-laden.
      File.write!(Path.join(repo, "touched.ts"), "a\n=======\nb\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "both"])

      assert Git.conflict_marker_files(repo, ["touched.ts"]) == ["touched.ts"]
      # Scope entries that no longer exist are dropped, not passed to git.
      assert Git.conflict_marker_files(repo, ["gone.ts", "touched.ts"]) == ["touched.ts"]
    end

    test "marker-like but non-marker lines do not trip the scan", %{repo: repo, run: run} do
      File.write!(Path.join(repo, "notes.md"), """
      ==== four equals is a heading underline
      ========== ten equals is a divider
      <<<<<<<< eight angles is not a marker
      x <<<<<<< not at line start
      """)

      run.(["add", "."])
      run.(["commit", "-q", "-m", "lookalikes"])

      assert Git.conflict_marker_files(repo) == []
    end

    test "conflict_marker_excerpt gives file:line:content hits", %{repo: repo, run: run} do
      File.write!(Path.join(repo, "x.rs"), "a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> ghost/g\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "markers"])

      excerpt = Git.conflict_marker_excerpt(repo, ["x.rs"])
      assert Enum.any?(excerpt, &String.starts_with?(&1, "x.rs:2:<<<<<<<"))
      assert Enum.any?(excerpt, &(&1 == "x.rs:4:======="))
      assert length(excerpt) == 3
    end

    test "diff3-style base markers are caught", %{repo: repo, run: run} do
      File.write!(Path.join(repo, "d3.txt"), "||||||| merged common ancestors\n")
      run.(["add", "."])
      run.(["commit", "-q", "-m", "diff3"])

      assert Git.conflict_marker_files(repo) == ["d3.txt"]
    end
  end
end
