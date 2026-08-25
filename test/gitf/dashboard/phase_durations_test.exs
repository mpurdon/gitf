defmodule GiTF.Dashboard.PhaseDurationsTest do
  use ExUnit.Case, async: true

  alias GiTF.Dashboard.MissionDetailLive

  defp t(seconds), do: DateTime.add(~U[2026-08-18 16:00:00Z], seconds, :second)

  defp transition(to_phase, at), do: %{to_phase: to_phase, inserted_at: at}

  describe "compute_phase_durations/2" do
    test "revisited phases accumulate instead of keeping only the last visit" do
      # The run-21 dashboard bug: a 50-minute implementation followed by a
      # 3-minute fix cycle displayed as "implementation 3m".
      transitions = [
        transition("implementation", t(0)),
        transition("validation", t(3000)),
        transition("implementation", t(3060)),
        transition("validation", t(3240))
      ]

      durations = MissionDetailLive.compute_phase_durations(transitions, t(3300))

      # 3000s first build + 180s fix cycle = 53m, not 3m.
      assert durations["implementation"] == "53m"
    end

    test "the phase the mission is in right now accrues up to `now`" do
      transitions = [
        transition("implementation", t(0)),
        transition("validation", t(600))
      ]

      durations = MissionDetailLive.compute_phase_durations(transitions, t(1500))

      assert durations["implementation"] == "10m"
      # 900s of live validation, not absent or stale.
      assert durations["validation"] == "15m"
    end

    test "a completed mission does not keep accruing into its final phase" do
      transitions = [
        transition("implementation", t(0)),
        transition("completed", t(600))
      ]

      much_later = t(100_000)
      durations = MissionDetailLive.compute_phase_durations(transitions, much_later)

      assert durations["implementation"] == "10m"
      refute Map.has_key?(durations, "completed")
    end

    test "empty and malformed input stay empty" do
      assert MissionDetailLive.compute_phase_durations([], t(0)) == %{}
      assert MissionDetailLive.compute_phase_durations(nil, t(0)) == %{}
    end
  end

  describe "compute_duration/2" do
    # The regression: msn-db44d4 ran 00:02-00:30 (28 minutes) and the header
    # read "4h 44m" the next morning. For completed missions the end time was
    # `updated_at` — the last WRITE to the record — and outcome tracking,
    # boot sweeps, and PR polling all keep writing to finished missions, so
    # the displayed duration grew every time anything touched the record.
    test "a finished mission's duration ends at its terminal transition, not its last write" do
      mission = %{
        inserted_at: ~U[2026-08-25 00:02:00Z],
        # Touched hours later by an outcome poll:
        updated_at: ~U[2026-08-25 04:46:00Z],
        status: "completed"
      }

      transitions = [
        %{to_phase: "triage", inserted_at: ~U[2026-08-25 00:02:03Z]},
        %{to_phase: "completed", inserted_at: ~U[2026-08-25 00:30:26Z]}
      ]

      assert MissionDetailLive.compute_duration(mission, transitions) == "28m 26s"
    end

    test "falls back to updated_at when no terminal transition was recorded" do
      mission = %{
        inserted_at: ~U[2026-08-25 00:00:00Z],
        updated_at: ~U[2026-08-25 00:10:00Z],
        status: "failed"
      }

      assert MissionDetailLive.compute_duration(mission, []) == "10m 0s"
    end

    test "a running mission measures to now" do
      mission = %{
        inserted_at: DateTime.add(DateTime.utc_now(), -90, :second),
        status: "active"
      }

      assert MissionDetailLive.compute_duration(mission, []) == "1m 30s"
    end
  end
end
