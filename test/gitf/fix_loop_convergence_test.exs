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

  test "fix attempts accumulate on the origin op across cycles", %{op: op, shell: shell} do
    failures = %{"security" => [], "summary" => "proof of test failed"}

    # Cycle 1: origin has no context → attempt becomes 1, persisted to origin.
    ctx1 = FixContext.new(op.id)
    {:ok, _fix_op} = Togusa.request_fix(op.id, shell.id, failures, ctx1)

    {:ok, reloaded} = Ops.get(op.id)
    assert %{} = ctx_map = reloaded[:fix_context]
    assert FixContext.from_map(ctx_map).attempt == 1

    # Cycle 2: context loaded FROM THE ORIGIN continues the count.
    ctx2 = FixContext.from_map(reloaded[:fix_context])
    {:ok, _fix_op2} = Togusa.request_fix(op.id, shell.id, failures, ctx2)

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
end
