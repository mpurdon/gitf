defmodule GiTF.Togusa.TerminalGuardTest do
  @moduledoc """
  msn-0434e9: a simplify op's quality gate ran 18 minutes after the op
  finished, failed on a stale tree, and spawned "Fix quality issues
  (attempt 1)" 43 seconds AFTER the mission had completed. The fix op
  sat pending on a finished mission forever. A fix may only be requested
  for a mission that is still running.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Togusa

  defp mission!(status) do
    {:ok, m} =
      Archive.insert(:missions, %{
        name: "guard",
        goal: "g",
        status: status,
        current_phase: status,
        sector_id: "sec-guard",
        artifacts: %{},
        ops: []
      })

    m
  end

  defp op!(mission) do
    {:ok, op} =
      Archive.insert(:ops, %{
        title: "Simplify [quality]",
        mission_id: mission.id,
        sector_id: mission.sector_id,
        status: "done",
        phase_job: false
      })

    op
  end

  test "a fix is refused for every terminal status" do
    for status <- GiTF.Missions.terminal_phases() do
      op = op!(mission!(status))
      assert {:error, {:mission_terminal, ^status}} = Togusa.ensure_mission_live(op)
    end
  end

  test "a live mission may still request a fix" do
    op = op!(mission!("active"))
    assert :ok = Togusa.ensure_mission_live(op)
  end

  test "an op whose mission is gone is refused rather than raising" do
    assert {:error, :mission_not_found} = Togusa.ensure_mission_live(%{mission_id: "msn-nope"})
  end
end
