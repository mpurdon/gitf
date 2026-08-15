defmodule GiTF.ClockTest do
  use ExUnit.Case

  alias GiTF.Clock

  setup do
    on_exit(fn -> Clock.put_intervals_for_test([]) end)
    :ok
  end

  defp dt(minutes_ago), do: DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)

  test "equals wall-clock elapsed when no sleep intervals are recorded" do
    Clock.put_intervals_for_test([])
    since = dt(60)
    assert_in_delta Clock.awake_elapsed(since), 3600, 2
  end

  test "subtracts a fully-contained sleep interval" do
    # Slept from 40 to 10 minutes ago (30 min) inside a 60-min window.
    Clock.put_intervals_for_test([{dt(40), dt(10)}])
    assert_in_delta Clock.awake_elapsed(dt(60)), 1800, 2
  end

  test "clips intervals that extend beyond the query window" do
    # Sleep started 90 min ago, ended 30 min ago; window is the last hour —
    # only the overlapping 30 minutes are subtracted.
    Clock.put_intervals_for_test([{dt(90), dt(30)}])
    assert_in_delta Clock.awake_elapsed(dt(60)), 1800, 2
  end

  test "sums multiple intervals and never goes negative" do
    Clock.put_intervals_for_test([{dt(55), dt(35)}, {dt(30), dt(5)}])
    assert_in_delta Clock.awake_elapsed(dt(60)), 3600 - 1200 - 1500, 2

    # Entire window asleep — clamps at zero.
    Clock.put_intervals_for_test([{dt(120), DateTime.utc_now()}])
    assert Clock.awake_elapsed(dt(60)) <= 1
  end

  test "nil since is zero elapsed" do
    assert Clock.awake_elapsed(nil) == 0
  end

  test "in_boot_grace? is false when the clock never started" do
    # Test env doesn't supervise Clock; the degraded behavior must be
    # \"no grace\" so nothing holds forever.
    refute Clock.in_boot_grace?()
  end
end
