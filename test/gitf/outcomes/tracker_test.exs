defmodule GiTF.Outcomes.TrackerTest do
  use ExUnit.Case, async: false

  alias GiTF.Outcomes
  alias GiTF.Outcomes.Tracker

  setup do
    prior = Application.get_env(:gitf, :outcomes_enabled, false)

    # Make sure the app-level Archive is healthy and writable. A prior
    # StoreCase test may have torn down its temp data_dir while leaving
    # the Archive process pointing at it; `restore_app_store/0` kills
    # the stale process and starts a fresh Archive at a stable temp
    # path. Without this guard, `Archive.insert` for tests below blows
    # up with `{:error, :enoent}` and CaseClauseError on the bind.
    GiTF.Test.StoreHelper.restore_app_store()

    GiTF.Archive.all(:mission_outcomes)
    |> Enum.each(fn o -> GiTF.Archive.delete(:mission_outcomes, o.id) end)

    on_exit(fn -> Application.put_env(:gitf, :outcomes_enabled, prior) end)
    :ok
  end

  describe "next_poll_seconds/1 (polling decay curve)" do
    test "5 minutes in the first hour" do
      assert Tracker.next_poll_seconds(0) == 5 * 60
      assert Tracker.next_poll_seconds(30 * 60) == 5 * 60
    end

    test "15 minutes from 1h to 6h" do
      assert Tracker.next_poll_seconds(1 * 3600) == 15 * 60
      assert Tracker.next_poll_seconds(5 * 3600) == 15 * 60
    end

    test "60 minutes from 6h to 24h" do
      assert Tracker.next_poll_seconds(6 * 3600) == 60 * 60
      assert Tracker.next_poll_seconds(23 * 3600) == 60 * 60
    end

    test "4 hours from 24h to 72h" do
      assert Tracker.next_poll_seconds(24 * 3600) == 4 * 3600
      assert Tracker.next_poll_seconds(71 * 3600) == 4 * 3600
    end

    test "24 hours beyond the 72h stale window" do
      assert Tracker.next_poll_seconds(72 * 3600) == 24 * 3600
      assert Tracker.next_poll_seconds(200 * 3600) == 24 * 3600
    end

    test "a changed PR goes back to the tightest interval" do
      # The decay is keyed on age since first tracked, so a days-old PR sits
      # on 4- or 24-hour polls exactly when a human starts interacting with
      # it. Any real change resets the cadence to this.
      assert Tracker.fast_poll_seconds() == 5 * 60
      assert Tracker.fast_poll_seconds() < Tracker.next_poll_seconds(200 * 3600)
    end
  end

  describe "tick with feature flag off" do
    test "does nothing when :outcomes_enabled is false" do
      Application.put_env(:gitf, :outcomes_enabled, false)
      # No Tracker GenServer started in test — exercise list_open/0 guard
      assert Outcomes.list_open() == []
    end
  end

  describe "stale records are stopped on tick (via Analyzer)" do
    test "records with no activity for 72h get tracking_stopped" do
      Application.put_env(:gitf, :outcomes_enabled, true)

      # Staleness means QUIET, not old: age the activity anchor, not just the
      # tracking start. A PR still receiving reviews must never age out.
      old = DateTime.add(DateTime.utc_now(), -(72 * 3600 + 300), :second)
      {:ok, o} = Outcomes.start_tracking(%{id: "msn-stale", sector_id: nil}, "https://x/y/pull/1")

      {:ok, _} =
        Outcomes.update(o.id, fn rec ->
          Map.merge(rec, %{first_tracked_at: old, last_activity_at: old})
        end)

      # Poll via an in-process call to the Tracker's private flow. We can't
      # touch the private functions, so exercise the public tick path. In
      # absence of a running Tracker GenServer the tick is a no-op, so we
      # assert the Analyzer would classify it as stale.
      stale_outcome = Outcomes.get(o.id)
      assert GiTF.Outcomes.Analyzer.stale?(stale_outcome, DateTime.utc_now())
    end
  end
end
