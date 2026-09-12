defmodule GiTF.Cabinet.SnapshotLiveTest do
  @moduledoc """
  The Console draws a ministry's release, load and sleep countdown from the
  registry. The old console fetched them inside its render path — one HTTP
  call per running factory, on mount and every twenty seconds, per open
  console. The watcher stores them now, which only works if a stopped factory
  loses its liveness: a remembered "up 3h" is worse than no answer.
  """
  use GiTF.StoreCase

  alias GiTF.Cabinet.{Registry, Snapshot}

  defp ministry!(attrs \\ %{}) do
    {:ok, m} =
      Registry.create(
        Map.merge(%{slug: "m-#{:erlang.unique_integer([:positive])}", name: "M"}, attrs)
      )

    m
  end

  @health %{
    "status" => "ok",
    "version" => "0.65.336",
    "uptime_seconds" => 2520,
    "idle" => true,
    "idle_stop_at" => "2026-09-12T04:00:00Z",
    "active_missions" => 0,
    "active_ghosts" => 0
  }

  test "a health payload is stored whole, not reduced to a status string" do
    m = ministry!()
    {:ok, stored} = Registry.update(m.id, &Snapshot.merge_live(&1, @health))

    assert stored.live["version"] == "0.65.336"
    assert stored.live["idle_stop_at"] == "2026-09-12T04:00:00Z"
    assert stored.live["uptime_seconds"] == 2520
    assert %DateTime{} = stored.live_at
  end

  test "a factory that stops loses its liveness rather than remembering it" do
    m = ministry!()
    {:ok, _} = Registry.update(m.id, &Snapshot.merge_live(&1, @health))
    assert Registry.get(m.id).live

    Snapshot.clear_live(m.id)

    assert Registry.get(m.id).live == nil
    assert Registry.get(m.id).live_at == nil
  end

  test "an unreachable factory clears rather than half-writes" do
    m = ministry!()
    {:ok, _} = Registry.update(m.id, &Snapshot.merge_live(&1, @health))
    {:ok, stored} = Registry.update(m.id, &Snapshot.merge_live(&1, %{}))
    assert stored.live == nil
  end

  test "spend still ratchets within a month and resets across one" do
    m = ministry!()
    a = Snapshot.merge_spend(m, 10.0, 8.0, ~D[2026-09-12])
    assert a.spend_month_usd == 8.0

    # the factory pruned its ledger; the Cabinet must not un-trip a cap
    b = Snapshot.merge_spend(a, 10.0, 3.0, ~D[2026-09-12])
    assert b.spend_month_usd == 8.0

    c = Snapshot.merge_spend(b, 10.0, 1.0, ~D[2026-10-01])
    assert c.spend_month_usd == 1.0
  end
end
