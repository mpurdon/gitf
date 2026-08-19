defmodule GiTF.DiskUsageTest do
  use GiTF.StoreCase

  alias GiTF.{Archive, DiskUsage}

  test "dir_size measures a real directory and nil for a missing one" do
    tmp = Path.join(System.tmp_dir!(), "gitf_du_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    File.write!(Path.join(tmp, "blob"), String.duplicate("x", 50_000))

    size = DiskUsage.dir_size(tmp)
    assert is_integer(size) and size > 0

    assert DiskUsage.dir_size(Path.join(tmp, "nope")) == nil
  end

  test "report attributes ghost worktrees to their missions" do
    tmp = Path.join(System.tmp_dir!(), "gitf_du_sector_#{System.unique_integer([:positive])}")
    ghost_dir = Path.join([tmp, "ghosts", "ghost-du1"])
    File.mkdir_p!(ghost_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)
    File.write!(Path.join(ghost_dir, "file"), "data")

    {:ok, sector} = Archive.insert(:sectors, %{name: "du-sector", path: tmp})
    {:ok, mission} = Archive.insert(:missions, %{name: "du-mission", goal: "g"})

    {:ok, _op} =
      Archive.insert(:ops, %{
        title: "t",
        mission_id: mission.id,
        sector_id: sector.id,
        ghost_id: "ghost-du1",
        status: "done"
      })

    report = DiskUsage.report()
    sector_report = Enum.find(report.sectors, &(&1.id == sector.id))

    assert %{worktrees: [wt]} = sector_report
    assert wt.ghost_id == "ghost-du1"
    assert wt.mission_id == mission.id
    assert is_integer(wt.bytes)
    assert sector_report.by_mission[mission.id] == wt.bytes

    assert is_map(report.filesystem)
    assert is_map(report.infra)
  end
end
