defmodule GiTF.Cabinet.SnapshotTest do
  @moduledoc """
  The cost cap the Gate reads is `spend_month_usd`; until 0.65.319 nothing
  set it, so the cap was inert. It ratchets up within a month — the
  factory's prune sweep can lower its own month-to-date, and a cap that
  un-trips because old records were pruned is no cap.
  """
  use ExUnit.Case, async: true

  alias GiTF.Cabinet.Snapshot

  test "month-to-date ratchets within the month and resets on a new one" do
    sep = ~D[2026-09-10]
    m = Snapshot.merge_spend(%{}, 12.0, 30.0, sep)
    assert m.spend_month_usd == 30.0
    assert m.spend_month == ~D[2026-09-01]

    # The factory pruned: its month-to-date fell. Ours does not.
    m = Snapshot.merge_spend(m, 5.0, 8.0, sep)
    assert m.spend_month_usd == 30.0
    assert m.spend_usd == 5.0

    # More spend: up it goes.
    m = Snapshot.merge_spend(m, 40.0, 41.5, ~D[2026-09-20])
    assert m.spend_month_usd == 41.5

    # October: a fresh month.
    m = Snapshot.merge_spend(m, 41.0, 1.25, ~D[2026-10-01])
    assert m.spend_month_usd == 1.25

    # An old factory that reports no month figure counts as nothing new.
    m = Snapshot.merge_spend(m, 41.0, nil, ~D[2026-10-02])
    assert m.spend_month_usd == 1.25
  end
end
