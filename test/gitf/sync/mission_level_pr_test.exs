defmodule GiTF.Sync.MissionLevelPrTest do
  @moduledoc """
  The "one mission-level PR" policy must hold on EVERY path into per-op
  sync. Run 8: tachikoma's gate skipped the broadcast, but SyncQueue's
  recover_pending sweep re-found the same done+verified ops and opened a
  stray PR from each raw ghost branch.
  """

  use GiTF.StoreCase

  alias GiTF.Archive

  defp insert_fixture!(sync_strategy) do
    {:ok, sector} =
      Archive.insert(:sectors, %{
        name: "s-#{sync_strategy}",
        path: "/tmp/nonexistent",
        sync_strategy: sync_strategy
      })

    {:ok, mission} = GiTF.Missions.create(%{goal: "policy test", sector_id: sector.id})

    {:ok, op} =
      Archive.insert(:ops, %{
        title: "impl",
        mission_id: mission.id,
        sector_id: sector.id,
        status: "done",
        verification_status: "passed",
        ghost_id: "ghost-plcy"
      })

    op
  end

  test "op in a pr_branch mission is delivered mission-level, not per-op" do
    op = insert_fixture!("pr_branch")
    assert GiTF.Sync.mission_level_pr?(op)
    assert GiTF.Sync.mission_level_pr?(op.id)
  end

  test "auto_merge missions still sync per-op" do
    op = insert_fixture!("auto_merge")
    refute GiTF.Sync.mission_level_pr?(op)
  end

  test "an op with no mission is not mission-level" do
    {:ok, op} =
      Archive.insert(:ops, %{title: "loose", sector_id: "sec-none", status: "done"})

    refute GiTF.Sync.mission_level_pr?(op)
    refute GiTF.Sync.mission_level_pr?("op-does-not-exist")
  end
end
