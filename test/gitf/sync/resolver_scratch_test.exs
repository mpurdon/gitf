defmodule GiTF.Sync.ResolverScratchTest do
  @moduledoc """
  The scratch-worktree merge invariant, exercised against real git repos:
  the shared clone's target only ever advances by a fast-forward to a
  finished merge, and no outcome — success, conflict, or escalation —
  leaves the shared clone dirty, mid-merge, or holding scratch debris.
  """

  use ExUnit.Case, async: false

  alias GiTF.Archive
  alias GiTF.Sync.Resolver

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_resolver_#{:erlang.unique_integer([:positive])}")
    store = Path.join(tmp, "store")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(store)
    File.mkdir_p!(repo)

    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = Archive.start_link(data_dir: store)
    on_exit(fn -> File.rm_rf!(tmp) end)

    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.email", "test@gitf"])
    git!(repo, ["config", "user.name", "gitf-test"])
    File.write!(Path.join(repo, "app.txt"), "line one\nline two\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "initial"])

    {:ok, sector} =
      Archive.insert(:sectors, %{name: "repo", path: repo, sync_strategy: "auto_merge"})

    %{repo: repo, sector: sector}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    out
  end

  defp git(repo, args) do
    {out, _code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  defp make_op_and_shell(sector, branch) do
    {:ok, op} =
      Archive.insert(:ops, %{
        title: "t",
        sector_id: sector.id,
        status: "done",
        mission_id: nil,
        description: "test op"
      })

    {:ok, shell} =
      Archive.insert(:shells, %{branch: branch, sector_id: sector.id, ghost_id: nil})

    {op, shell}
  end

  defp assert_shared_clone_pristine(repo) do
    refute File.exists?(Path.join(repo, ".git/MERGE_HEAD")),
           "shared clone left mid-merge"

    assert git(repo, ["status", "--porcelain"]) == "",
           "shared clone left dirty"

    scratch_branches =
      git(repo, ["branch", "--list", "gitf/sync-*"]) |> String.split("\n", trim: true)

    assert scratch_branches == [], "scratch branches left behind: #{inspect(scratch_branches)}"

    leftovers =
      Path.join(repo, "ghosts")
      |> File.ls()
      |> case do
        {:ok, entries} -> Enum.filter(entries, &String.starts_with?(&1, "sync-"))
        _ -> []
      end

    assert leftovers == [], "scratch worktrees left behind: #{inspect(leftovers)}"
  end

  test "a clean merge fast-forwards target and leaves no trace", %{repo: repo, sector: sector} do
    git!(repo, ["checkout", "-b", "ghost/clean"])
    File.write!(Path.join(repo, "new.txt"), "new file\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "ghost adds new file"])
    git!(repo, ["checkout", "main"])
    before_sha = git(repo, ["rev-parse", "HEAD"])

    {op, shell} = make_op_and_shell(sector, "ghost/clean")

    assert {:ok, :merged, 0} = Resolver.resolve(op.id, shell.id)

    # Target advanced to a merge commit containing the ghost's work.
    assert git(repo, ["rev-parse", "HEAD"]) != before_sha
    assert File.exists?(Path.join(repo, "new.txt"))
    assert git(repo, ["log", "--merges", "--oneline"]) =~ "Sync ghost/clean"

    assert_shared_clone_pristine(repo)
  end

  test "an unresolvable conflict escalates without ever dirtying the shared clone",
       %{repo: repo, sector: sector} do
    # Both sides rewrite the same line: tier 0 conflicts, tier 1 cannot
    # auto-resolve (not additive, touched by both), and tier 2 bails before
    # any model call because we conflict more files than its cap.
    for i <- 1..6 do
      File.write!(Path.join(repo, "f#{i}.txt"), "base #{i}\n")
    end

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "seed files"])

    git!(repo, ["checkout", "-b", "ghost/conflict"])

    for i <- 1..6 do
      File.write!(Path.join(repo, "f#{i}.txt"), "ghost version #{i}\n")
    end

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "ghost edits"])

    git!(repo, ["checkout", "main"])

    for i <- 1..6 do
      File.write!(Path.join(repo, "f#{i}.txt"), "main version #{i}\n")
    end

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "main edits"])
    before_sha = git(repo, ["rev-parse", "HEAD"])

    {op, shell} = make_op_and_shell(sector, "ghost/conflict")

    # Tier 3 creates a re-imagine op and the escalation ends in exhaustion —
    # the point here is not the verdict but what the shared clone looks like
    # afterwards.
    assert {:error, _reason, _tier} = Resolver.resolve(op.id, shell.id)

    assert git(repo, ["rev-parse", "HEAD"]) == before_sha, "target must not move on failure"
    assert File.read!(Path.join(repo, "f1.txt")) == "main version 1\n"
    assert_shared_clone_pristine(repo)
  end

  test "a leftover scratch worktree from a killed predecessor does not block the next run",
       %{repo: repo, sector: sector} do
    git!(repo, ["checkout", "-b", "ghost/retry"])
    File.write!(Path.join(repo, "retry.txt"), "work\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "ghost work"])
    git!(repo, ["checkout", "main"])

    {op, shell} = make_op_and_shell(sector, "ghost/retry")

    # Simulate a brutal kill mid-merge: the scratch worktree and branch exist,
    # half-populated, exactly as Process.exit(:kill) would leave them.
    stale = Path.join([repo, "ghosts", "sync-#{op.id}-t0"])
    git!(repo, ["worktree", "add", stale, "-B", "gitf/sync-#{op.id}-t0", "main"])

    assert {:ok, :merged, 0} = Resolver.resolve(op.id, shell.id)
    assert File.exists?(Path.join(repo, "retry.txt"))
    assert_shared_clone_pristine(repo)
  end
end
