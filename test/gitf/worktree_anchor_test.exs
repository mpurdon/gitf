defmodule GiTF.WorktreeAnchorTest do
  @moduledoc """
  Runs 4 and 5 both died on a fix ghost's merge-back: ghost-70bcc6 and
  ghost-20bca7 each committed to a FRESH branch cut from the sector base
  and then three-way-conflicted against the very tree they were spawned to
  repair.

  The root cause was structural, not a spawn-path bug: fix and resolution
  ops carried no dependency edges, so `GiTF.Major.predecessor_shell/1`
  answered `:none` and every one of the three spawn paths that can reach
  such an op — direct, fallback, recovery sweep — provisioned a sibling
  worktree. These tests pin the edge, not any one spawn path.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, Missions, Ops, Validation}
  alias GiTF.Major.Endgame
  alias GiTF.Togusa.FixContext

  setup do
    {:ok, sector} = Archive.insert(:sectors, %{name: "anchor-sector", path: "/tmp/anchor-sector"})
    {:ok, mission} = Missions.create(%{goal: "Ship the thing", sector_id: sector.id})
    %{sector: sector, mission_id: mission.id}
  end

  # A completed implementation op with a ghost and a shell. `live_worktree?`
  # decides whether the shell's directory exists — which is exactly what
  # separates "canonical shell resolves" from "it does not".
  defp done_impl_op(mission_id, sector_id, opts \\ []) do
    {:ok, op} =
      Ops.create(%{
        title: Keyword.get(opts, :title, "Implement it"),
        mission_id: mission_id,
        sector_id: sector_id
      })

    worktree =
      if Keyword.get(opts, :live_worktree?, false) do
        path = Path.join(System.tmp_dir!(), "gitf_anchor_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(path)
        ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
        path
      else
        "/tmp/gitf-anchor-absent-#{:erlang.unique_integer([:positive])}"
      end

    {:ok, ghost} = Archive.insert(:ghosts, %{name: "g", status: "stopped", op_id: op.id})

    {:ok, shell} =
      Archive.insert(:shells, %{
        sector_id: sector_id,
        ghost_id: ghost.id,
        worktree_path: worktree,
        branch: "ghost/#{ghost.id}",
        status: "active"
      })

    Archive.update(:ghosts, ghost.id, &Map.put(&1, :shell_id, shell.id))
    {:ok, op} = Archive.update(:ops, op.id, &Map.merge(&1, %{status: "done", ghost_id: ghost.id}))

    %{op: op, ghost: ghost, shell: shell}
  end

  defp reload(mission_id) do
    {:ok, mission} = Missions.get(mission_id)
    mission
  end

  defp depends_on(op_id) do
    op_id |> Ops.dependencies() |> Enum.map(& &1.id) |> Enum.sort()
  end

  describe "anchor_to_canonical_worktree/3" do
    test "anchors to the op that OWNS the canonical worktree", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: canonical} = done_impl_op(mid, sector.id, live_worktree?: true)
      %{op: stale} = done_impl_op(mid, sector.id, title: "Older, no worktree")

      {:ok, follower} = Ops.create(%{title: "Fix it", mission_id: mid, sector_id: sector.id})

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), follower)

      assert depends_on(follower.id) == [canonical.id]
      refute stale.id in depends_on(follower.id)
    end

    test "falls back to the originating op when no canonical worktree survives", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: origin} = done_impl_op(mid, sector.id)
      {:ok, follower} = Ops.create(%{title: "Fix it", mission_id: mid, sector_id: sector.id})

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), follower, origin.id)

      assert depends_on(follower.id) == [origin.id]
    end

    test "never anchors to an unfinished op — that would BLOCK the new op", %{
      mission_id: mid,
      sector: sector
    } do
      {:ok, running} =
        Ops.create(%{title: "Still going", mission_id: mid, sector_id: sector.id})

      {:ok, _} = Archive.update(:ops, running.id, &Map.put(&1, :status, "running"))
      {:ok, follower} = Ops.create(%{title: "Fix it", mission_id: mid, sector_id: sector.id})

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), follower, running.id)

      assert depends_on(follower.id) == []
      assert {:ok, %{status: "pending"}} = Ops.get(follower.id)
    end

    test "a mission with no completed impl op leaves the op unanchored", %{
      mission_id: mid,
      sector: sector
    } do
      {:ok, follower} = Ops.create(%{title: "Fix it", mission_id: mid, sector_id: sector.id})

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), follower)

      assert depends_on(follower.id) == []
    end

    test "the anchored op is immediately READY, not blocked", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: canonical} = done_impl_op(mid, sector.id, live_worktree?: true)
      {:ok, follower} = Ops.create(%{title: "Fix it", mission_id: mid, sector_id: sector.id})

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), follower)

      # `add_dependency/2` blocks only on an UNRESOLVED dependency; a done
      # anchor must leave the op schedulable or the fix loop deadlocks.
      assert {:ok, %{status: "pending"}} = Ops.get(follower.id)
      assert Ops.ready?(follower.id)
      assert depends_on(follower.id) == [canonical.id]
    end

    test "is a no-op when the anchor would be the op itself", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: canonical} = done_impl_op(mid, sector.id, live_worktree?: true)

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), canonical)

      assert depends_on(canonical.id) == []
    end
  end

  describe "the edge is what makes predecessor_shell resolve" do
    test "an anchored op continues the canonical worktree; an unanchored one does not", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: _canonical, shell: shell} = done_impl_op(mid, sector.id, live_worktree?: true)

      {:ok, unanchored} = Ops.create(%{title: "Fix it", mission_id: mid, sector_id: sector.id})

      # This is the run 4/5 shape: no edges, so the spawn paths cut a
      # sibling worktree from the sector base.
      assert GiTF.Major.predecessor_shell(unanchored) == :none

      :ok = Validation.anchor_to_canonical_worktree(reload(mid), unanchored)
      {:ok, anchored} = Ops.get(unanchored.id)

      assert GiTF.Major.predecessor_shell(anchored) == {:ok, shell.id}
    end
  end

  describe "validation fix ops are anchored at creation" do
    test "attempt_fixes/3 gives the fix op its worktree edge", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: origin} = done_impl_op(mid, sector.id)
      mission = reload(mid)
      ctx = FixContext.new(mid) |> Map.put(:original_op_id, origin.id)

      {:ok, "implementation"} =
        Validation.attempt_fixes(mission, %{"summary" => "requirement unmet"}, ctx)

      fix_op =
        Ops.list(mission_id: mid)
        |> Enum.find(&is_binary(&1[:fix_of]))

      assert fix_op, "expected a fix op to have been created"
      assert depends_on(fix_op.id) == [origin.id]
      assert Ops.ready?(fix_op.id)
    end
  end

  describe "conflict-resolution ops are anchored at creation" do
    test "start_conflict_resolution/3 gives the resolution op its worktree edge", %{
      mission_id: mid,
      sector: sector
    } do
      %{op: impl} = done_impl_op(mid, sector.id)
      mission = reload(mid)

      {:ok, "implementation"} =
        Endgame.start_conflict_resolution(mission, "ghost/other", ["src/models.rs"])

      resolution =
        Ops.list(mission_id: mid)
        |> Enum.find(&is_binary(&1[:conflict_resolution]))

      assert resolution, "expected a resolution op to have been created"
      assert resolution[:conflict_resolution] == "ghost/other"
      assert depends_on(resolution.id) == [impl.id]
      assert Ops.ready?(resolution.id)
    end
  end
end
