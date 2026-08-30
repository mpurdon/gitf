defmodule GiTF.Runtime.CLICallTrackerTest do
  @moduledoc """
  The CLI ghost path is the overwhelming majority of the factory's LLM
  work, and it produced no latency data at all. What matters here is that
  the numbers it now produces are honest: one record per model call and
  not per content block, tool-execution time excluded from call latency,
  a distinguishable `unit` so a run can never be read as a call, and a
  record on the failure paths — a timeout is the whole point.
  """

  use ExUnit.Case, async: true

  alias GiTF.Runtime.CLICallTracker, as: Tracker
  alias GiTF.TestDriver.MockClaude

  defp tracker(now_ms \\ 0) do
    Tracker.new(
      provider: "cli:claude",
      model: "sonnet",
      mode: :cli,
      mission_id: "msn-test",
      now_ms: now_ms
    )
  end

  defp line(event), do: Jason.encode!(event) <> "\n"

  # Feeds each event as its own chunk at the given arrival time.
  defp play(tracker, timed_events) do
    Enum.reduce(timed_events, {tracker, []}, fn {event, at}, {tracker, acc} ->
      {tracker, records} = Tracker.consume(tracker, line(event), at)
      {tracker, acc ++ records}
    end)
  end

  describe "call boundaries" do
    test "one record per distinct message id, not per content block" do
      events = MockClaude.turn_events(3, blocks: 3)
      timed = Enum.with_index(events, fn event, i -> {event, i * 1_000} end)

      {tracker, records} = play(tracker(), timed)

      # 3 turns emitted 3 blocks each = 9 assistant events on the wire.
      assert Enum.count(events, &(&1["type"] == "assistant")) == 9
      # …for 3 model calls.
      assert length(records) == 3
      assert Tracker.emitted(tracker) == 3
      assert Enum.all?(records, &(&1.unit == :call))
      assert Enum.all?(records, &(&1.kind == :cli_call))
    end

    test "tool execution time is not billed as call latency" do
      init = %{"type" => "system", "subtype" => "init"}

      call = fn id ->
        %{
          "type" => "assistant",
          "message" => %{
            "id" => id,
            "model" => "claude-sonnet-4-20250514",
            "usage" => %{"input_tokens" => 900, "output_tokens" => 120}
          }
        }
      end

      tool_result = %{"type" => "user", "message" => %{"role" => "user"}}

      {_tracker, records} =
        play(tracker(0), [
          # CLI boots for 5s, then a 2s model call.
          {init, 5_000},
          {call.("msg_a"), 7_000},
          # A 30s test suite runs, then a 3s model call.
          {tool_result, 37_000},
          {call.("msg_b"), 40_000}
        ])

      assert [first, second] = records
      assert first.duration_ms == 2_000
      assert second.duration_ms == 3_000
    end

    test "duration, provider, model and tokens are all populated" do
      events = MockClaude.turn_events(1, blocks: 1, output_tokens: 250, input_tokens: 4_000)
      timed = Enum.with_index(events, fn event, i -> {event, i * 500} end)

      {_tracker, [record]} = play(tracker(), timed)

      assert record.provider == "cli:claude"
      # The model the CLI named, not the fallback the ghost was assigned.
      assert record.model == "claude-sonnet-4-20250514"
      assert record.mode == :cli
      assert record.mission_id == "msn-test"
      assert record.input_tokens == 4_000
      assert record.output_tokens == 250
      assert record.duration_ms == 500
      assert record.outcome == :ok
      # Nothing here streams, so TTFT stays honestly nil.
      assert record.ttft_ms == nil
      refute record.streaming
    end

    test "the ghost's assigned model stands in when the CLI names none" do
      event = %{"type" => "assistant", "message" => %{"id" => "msg_x", "usage" => %{}}}
      {_tracker, [record]} = play(tracker(), [{event, 1_000}])

      assert record.model == "sonnet"
    end
  end

  describe "framing" do
    test "an event split across port chunks is still counted" do
      [payload] =
        MockClaude.turn_events(1, blocks: 1)
        |> Enum.filter(&(&1["type"] == "assistant"))

      encoded = line(payload)
      cut = div(byte_size(encoded), 2)
      <<head::binary-size(cut), tail::binary>> = encoded

      # The naive parser drops both halves; nothing decodes on its own.
      assert GiTF.Runtime.StreamParser.parse_chunk(head) == []
      assert GiTF.Runtime.StreamParser.parse_chunk(tail) == []

      {tracker, []} = Tracker.consume(tracker(0), head, 100)
      {_tracker, records} = Tracker.consume(tracker, tail, 900)

      assert [%{duration_ms: 900}] = records
    end

    test "garbage on the stream is skipped, not fatal" do
      {tracker, records} = Tracker.consume(tracker(0), "not json\n{\n\n", 10)
      assert records == []

      {_tracker, records} =
        Tracker.consume(tracker, line(%{"type" => "assistant", "message" => %{"id" => "m"}}), 20)

      assert length(records) == 1
    end
  end

  describe "finish" do
    test "a run killed mid-call books that call with the killing outcome" do
      tool_result = %{"type" => "user", "message" => %{}}
      call = %{"type" => "assistant", "message" => %{"id" => "msg_a", "usage" => %{}}}

      {tracker, _} = play(tracker(0), [{call, 1_000}, {tool_result, 2_000}])
      {_tracker, [record]} = Tracker.finish(tracker, :timeout, 302_000)

      assert record.unit == :call
      assert record.outcome == :timeout
      # Measured from when the call could have started, not from spawn.
      assert record.duration_ms == 300_000
    end

    test "a clean run that already booked its calls says nothing more" do
      events = MockClaude.turn_events(2)
      timed = Enum.with_index(events, fn event, i -> {event, i * 100} end)

      {tracker, records} = play(tracker(), timed)
      assert length(records) == 2

      assert {_tracker, []} = Tracker.finish(tracker, :ok, 10_000)
    end

    test "a transcript we cannot decompose still books one unit: :run record" do
      # The copilot CLI emits plain text — no events, no call boundaries.
      {tracker, []} = Tracker.consume(tracker(0), "working on it...\ndone.\n", 500)
      {_tracker, [record]} = Tracker.finish(tracker, :ok, 60_000)

      assert record.unit == :run
      assert record.kind == :cli_run
      assert record.duration_ms == 60_000
      assert record.outcome == :ok
    end

    test "a run record carries the terminal event's totals when there is one" do
      result = %{
        "type" => "result",
        "usage" => %{"input_tokens" => 12_000, "output_tokens" => 800}
      }

      {tracker, []} = play(tracker(0), [{result, 5_000}])
      {_tracker, [record]} = Tracker.finish(tracker, :ok, 5_000)

      assert record.unit == :run
      assert record.input_tokens == 12_000
      assert record.output_tokens == 800
    end

    test "a ghost that died before the CLI spoke is a failed run, not a call" do
      {_tracker, [record]} = Tracker.finish(tracker(0), :exit_error, 3_000)

      assert record.unit == :run
      assert record.outcome == :exit_error
      assert record.duration_ms == 3_000
    end
  end

  describe "bounds" do
    test "records per run are capped so a runaway ghost cannot flood the store" do
      events = MockClaude.turn_events(700, blocks: 1)
      timed = Enum.with_index(events, fn event, i -> {event, i} end)

      {tracker, records} = play(tracker(), timed)

      assert Tracker.emitted(tracker) == 500
      assert length(records) == 500
    end

    test "an unterminated fragment cannot grow the buffer without bound" do
      huge = String.duplicate("x", 5_000_000)
      {tracker, []} = Tracker.consume(tracker(0), huge, 10)
      assert tracker.buffer == ""
    end
  end

  test "consume and finish tolerate a tracker that was never built" do
    assert {nil, []} = Tracker.consume(nil, "{}\n", 0)
    assert {nil, []} = Tracker.finish(nil, :ok, 0)
  end
end
