defmodule GiTF.ShellOriginBaseTest do
  use GiTF.StoreCase

  @git System.find_executable("git")

  defp git!(dir, args) do
    {out, 0} = System.cmd(@git, args, cd: dir, stderr_to_stdout: true)
    out
  end

  # A bare "origin" and a clone whose local main has diverged from it —
  # the state every GitHub squash-merge or history rewrite produces.
  defp diverged_repos(tmp) do
    origin = Path.join(tmp, "origin.git")
    clone = Path.join(tmp, "clone")
    seed = Path.join(tmp, "seed")

    File.mkdir_p!(seed)
    git!(seed, ["init", "-q", "-b", "main"])
    git!(seed, ["config", "user.email", "t@t.dev"])
    git!(seed, ["config", "user.name", "t"])
    File.write!(Path.join(seed, "a.txt"), "v1\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-q", "-m", "init"])
    git!(seed, ["clone", "-q", "--bare", ".", origin])

    git!(tmp, ["clone", "-q", origin, clone])
    git!(clone, ["config", "user.email", "t@t.dev"])
    git!(clone, ["config", "user.name", "t"])

    # Local-only divergence: the factory's own merge commit.
    File.write!(Path.join(clone, "local.txt"), "local\n")
    git!(clone, ["add", "."])
    git!(clone, ["commit", "-q", "-m", "local factory merge"])

    # Remote-side divergence: a squash commit pushed from elsewhere.
    File.write!(Path.join(seed, "squashed.txt"), "squashed\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-q", "-m", "squash-merged PR"])
    git!(seed, ["push", "-q", origin, "main"])

    clone
  end

  @tag :tmp_dir
  test "worktrees base on freshly-fetched origin/main, not diverged local main", %{
    tmp_dir: tmp
  } do
    clone = diverged_repos(tmp)

    {:ok, _sector} =
      GiTF.Archive.put(:sectors, %{id: "sec-origbase", name: "origbase", path: clone})

    {:ok, shell} = GiTF.Shell.create("sec-origbase", "ghost-origbase")
    files = File.ls!(shell.worktree_path)

    # Has origin's squash commit, does NOT have the local-only commit.
    assert "squashed.txt" in files
    refute "local.txt" in files

    GiTF.Shell.remove(shell.id, force: true)
  end

  @tag :tmp_dir
  test "remoteless sectors fall back to local HEAD", %{tmp_dir: tmp} do
    repo = Path.join(tmp, "loner")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@t.dev"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "only.txt"), "x\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])

    {:ok, _sector} = GiTF.Archive.put(:sectors, %{id: "sec-loner", name: "loner", path: repo})

    {:ok, shell} = GiTF.Shell.create("sec-loner", "ghost-loner")
    assert "only.txt" in File.ls!(shell.worktree_path)

    GiTF.Shell.remove(shell.id, force: true)
  end
end
