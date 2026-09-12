defmodule GiTF.Dashboard.MissionDurationTest do
  @moduledoc """
  The register reported `190h48m` for a mission the detail page correctly
  called `29m 38s`, because the two computed duration differently: the
  register measured to `updated_at`, which an outcome poll or a late artifact
  write moves for days after the work stopped. One definition now, measured to
  the transition that actually ended the mission.
  """
  use GiTF.StoreCase

  alias GiTF.Dashboard.Helpers
  alias GiTF.{Archive, Missions}

  defp mission!(status, inserted, updated) do
    {:ok, m} =
      Archive.insert(:missions, %{
        name: "dur",
        status: status,
        current_phase: status,
        sector_id: "s",
        artifacts: %{},
        ops: []
      })

    {:ok, m} =
      Archive.update(
        :missions,
        m.id,
        &Map.merge(&1, %{inserted_at: inserted, updated_at: updated})
      )

    m
  end

  defp transition!(mission_id, to_phase, at, seq) do
    {:ok, t} =
      Archive.insert(:mission_phase_transitions, %{
        mission_id: mission_id,
        from_phase: "validation",
        to_phase: to_phase,
        seq: seq
      })

    Archive.update(:mission_phase_transitions, t.id, &Map.put(&1, :inserted_at, at))
  end

  test "a finished mission is measured to the transition that ended it, not to updated_at" do
    start = ~U[2026-08-31 04:22:00Z]
    ended = ~U[2026-08-31 04:51:38Z]
    # something touched the record eight days later — an outcome poll
    touched = ~U[2026-09-08 05:00:00Z]

    m = mission!("completed", start, touched)
    transition!(m.id, "completed", ended, 1)
    m = Archive.get(:missions, m.id)

    assert Missions.duration_seconds(m) == 1778
    assert Helpers.duration(1778) == "29m 38s"

    # the old arithmetic, for contrast
    assert DateTime.diff(touched, start, :second) > 600_000
  end

  test "a running mission is measured to now" do
    m = mission!("active", DateTime.add(DateTime.utc_now(), -90, :second), DateTime.utc_now())
    assert_in_delta Missions.duration_seconds(m), 90, 2
  end

  test "the batch index agrees with the single lookup" do
    start = ~U[2026-08-31 04:22:00Z]
    ended = ~U[2026-08-31 04:51:38Z]
    m = mission!("completed", start, ~U[2026-09-08 05:00:00Z])
    transition!(m.id, "completed", ended, 1)
    m = Archive.get(:missions, m.id)

    index = Missions.terminal_transition_index()
    assert index[m.id] == ended
    assert Missions.duration_seconds(m, index[m.id]) == Missions.duration_seconds(m)
  end

  test "a mission with no start has no duration" do
    assert Missions.duration_seconds(%{status: "completed"}) == nil
    assert Helpers.duration(nil) == "—"
  end
end
