defmodule GiTF.EventStoreRetentionTest do
  @moduledoc """
  Measured 2026-08-29: `:events` held 194,727 rows — 194MB of a 313MB ETS
  footprint, inside a 912MB BEAM that health was flagging as a warning.
  The retention that was supposed to bound it deleted NOTHING, because
  every one of those rows was younger than the 30-day window.

  Age retention answers "how long do we keep events". It does not answer
  "how many events can exist", and only the second question was actually
  costing memory. These tests pin both answers.
  """
  use GiTF.StoreCase

  alias GiTF.{Archive, EventStore}

  defp event_at!(days_ago) do
    {:ok, event} = EventStore.record(:job_created, "op-#{:erlang.unique_integer()}", %{})

    Archive.update(:events, event.id, fn e ->
      Map.put(e, :timestamp, DateTime.shift(DateTime.utc_now(), day: -days_ago))
    end)

    event
  end

  describe "prune/1 — the age window" do
    test "deletes events older than the window and keeps the rest" do
      old = event_at!(10)
      fresh = event_at!(1)

      assert EventStore.prune(days: 7) == 1

      refute Archive.get(:events, old.id)
      assert Archive.get(:events, fresh.id)
    end

    test "a week of busy traffic is entirely inside the window — age alone frees nothing" do
      for _ <- 1..20, do: event_at!(0)

      assert EventStore.prune(days: 7) == 0
      assert length(Archive.all(:events)) == 20
    end
  end

  describe "cap/1 — the row ceiling the age window cannot provide" do
    test "keeps the newest rows and deletes the oldest surplus" do
      # Ages descending so "newest" is unambiguous.
      events = for days <- 5..1//-1, do: event_at!(days)
      [oldest, second_oldest | newest] = events

      assert EventStore.cap(3) == 2

      refute Archive.get(:events, oldest.id)
      refute Archive.get(:events, second_oldest.id)

      for e <- newest, do: assert(Archive.get(:events, e.id), "newest rows must survive the cap")
    end

    test "a collection under the cap is untouched" do
      for _ <- 1..3, do: event_at!(0)

      assert EventStore.cap(50_000) == 0
      assert length(Archive.all(:events)) == 3
    end

    test "the cap bites exactly when age retention cannot — all rows fresh" do
      for _ <- 1..10, do: event_at!(0)

      assert EventStore.prune(days: 7) == 0
      assert EventStore.cap(4) == 6
      assert length(Archive.all(:events)) == 4
    end
  end
end
