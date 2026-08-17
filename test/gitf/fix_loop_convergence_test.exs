defmodule GiTF.FixLoopConvergenceTest do
  # Regression for msn-8933dc's 12-cycle fix loop: the incremented
  # FixContext lived only on the (completed) fix ops, so every fresh
  # failure of the origin op restarted at attempt 1 and exhausted?/1
  # never fired.
  use ExUnit.Case, async: false

  alias GiTF.{Archive, Ops, Togusa}
  alias GiTF.Togusa.FixContext

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    GiTF.Test.StoreHelper.stop_store()
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_fixloop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} = Archive.insert(:sectors, %{name: "s", path: "/tmp/s"})
    {:ok, mission} = Archive.insert(:missions, %{name: "m", goal: "g"})

    {:ok, op} =
      Ops.create(%{title: "Crux op", mission_id: mission.id, sector_id: sector.id})

    # Production reality: the quality gate runs on COMPLETED ops. A
    # pending/assigned origin op counts as an active worktree writer and
    # (correctly) defers fix creation.
    {:ok, op} = Archive.update(:ops, op.id, &Map.put(&1, :status, "done"))

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: sector.id,
        path: "/tmp/s",
        # Nonexistent on purpose: ghost spawn fails cleanly and request_fix
        # takes its documented fallback — context persistence is what's
        # under test, not spawning.
        worktree_path: "/tmp/gitf-fixloop-nonexistent-#{System.unique_integer([:positive])}",
        status: "active"
      })

    %{op: op, shell: shell}
  end

  test "fix ops carry their lineage — fix_of and fix_context survive creation", %{
    op: op,
    shell: shell
  } do
    ctx = FixContext.new(op.id)
    {:ok, fix_op} = Togusa.request_fix(op.id, shell.id, %{"summary" => "gate fail"}, ctx)

    # Ops.create silently dropped both fields (finding #14): every fix op
    # was an orphan, and gate failures on completed fix ops restarted the
    # chain at attempt 1 forever.
    {:ok, reloaded} = Ops.get(fix_op.id)
    assert reloaded[:fix_of] == op.id
    assert FixContext.from_map(reloaded[:fix_context]).attempt == 1
  end

  test "fix attempts accumulate on the origin op across cycles", %{op: op, shell: shell} do
    failures = %{"security" => [], "summary" => "proof of test failed"}

    # Cycle 1: origin has no context → attempt becomes 1, persisted to origin.
    ctx1 = FixContext.new(op.id)
    {:ok, fix_op1} = Togusa.request_fix(op.id, shell.id, failures, ctx1)

    # Single-lineage rule: a second fix is DEFERRED while one is in flight.
    assert {:error, :fix_in_flight} =
             Togusa.request_fix(op.id, shell.id, failures, ctx1)

    # The fix ghost completes — the lane frees up.
    {:ok, _} = GiTF.Archive.update(:ops, fix_op1.id, &Map.put(&1, :status, "done"))

    {:ok, reloaded} = Ops.get(op.id)
    assert %{} = ctx_map = reloaded[:fix_context]
    assert FixContext.from_map(ctx_map).attempt == 1

    # Cycle 2: context loaded FROM THE ORIGIN continues the count.
    ctx2 = FixContext.from_map(reloaded[:fix_context])
    {:ok, fix_op2} = Togusa.request_fix(op.id, shell.id, failures, ctx2)
    {:ok, _} = GiTF.Archive.update(:ops, fix_op2.id, &Map.put(&1, :status, "done"))

    {:ok, reloaded2} = Ops.get(op.id)
    ctx_after = FixContext.from_map(reloaded2[:fix_context])
    assert ctx_after.attempt == 2

    # Cycle 3 exhausts the default max of 3.
    {:ok, _} = Togusa.request_fix(op.id, shell.id, failures, ctx_after)
    {:ok, reloaded3} = Ops.get(op.id)
    ctx_final = FixContext.from_map(reloaded3[:fix_context])
    assert ctx_final.attempt == 3
    assert FixContext.exhausted?(ctx_final)
  end

  test "canonical shell selection excludes fix ops", %{op: op, shell: shell} do
    # A completed FIX op newer than the chain tip must NOT become the
    # canonical worktree (run 17: a fix ghost adopted chain-op 2's shell,
    # became 'latest completed', and dragged consolidation backward).
    tmp_wt = Path.join(System.tmp_dir!(), "gitf_canon_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_wt)
    on_exit(fn -> File.rm_rf!(tmp_wt) end)

    {:ok, chain_ghost} = Archive.insert(:ghosts, %{name: "chain", status: "stopped"})

    {:ok, chain_shell} =
      Archive.insert(:shells, %{
        sector_id: op.sector_id,
        ghost_id: chain_ghost.id,
        path: "/tmp/s",
        worktree_path: tmp_wt,
        status: "active"
      })

    {:ok, _} = Archive.update(:ghosts, chain_ghost.id, &Map.put(&1, :shell_id, chain_shell.id))
    {:ok, _} = Archive.update(:ops, op.id, &Map.put(&1, :ghost_id, chain_ghost.id))

    # A newer, completed fix op pointing at the OLD shell.
    {:ok, fix_op} =
      Ops.create(%{
        title: "Fix something",
        mission_id: op.mission_id,
        sector_id: op.sector_id,
        fix_of: op.id
      })

    {:ok, fix_ghost} = Archive.insert(:ghosts, %{name: "fixer", status: "stopped"})
    {:ok, _} = Archive.update(:ghosts, fix_ghost.id, &Map.put(&1, :shell_id, shell.id))

    {:ok, _} =
      Archive.update(:ops, fix_op.id, fn o ->
        o |> Map.put(:status, "done") |> Map.put(:ghost_id, fix_ghost.id)
      end)

    {:ok, mission} = GiTF.Missions.get(op.mission_id)

    canonical = GiTF.Validation.canonical_impl_shell(mission)
    assert canonical.id == chain_shell.id
  end
end
