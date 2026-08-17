defmodule GiTF.MajorPredecessorShellTest do
  # Pins the chain-inheritance contract: an op whose dependency completed
  # in a live worktree spawns IN that worktree. The original implementation
  # read a nonexistent op[:depends_on] field (deps actually live in the
  # :op_dependencies collection via Ops.add_dependency/2), so the
  # "serialized implementation chain" never chained lineage — every impl
  # op forked a sibling branch off origin/main and consolidation
  # manufactured conflict markers on every run from 13 through 16.
  use ExUnit.Case, async: false

  alias GiTF.{Archive, Ops}

  setup do
    GiTF.Test.StoreHelper.ensure_infrastructure()
    GiTF.Test.StoreHelper.stop_store()
    tmp_dir = Path.join(System.tmp_dir!(), "gitf_pred_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    {:ok, _} = Archive.start_link(data_dir: tmp_dir)

    worktree = Path.join(tmp_dir, "wt")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, sector} = Archive.insert(:sectors, %{name: "s", path: "/tmp/s"})
    {:ok, mission} = Archive.insert(:missions, %{name: "m", goal: "g"})

    {:ok, dep_op} = Ops.create(%{title: "op A", mission_id: mission.id, sector_id: sector.id})
    {:ok, op} = Ops.create(%{title: "op B", mission_id: mission.id, sector_id: sector.id})
    {:ok, _} = Ops.add_dependency(op.id, dep_op.id)

    {:ok, ghost} = Archive.insert(:ghosts, %{name: "g1", status: "stopped"})

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: sector.id,
        ghost_id: ghost.id,
        path: "/tmp/s",
        worktree_path: worktree,
        status: "active"
      })

    {:ok, _} = Archive.update(:ghosts, ghost.id, &Map.put(&1, :shell_id, shell.id))

    {:ok, dep_op} =
      Archive.update(:ops, dep_op.id, fn o ->
        o |> Map.put(:status, "done") |> Map.put(:ghost_id, ghost.id)
      end)

    %{op: op, dep_op: dep_op, shell: shell}
  end

  test "chained op inherits the completed dependency's worktree shell", %{
    op: op,
    shell: shell
  } do
    {:ok, op} = Ops.get(op.id)
    assert {:ok, shell_id} = GiTF.Major.predecessor_shell(op)
    assert shell_id == shell.id
  end

  test "ops without dependencies get no predecessor shell", %{dep_op: dep_op} do
    assert GiTF.Major.predecessor_shell(dep_op) == :none
  end
end
