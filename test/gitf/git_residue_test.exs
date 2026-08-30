defmodule GiTF.GitResidueTest do
  @moduledoc """
  The runtime probe writes its screenshots to `.gitf-probe/` INSIDE the
  ghost's worktree, and its throwaway `$HOME` to `.gitf-probe-home/`.
  Neither is the ghost's work, and both did two kinds of damage:

    1. Every fix op's auto-commit swept the new PNGs into the mission
       branch — the same class as the lockfile leak that shipped 600
       lines of `package-lock.json` churn in cora PR #11.
    2. Worse and quieter: they changed `git status --porcelain`, which is
       half of `tree_fingerprint/1`. The exec-validation verdict cache
       keys on that fingerprint, so it could never hit — every fix round
       re-paid `npm ci` + build under the sector lock to re-derive a
       verdict for a tree whose only change was a screenshot.
  """
  use ExUnit.Case, async: true

  alias GiTF.Git

  # Absolute path, resolved once, with a fallback: `PATH` is a
  # process-global in the BEAM, and `runtime/{claude,kimi,copilot}_test`
  # each set it to "/empty" for the duration of a test. Anything that
  # resolves `git` off PATH while that window is open gets nil.
  @git System.find_executable("git") || "/usr/bin/git"

  setup do
    wt = Path.join(System.tmp_dir!(), "gitf_residue_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(wt)
    on_exit(fn -> File.rm_rf(wt) end)

    git = fn args -> System.cmd(@git, args, cd: wt, stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "t@t.dev"])
    git.(["config", "user.name", "t"])
    File.write!(Path.join(wt, "README.md"), "base\n")
    git.(["add", "-A"])
    git.(["commit", "-qm", "base"])

    %{wt: wt, git: git}
  end

  defp write_probe_artifacts!(wt) do
    File.mkdir_p!(Path.join(wt, ".gitf-probe"))
    File.write!(Path.join([wt, ".gitf-probe", "boot.png"]), "PNG#{:rand.uniform(10_000)}")
    File.write!(Path.join([wt, ".gitf-probe", "final.png"]), "PNG#{:rand.uniform(10_000)}")

    File.mkdir_p!(Path.join(wt, ".gitf-probe-home"))
    File.write!(Path.join([wt, ".gitf-probe-home", ".config"]), "junk")
  end

  defp staged(wt) do
    {out, 0} = System.cmd(@git, ["diff", "--cached", "--name-only"], cd: wt)
    out |> String.split("\n", trim: true)
  end

  describe "tree_fingerprint/1 ignores probe residue" do
    test "a tree that differs only by probe artifacts has the SAME fingerprint", %{wt: wt} do
      before = Git.tree_fingerprint(wt)
      assert is_binary(before)

      write_probe_artifacts!(wt)

      assert Git.tree_fingerprint(wt) == before,
             "probe screenshots must not churn the verdict cache's key"
    end

    test "a second probe run with different screenshots still does not move it", %{wt: wt} do
      write_probe_artifacts!(wt)
      first = Git.tree_fingerprint(wt)

      write_probe_artifacts!(wt)

      assert Git.tree_fingerprint(wt) == first
    end

    test "REAL work still moves the fingerprint", %{wt: wt} do
      write_probe_artifacts!(wt)
      before = Git.tree_fingerprint(wt)

      File.write!(Path.join(wt, "feature.ex"), "defmodule Feature do\nend\n")

      refute Git.tree_fingerprint(wt) == before,
             "the cache must still invalidate when the ghost changes something"
    end

    test "a commit still moves the fingerprint", %{wt: wt, git: git} do
      write_probe_artifacts!(wt)
      before = Git.tree_fingerprint(wt)

      File.write!(Path.join(wt, "feature.ex"), "defmodule Feature do\nend\n")
      git.(["add", "feature.ex"])
      git.(["commit", "-qm", "work"])

      refute Git.tree_fingerprint(wt) == before
    end
  end

  describe "unstage_residue/1" do
    test "drops probe artifacts and .claude from the index, keeping real work", %{
      wt: wt,
      git: git
    } do
      write_probe_artifacts!(wt)
      File.mkdir_p!(Path.join(wt, ".claude"))
      File.write!(Path.join([wt, ".claude", "settings.json"]), "{}")
      File.write!(Path.join(wt, "feature.ex"), "defmodule Feature do\nend\n")

      git.(["add", "-A"])
      assert Enum.any?(staged(wt), &String.starts_with?(&1, ".gitf-probe/"))

      assert :ok = Git.unstage_residue(wt)

      remaining = staged(wt)
      assert remaining == ["feature.ex"]
    end

    test "a clean index is not an error", %{wt: wt} do
      assert :ok = Git.unstage_residue(wt)
      assert staged(wt) == []
    end

    test "the working-tree files survive — only the commit is protected", %{wt: wt, git: git} do
      write_probe_artifacts!(wt)
      git.(["add", "-A"])
      Git.unstage_residue(wt)

      assert File.exists?(Path.join([wt, ".gitf-probe", "boot.png"]))
    end
  end

  describe "residue_paths/0" do
    test "names both probe directories and .claude" do
      paths = Git.residue_paths()

      assert ".claude/" in paths
      assert ".gitf-probe/" in paths
      assert ".gitf-probe-home/" in paths
    end
  end
end
