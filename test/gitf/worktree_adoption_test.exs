defmodule GiTF.WorktreeAdoptionTest do
  @moduledoc """
  msn-b47135 (v0.65.228) anchored every fix and resolution op to the
  canonical worktree op, `GiTF.Ghosts.spawn_in_worktree/4` adopted the
  canonical shell, and the log said "spawned in existing worktree" — and
  all four ghosts still committed to their own `ghost/<id>` branch cut
  from origin/main, whose merge-back manufactured the very conflicts they
  had been spawned to resolve.

  The hand-off was lost between the two: `GiTF.Ghosts.start_worker/5`
  copies only an allowlist of options into the Worker's child spec, and
  `:shell_id` was not on it. The Worker, never told which worktree it had
  been handed, provisioned a fresh one.

  These tests pin the OUTCOME — one ghost, one worktree, one branch —
  rather than the option plumbing, because the plumbing is exactly what
  proved able to break silently.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Ghosts, Ops, Shell}
  alias GiTF.TestDriver.Assertions

  @tmp_dir System.tmp_dir!()

  setup do
    if !Process.whereis(GiTF.SectorSupervisor) do
      DynamicSupervisor.start_link(strategy: :one_for_one, name: GiTF.SectorSupervisor)
    end

    repo_path = create_temp_git_repo()
    gitf_root = create_gitf_workspace()

    {:ok, sector} =
      GiTF.Sector.add(repo_path, name: "adopt-sector-#{:erlang.unique_integer([:positive])}")

    {:ok, mission} =
      Archive.insert(:missions, %{name: "adopt-mission", status: "active"})

    %{sector: sector, mission: mission, gitf_root: gitf_root, repo_path: repo_path}
  end

  describe "spawn_in_worktree/4" do
    @tag timeout: 120_000
    test "the fix ghost continues in the adopted shell instead of cutting a sibling", ctx do
      %{shell: shell} = completed_impl_ghost(ctx)
      {:ok, fix_op} = create_op(ctx, "Fix validation issues (attempt 1)")

      {:ok, fix_ghost} =
        Ghosts.spawn_in_worktree(fix_op.id, shell.id, ctx.sector.id, ctx.gitf_root)

      await_ghost_stopped(fix_ghost.id)

      assert Archive.get(:ghosts, fix_ghost.id).shell_id == shell.id,
             "the fix ghost must record the adopted shell, not a fresh one"

      assert active_shells(ctx.sector.id) == [shell.id],
             "provisioning cut a second shell for the same sector — the sibling worktree"
    end

    @tag timeout: 120_000
    test "no ghost/<fix ghost id> branch is ever created", ctx do
      %{shell: shell} = completed_impl_ghost(ctx)
      {:ok, fix_op} = create_op(ctx, "Fix validation issues (attempt 1)")

      {:ok, fix_ghost} =
        Ghosts.spawn_in_worktree(fix_op.id, shell.id, ctx.sector.id, ctx.gitf_root)

      await_ghost_stopped(fix_ghost.id)

      refute branch_exists?(ctx.repo_path, "ghost/#{fix_ghost.id}"),
             "a sibling branch was created for the fix ghost"

      assert head_branch(shell.worktree_path) == shell.branch,
             "the adopted worktree was switched off the branch it must commit to"
    end

    @tag timeout: 120_000
    test "no sibling worktree directory appears on disk", ctx do
      %{shell: shell} = completed_impl_ghost(ctx)
      {:ok, fix_op} = create_op(ctx, "Fix validation issues (attempt 1)")

      {:ok, fix_ghost} =
        Ghosts.spawn_in_worktree(fix_op.id, shell.id, ctx.sector.id, ctx.gitf_root)

      await_ghost_stopped(fix_ghost.id)

      # `GiTF.Shell.create/3` lays worktrees down at <sector>/ghosts/<ghost_id>.
      # One directory per fix ghost is the physical shape of the defect.
      refute File.dir?(Path.join([ctx.repo_path, "ghosts", fix_ghost.id])),
             "a sibling worktree was cut for the fix ghost"

      assert File.dir?(shell.worktree_path),
             "the adopted worktree was destroyed"
    end
  end

  describe "revive/3" do
    @tag timeout: 120_000
    test "the reviving ghost reuses the dead ghost's worktree", ctx do
      %{ghost: dead, shell: shell, op: op} = completed_impl_ghost(ctx)

      Archive.update(:ghosts, dead.id, &%{&1 | status: "crashed"})
      Archive.update(:ops, op.id, &%{&1 | status: "failed"})

      {:ok, new_ghost} = Ghosts.revive(dead.id, ctx.gitf_root, claude_executable: "/bin/echo")
      await_ghost_stopped(new_ghost.id)

      assert Archive.get(:ghosts, new_ghost.id).shell_id == shell.id
      assert active_shells(ctx.sector.id) == [shell.id]
      refute branch_exists?(ctx.repo_path, "ghost/#{new_ghost.id}")
    end
  end

  # -- Helpers ----------------------------------------------------------------

  # A first ghost run to completion, so the sector has one real worktree on
  # one real branch — the canonical shell every later ghost must adopt.
  defp completed_impl_ghost(ctx) do
    {:ok, op} = create_op(ctx, "Implement it")

    {:ok, ghost} =
      Ghosts.spawn(op.id, ctx.sector.id, ctx.gitf_root,
        name: "impl-ghost",
        claude_executable: "/bin/echo",
        prompt: "hello"
      )

    await_ghost_stopped(ghost.id)

    shell = Archive.find_one(:shells, &(&1.ghost_id == ghost.id and &1[:status] == "active"))
    assert %{worktree_path: path} = shell
    assert File.dir?(path)

    %{ghost: ghost, shell: shell, op: op}
  end

  defp create_op(ctx, title) do
    Ops.create(%{title: title, mission_id: ctx.mission.id, sector_id: ctx.sector.id})
  end

  defp await_ghost_stopped(ghost_id) do
    Assertions.await(
      fn ->
        match?(%{status: s} when s in ["stopped", "crashed"], Archive.get(:ghosts, ghost_id))
      end,
      timeout: 60_000,
      interval: 200,
      message: "ghost #{ghost_id} never reached a terminal state"
    )
  end

  defp active_shells(sector_id) do
    Shell.list(sector_id: sector_id, status: "active") |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp branch_exists?(repo_path, branch) do
    {_out, code} =
      System.cmd("git", ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
        cd: repo_path,
        stderr_to_stdout: true
      )

    code == 0
  end

  defp head_branch(worktree_path) do
    {out, 0} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
        cd: worktree_path,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp create_temp_git_repo do
    path = Path.join(@tmp_dir, "gitf_adopt_repo_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)

    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@gitf.local"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)

    File.write!(Path.join(path, "README.md"), "# Test\n")
    System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "initial"], cd: path, stderr_to_stdout: true)

    {real_path, 0} =
      System.cmd("git", ["rev-parse", "--show-toplevel"], cd: path, stderr_to_stdout: true)

    on_exit(fn -> File.rm_rf(path) end)
    String.trim(real_path)
  end

  defp create_gitf_workspace do
    path = Path.join(@tmp_dir, "gitf_adopt_ws_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, ".gitf"))
    File.write!(Path.join([path, ".gitf", "config.toml"]), "")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
