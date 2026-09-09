defmodule GiTF.Major.ConsolidateOpTest do
  @moduledoc """
  Merge-as-you-go (execution-efficiency A2). The verified op's branch
  lands on the canonical tip at completion when it merges CLEAN; a
  conflict is aborted — never committed with markers, this tree is what
  the next op forks from — and left for the endgame; a canonical
  worktree with a live ghost in it is not touched.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Major.Topology

  setup do
    root = Path.join(System.tmp_dir!(), "gitf_a2_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git = fn args, dir -> {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true) end
    git.(["init", "-b", "main"], root)
    git.(["config", "user.email", "t@t"], root)
    git.(["config", "user.name", "t"], root)
    File.write!(Path.join(root, "a.txt"), "one\n")
    File.write!(Path.join(root, "b.txt"), "left\n")
    git.(["add", "."], root)
    git.(["commit", "-qm", "base"], root)

    # The canonical worktree: op 1's, on ghost/g1, one commit ahead.
    canon = Path.join(root, "wt-g1")
    git.(["worktree", "add", "-q", "-b", "ghost/g1", canon, "main"], root)
    File.write!(Path.join(canon, "a.txt"), "one\ntwo\n")
    git.(["commit", "-qam", "op1"], canon)

    {:ok, sector} = Archive.insert(:sectors, %{name: "a2", path: root})

    {:ok, mission} =
      Archive.insert(:missions, %{name: "a2", sector_id: sector.id, status: "active"})

    {:ok, shell1} = Archive.insert(:shells, %{worktree_path: canon, ghost_id: "g1"})

    {:ok, _} =
      Archive.insert(:ghosts, %{
        id: "g1",
        name: "g1",
        status: "stopped",
        shell_id: shell1.id,
        shell_path: canon
      })

    {:ok, op1} =
      Archive.insert(:ops, %{
        mission_id: mission.id,
        status: "done",
        ghost_id: "g1",
        verification_status: "passed",
        inserted_at: DateTime.utc_now()
      })

    %{root: root, canon: canon, git: git, sector: sector, mission: mission, op1: op1}
  end

  defp sibling(ctx, ghost, edit) do
    wt = Path.join(ctx.root, "wt-#{ghost}")
    ctx.git.(["worktree", "add", "-q", "-b", "ghost/#{ghost}", wt, "main"], ctx.root)
    edit.(wt)
    ctx.git.(["add", "."], wt)
    ctx.git.(["commit", "-qm", ghost], wt)

    {:ok, shell} = Archive.insert(:shells, %{worktree_path: wt, ghost_id: ghost})

    {:ok, _} =
      Archive.insert(:ghosts, %{
        id: ghost,
        name: ghost,
        status: "stopped",
        shell_id: shell.id,
        shell_path: wt
      })

    {:ok, op} =
      Archive.insert(:ops, %{
        mission_id: ctx.mission.id,
        status: "done",
        ghost_id: ghost,
        verification_status: "passed",
        inserted_at: DateTime.utc_now()
      })

    op
  end

  defp mission!(ctx), do: elem(GiTF.Missions.get(ctx.mission.id), 1)

  test "a clean sibling branch is merged so the canonical tip carries all done work", ctx do
    # g2 is the newest done op, so it becomes the canonical; g1's work is merged into it.
    _op2 = sibling(ctx, "g2", fn wt -> File.write!(Path.join(wt, "b.txt"), "right\n") end)
    wt2 = Path.join(ctx.root, "wt-g2")

    assert {:ok, ["ghost/g1"], []} = Topology.consolidate_on_completion(mission!(ctx))
    assert File.read!(Path.join(wt2, "a.txt")) == "one\ntwo\n"
    assert File.read!(Path.join(wt2, "b.txt")) == "right\n"

    # Idempotent: the endgame's pass finds nothing left to merge.
    assert {:ok, [], []} = Topology.consolidate_on_completion(mission!(ctx))
  end

  test "a conflicting branch is aborted, never committed with markers", ctx do
    _op2 = sibling(ctx, "g2", fn wt -> File.write!(Path.join(wt, "a.txt"), "one\nTWO\n") end)
    wt2 = Path.join(ctx.root, "wt-g2")

    assert {:ok, [], [{"ghost/g1", {:conflict, ["a.txt"]}}]} =
             Topology.consolidate_on_completion(mission!(ctx))

    assert File.read!(Path.join(wt2, "a.txt")) == "one\nTWO\n"
    assert GiTF.Git.conflict_marker_files(wt2) == []
    {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: wt2)
    assert out == ""
  end

  test "a canonical worktree with a live ghost in it is left alone", ctx do
    _op2 = sibling(ctx, "g2", fn wt -> File.write!(Path.join(wt, "b.txt"), "right\n") end)
    wt2 = Path.join(ctx.root, "wt-g2")

    {:ok, _} =
      Archive.insert(:ghosts, %{id: "g3", name: "g3", status: "working", shell_path: wt2})

    assert {:skipped, :canonical_in_use} = Topology.consolidate_on_completion(mission!(ctx))
    refute GiTF.Git.merged?(wt2, "ghost/g1")
  end

  test "tournament missions never consolidate on completion", ctx do
    _op2 = sibling(ctx, "g2", fn wt -> File.write!(Path.join(wt, "b.txt"), "right\n") end)
    m = mission!(ctx)
    m = %{m | ops: Enum.map(m.ops, &Map.put(&1, :variant, "v1"))}
    assert {:skipped, :tournament} = Topology.consolidate_on_completion(m)
  end

  test "a single done op has nothing to merge", ctx do
    assert {:ok, [], []} = Topology.consolidate_on_completion(mission!(ctx))
  end
end
