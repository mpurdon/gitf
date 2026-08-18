defmodule GiTF.Runtime.StreamParserTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.StreamParser

  describe "parse_chunk/1" do
    test "parses a single JSON line" do
      data = ~s({"type":"system","model":"claude-sonnet-4-20250514"}\n)

      assert [%{"type" => "system", "model" => "claude-sonnet-4-20250514"}] =
               StreamParser.parse_chunk(data)
    end

    test "parses multiple JSON lines" do
      data = """
      {"type":"system","model":"claude-sonnet-4-20250514"}
      {"type":"assistant","message":{"content":"hello"}}
      {"type":"result","result":"done","usage":{"input_tokens":100,"output_tokens":50}}
      """

      events = StreamParser.parse_chunk(data)
      assert length(events) == 3
      assert Enum.at(events, 0)["type"] == "system"
      assert Enum.at(events, 1)["type"] == "assistant"
      assert Enum.at(events, 2)["type"] == "result"
    end

    test "silently drops malformed lines" do
      data = """
      {"type":"system"}
      not valid json
      {"type":"result","usage":{"input_tokens":10,"output_tokens":5}}
      """

      events = StreamParser.parse_chunk(data)
      assert length(events) == 2
    end

    test "returns empty list for empty input" do
      assert [] = StreamParser.parse_chunk("")
    end

    test "handles data without trailing newline" do
      data = ~s({"type":"system"})
      assert [%{"type" => "system"}] = StreamParser.parse_chunk(data)
    end
  end

  describe "extract_cost/1" do
    test "extracts cost data from a result event" do
      event = %{
        "type" => "result",
        "usage" => %{
          "input_tokens" => 1000,
          "output_tokens" => 500,
          "cache_read_tokens" => 200,
          "cache_write_tokens" => 100
        },
        "model" => "claude-sonnet-4-20250514",
        "cost_usd" => 0.0123
      }

      cost = StreamParser.extract_cost(event)

      assert cost.input_tokens == 1000
      assert cost.output_tokens == 500
      assert cost.cache_read_tokens == 200
      assert cost.cache_write_tokens == 100
      assert cost.model == "claude-sonnet-4-20250514"
      assert cost.cost_usd == 0.0123
    end

    test "defaults missing token counts to zero" do
      event = %{
        "type" => "result",
        "usage" => %{
          "input_tokens" => 50,
          "output_tokens" => 25
        },
        "model" => "claude-sonnet-4-20250514"
      }

      cost = StreamParser.extract_cost(event)

      assert cost.input_tokens == 50
      assert cost.output_tokens == 25
      assert cost.cache_read_tokens == 0
      assert cost.cache_write_tokens == 0
      assert cost.cost_usd == nil
    end

    test "returns nil for non-result events" do
      assert nil == StreamParser.extract_cost(%{"type" => "system"})
      assert nil == StreamParser.extract_cost(%{"type" => "assistant"})
      assert nil == StreamParser.extract_cost(%{})
    end
  end

  describe "extract_costs/1" do
    test "extracts costs from a list of events" do
      events = [
        %{"type" => "system", "model" => "claude-sonnet-4-20250514"},
        %{"type" => "assistant", "message" => %{"content" => "hello"}},
        %{
          "type" => "result",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50},
          "model" => "claude-sonnet-4-20250514",
          "cost_usd" => 0.001
        }
      ]

      costs = StreamParser.extract_costs(events)
      assert length(costs) == 1
      assert hd(costs).input_tokens == 100
    end

    test "returns empty list when no result events" do
      events = [
        %{"type" => "system"},
        %{"type" => "assistant"}
      ]

      assert [] = StreamParser.extract_costs(events)
    end

    # The shape a real `claude --print --output-format stream-json` result
    # event has on the Max plan (captured 2026-08-18): no top-level "model",
    # cost under "total_cost_usd", and per-model breakdown in "modelUsage".
    test "books one record per model from a CLI result event's modelUsage" do
      events = [
        %{
          "type" => "result",
          "total_cost_usd" => 0.1347646,
          "usage" => %{"input_tokens" => 2, "output_tokens" => 4},
          "modelUsage" => %{
            "claude-sonnet-5" => %{
              "inputTokens" => 2,
              "outputTokens" => 4,
              "cacheReadInputTokens" => 24_462,
              "cacheCreationInputTokens" => 21_129,
              "costUSD" => 0.1341786,
              "canonicalModel" => "claude-sonnet-5"
            },
            "claude-haiku-4-5-20251001" => %{
              "inputTokens" => 521,
              "outputTokens" => 13,
              "cacheReadInputTokens" => 0,
              "cacheCreationInputTokens" => 0,
              "costUSD" => 0.000586,
              "canonicalModel" => "claude-haiku-4-5"
            }
          }
        }
      ]

      costs = StreamParser.extract_costs(events) |> Enum.sort_by(& &1.model)

      assert [haiku, sonnet] = costs
      assert sonnet.model == "claude-sonnet-5"
      assert sonnet.cache_read_tokens == 24_462
      assert sonnet.cache_write_tokens == 21_129
      assert sonnet.cost_usd == 0.1341786
      # Canonical name wins over the dated modelUsage key.
      assert haiku.model == "claude-haiku-4-5"
      assert haiku.cost_usd == 0.000586
    end

    test "CLI result event without modelUsage still books, with total_cost_usd" do
      events = [
        %{
          "type" => "result",
          "total_cost_usd" => 0.05,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
        }
      ]

      assert [cost] = StreamParser.extract_costs(events)
      assert cost.cost_usd == 0.05
      assert cost.model == nil
    end
  end

  describe "session_complete?/1" do
    test "returns true for result events" do
      assert StreamParser.session_complete?(%{"type" => "result"})
    end

    test "returns false for other event types" do
      refute StreamParser.session_complete?(%{"type" => "system"})
      refute StreamParser.session_complete?(%{"type" => "assistant"})
      refute StreamParser.session_complete?(%{})
    end
  end

  describe "extract_session_id/1" do
    test "extracts session_id from a system event" do
      events = [
        %{
          "type" => "system",
          "session_id" => "sess-abc123",
          "model" => "claude-sonnet-4-20250514"
        },
        %{"type" => "assistant", "message" => %{"content" => "hello"}},
        %{"type" => "result", "usage" => %{"input_tokens" => 10, "output_tokens" => 5}}
      ]

      assert "sess-abc123" = StreamParser.extract_session_id(events)
    end

    test "returns nil when no system event is present" do
      events = [
        %{"type" => "assistant", "message" => %{"content" => "hello"}},
        %{"type" => "result", "usage" => %{"input_tokens" => 10, "output_tokens" => 5}}
      ]

      assert nil == StreamParser.extract_session_id(events)
    end

    test "returns nil when system event has no session_id" do
      events = [
        %{"type" => "system", "model" => "claude-sonnet-4-20250514"}
      ]

      assert nil == StreamParser.extract_session_id(events)
    end

    test "returns nil for empty event list" do
      assert nil == StreamParser.extract_session_id([])
    end
  end
end
