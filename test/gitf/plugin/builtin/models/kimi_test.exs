defmodule GiTF.Plugin.Builtin.Models.KimiTest do
  use ExUnit.Case, async: true

  alias GiTF.Plugin.Builtin.Models.Kimi

  describe "name/0" do
    test "returns 'kimi'" do
      assert Kimi.name() == "kimi"
    end
  end

  describe "description/0" do
    test "returns a description string" do
      assert is_binary(Kimi.description())
      assert Kimi.description() =~ "Kimi"
    end
  end

  describe "parse_output/1" do
    test "parses JSONL data into events" do
      data = ~s({"type":"system","session_id":"sess-1"}\n{"type":"assistant","content":"hello"}\n)
      events = Kimi.parse_output(data)

      assert [
               %{"type" => "system", "session_id" => "sess-1"},
               %{"type" => "assistant", "content" => "hello"}
             ] = events
    end

    test "handles empty data" do
      assert [] = Kimi.parse_output("")
    end

    test "skips malformed JSON lines" do
      data = ~s({"type":"system"}\nnot json\n{"type":"assistant","content":"hi"}\n)
      events = Kimi.parse_output(data)

      assert length(events) == 2
      assert Enum.at(events, 0)["type"] == "system"
      assert Enum.at(events, 1)["type"] == "assistant"
    end
  end

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Kimi.capabilities()
      assert :tool_calling in caps
      assert :streaming in caps
      assert :interactive in caps
      assert :headless in caps
    end
  end

  describe "pricing/0" do
    test "returns Kimi K2 pricing table" do
      pricing = Kimi.pricing()
      assert is_map(pricing)
      assert Map.has_key?(pricing, "kimi-k2")

      k2 = pricing["kimi-k2"]
      assert k2.input == 2.0
      assert k2.output == 8.0
    end
  end

  describe "workspace_setup/2" do
    test "returns nil" do
      assert Kimi.workspace_setup("ghost-123", "/tmp/hive") == nil
      assert Kimi.workspace_setup("major", "/tmp/hive") == nil
    end
  end

  describe "extract_costs/1" do
    test "extracts cost from result events" do
      events = [
        %{"type" => "assistant", "content" => "hello"},
        %{
          "type" => "result",
          "usage" => %{
            "input_tokens" => 200,
            "output_tokens" => 100,
            "cache_read_tokens" => 0,
            "cache_write_tokens" => 0
          },
          "model" => "kimi-k2",
          "cost_usd" => 0.002
        }
      ]

      costs = Kimi.extract_costs(events)
      assert length(costs) == 1
      assert [%{input_tokens: 200, output_tokens: 100, model: "kimi-k2"}] = costs
    end

    test "returns empty list when no result events" do
      events = [%{"type" => "assistant", "content" => "hi"}]
      assert [] = Kimi.extract_costs(events)
    end
  end

  describe "extract_session_id/1" do
    test "extracts session ID from system events" do
      events = [%{"type" => "system", "session_id" => "kimi-sess-xyz"}]
      assert "kimi-sess-xyz" = Kimi.extract_session_id(events)
    end

    test "returns nil when no session ID" do
      events = [%{"type" => "assistant", "content" => "hi"}]
      assert nil == Kimi.extract_session_id(events)
    end
  end

  describe "progress_from_events/1" do
    test "extracts tool_use progress" do
      events = [
        %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "/tmp/f.ex"}}
      ]

      progress = Kimi.progress_from_events(events)
      assert [%{tool: "Edit", file: "/tmp/f.ex", message: "Using Edit"}] = progress
    end

    test "extracts assistant content progress" do
      events = [%{"type" => "assistant", "content" => "Analyzing code..."}]
      progress = Kimi.progress_from_events(events)
      assert [%{tool: nil, file: nil, message: "Analyzing code..."}] = progress
    end

    test "skips non-progress events" do
      events = [%{"type" => "system", "session_id" => "s1"}]
      assert [] = Kimi.progress_from_events(events)
    end
  end

  describe "find_executable/0" do
    test "returns {:ok, path} or {:error, :not_found}" do
      result = Kimi.find_executable()
      assert match?({:ok, _}, result) or match?({:error, :not_found}, result)
    end
  end
end
