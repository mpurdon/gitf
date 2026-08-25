defmodule GiTF.LedgerWallClockTest do
  @moduledoc """
  Wall clock is start transition → terminal transition, on wall-clock
  timestamps. The two lies it must not tell: `updated_at` drift (anything
  writing to a finished mission stretches it — the dashboard's "4h 44m"
  bug) and monotonic `seq` deltas (garbage across daemon restarts).
  """

  use GiTF.StoreCase

  setup do
    # StoreCase provides infrastructure, not the app's GenServers — without
    # this the record cast disappears into a dead name and entries() is [].
    case Process.whereis(GiTF.Ledger) do
      nil -> start_supervised!({GiTF.Ledger, []})
      pid -> pid
    end

    :ok
  end

  defp entry_for(mission) do
    # build_entry is private; record + entries is the public path.
    :ok = GiTF.Ledger.record(mission)
    # The cast is async — flush it with a sync call.
    GiTF.Ledger.entries() |> Enum.find(&(&1.mission_id == mission.id))
  end

  defp transition(mission_id, to_phase, at, seq) do
    {:ok, _} =
      GiTF.Archive.insert(:mission_phase_transitions, %{
        mission_id: mission_id,
        from_phase: "x",
        to_phase: to_phase,
        seq: seq,
        inserted_at: at
      })
  end

  test "wall clock spans first to terminal transition, not updated_at" do
    {:ok, m} = GiTF.Missions.create(%{goal: "wall clock test"})

    t0 = ~U[2026-08-25 00:02:03Z]
    transition(m.id, "triage", t0, 1)
    transition(m.id, "implementation", ~U[2026-08-25 00:10:00Z], 2)
    transition(m.id, "completed", ~U[2026-08-25 00:30:26Z], 3)

    # Outcome tracking touched the record hours later — must not count.
    mission =
      m
      |> Map.put(:status, "completed")
      |> Map.put(:inserted_at, ~U[2026-08-25 00:02:00Z])
      |> Map.put(:updated_at, ~U[2026-08-25 04:46:00Z])
      |> Map.put(:ops, [])

    entry = entry_for(mission)

    assert entry.wall_clock_seconds == 1703
    # The old duration_seconds still tells the drifted story — kept for
    # continuity, but wall_clock is the honest one.
    assert entry.duration_seconds > entry.wall_clock_seconds
  end

  test "queue wait is created→started, separated from execution" do
    {:ok, m} = GiTF.Missions.create(%{goal: "queue wait test"})

    created = m.inserted_at
    started = DateTime.add(created, 600, :second)
    done = DateTime.add(started, 120, :second)

    transition(m.id, "triage", started, 1)
    transition(m.id, "completed", done, 2)

    mission = m |> Map.put(:status, "completed") |> Map.put(:ops, [])
    entry = entry_for(mission)

    assert entry.queue_wait_seconds == 600
    assert entry.wall_clock_seconds == 120
  end

  test "a mission with no transitions yields nils, not zeros" do
    {:ok, m} = GiTF.Missions.create(%{goal: "no transitions"})
    mission = m |> Map.put(:status, "failed") |> Map.put(:ops, [])

    entry = entry_for(mission)

    assert entry.wall_clock_seconds == nil
    assert entry.queue_wait_seconds == nil
  end
end
