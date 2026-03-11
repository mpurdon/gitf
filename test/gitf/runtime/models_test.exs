defmodule GiTF.Runtime.ModelsTest do
  use ExUnit.Case, async: true

  alias GiTF.Runtime.Models

  describe "resolve_plugin/1" do
    test "defaults to ReqLLMProvider plugin when no opts" do
      assert {:ok, GiTF.Plugin.Builtin.Models.ReqLLMProvider} = Models.resolve_plugin()
    end

    test "accepts explicit module in :model_plugin opt" do
      assert {:ok, GiTF.Plugin.Builtin.Models.ReqLLMProvider} =
               Models.resolve_plugin(model_plugin: GiTF.Plugin.Builtin.Models.ReqLLMProvider)
    end

    test "accepts string name in :model_plugin opt" do
      # Falls back to default plugin when registry isn't running
      assert {:ok, GiTF.Plugin.Builtin.Models.ReqLLMProvider} =
               Models.resolve_plugin(model_plugin: "reqllm")
    end
  end

  describe "default_name/0" do
    test "returns 'reqllm' as default" do
      assert Models.default_name() == "reqllm"
    end
  end

  describe "parse_output/2" do
    test "returns empty list from ReqLLMProvider (API mode)" do
      # ReqLLMProvider doesn't parse CLI output streams
      data = ~s({"type":"system","model":"gemini-2.5-flash"}\n)
      events = Models.parse_output(data)
      assert [] = events
    end

    test "handles empty data" do
      assert [] = Models.parse_output("")
    end
  end

  describe "extract_costs/2" do
    test "extracts cost data from result events" do
      events = [
        %{"type" => "assistant", "content" => "hello"},
        %{
          "type" => "result",
          "usage" => %{
            input_tokens: 100,
            output_tokens: 50
          },
          "model" => "google:gemini-2.5-flash",
          "cost_usd" => 0.001
        }
      ]

      costs = Models.extract_costs(events)
      assert length(costs) == 1
      assert [%{input_tokens: 100, output_tokens: 50}] = costs
    end

    test "returns empty list when no result events" do
      events = [%{"type" => "assistant", "content" => "hello"}]
      assert [] = Models.extract_costs(events)
    end
  end

  describe "extract_session_id/2" do
    test "extracts session ID from system events" do
      events = [%{"type" => "system", "session_id" => "sess-abc123"}]
      assert "sess-abc123" = Models.extract_session_id(events)
    end

    test "returns nil when no session ID present" do
      events = [%{"type" => "assistant", "content" => "hello"}]
      assert nil == Models.extract_session_id(events)
    end

    test "returns nil for empty events" do
      assert nil == Models.extract_session_id([])
    end
  end

  describe "progress_from_events/2" do
    test "extracts tool_use progress" do
      events = [%{"type" => "tool_use", "name" => "Read", "input" => %{"path" => "/tmp/x"}}]
      progress = Models.progress_from_events(events)
      assert [%{tool: "Read", file: "/tmp/x", message: "Using Read"}] = progress
    end

    test "ignores non-tool_use events in API mode" do
      events = [%{"type" => "assistant", "content" => "Working on it..."}]
      progress = Models.progress_from_events(events)
      assert [] = progress
    end

    test "returns empty list for unrecognized events" do
      events = [%{"type" => "system", "model" => "gemini-2.5-flash"}]
      assert [] = Models.progress_from_events(events)
    end
  end

  describe "find_executable/1" do
    test "returns not_found for API-mode plugin" do
      # ReqLLMProvider doesn't have a CLI executable
      assert {:error, :not_found} = Models.find_executable()
    end
  end

  describe "pricing/1" do
    test "returns pricing table with Gemini and Anthropic models" do
      pricing = Models.pricing()
      assert is_map(pricing)
      assert Map.has_key?(pricing, "google:gemini-2.5-pro")
      assert Map.has_key?(pricing, "google:gemini-2.5-flash")
      assert Map.has_key?(pricing, "anthropic:claude-sonnet-4-6")

      gemini_pro = pricing["google:gemini-2.5-pro"]
      assert gemini_pro.input == 1.25
      assert gemini_pro.output == 10.0
    end
  end

  describe "workspace_setup/3" do
    test "returns nil in API mode (ReqLLMProvider)" do
      # ReqLLMProvider doesn't implement workspace_setup — API mode
      # doesn't need CLI settings files
      assert nil == Models.workspace_setup("ghost-test123", "/tmp/test-gitf")
    end

    test "returns nil for queen in API mode" do
      assert nil == Models.workspace_setup("major", "/tmp/test-gitf")
    end
  end

  describe "provider_config/1" do
    test "returns empty map for unconfigured provider" do
      assert Models.provider_config("nonexistent") == %{}
    end
  end
end
