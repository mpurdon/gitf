defmodule GiTF.Ghost.WorkerOutputTest do
  use ExUnit.Case, async: true

  # cap_events/2 is private; exercise the byte-bounding rule through the
  # module's public behaviour by building the same shapes it retains.
  # These assert the INVARIANT that matters: retention is bounded in bytes,
  # not just in count.

  @max_bytes 8_000_000

  defp fat_event(n) do
    # A realistic CLI stream event: an assistant message carrying a large
    # text block, the shape that grew the BEAM from 588MB to 1.9GB.
    %{
      "type" => "assistant",
      "seq" => n,
      "message" => %{"content" => String.duplicate("x", 200_000)}
    }
  end

  test "a count-only cap would be hundreds of MB; the byte cap holds it" do
    events = Enum.map(1..2_000, &fat_event/1)
    unbounded_bytes = Enum.reduce(events, 0, fn e, acc -> acc + :erlang.external_size(e) end)

    # Prove the premise: 2_000 of these blow far past any sane budget.
    assert unbounded_bytes > 100_000_000

    kept = GiTF.Ghost.Worker.cap_events_for_test(events, [])
    kept_bytes = Enum.reduce(kept, 0, fn e, acc -> acc + :erlang.external_size(e) end)

    assert kept_bytes <= @max_bytes + 1_000_000
    assert length(kept) < 2_000
    assert kept != []
  end

  test "keeps the newest events — the ones a crash report needs" do
    events = Enum.map(1..100, fn n -> %{"type" => "assistant", "seq" => n} end)
    kept = GiTF.Ghost.Worker.cap_events_for_test(events, [])

    seqs = Enum.map(kept, & &1["seq"])
    assert 100 in seqs
  end

  test "a single oversized event is retained rather than dropping everything" do
    huge = %{"type" => "result", "blob" => String.duplicate("y", @max_bytes * 2)}
    kept = GiTF.Ghost.Worker.cap_events_for_test([huge], [])
    assert length(kept) == 1
  end
end
