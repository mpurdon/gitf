defmodule GiTF.Major.PhaseCollectorTest do
  use ExUnit.Case, async: true

  alias GiTF.Major.PhaseCollector

  describe "extract_json/1" do
    test "parses raw JSON object" do
      assert {:ok, %{"key" => "value"}} = PhaseCollector.extract_json(~s({"key": "value"}))
    end

    test "parses raw JSON array" do
      assert {:ok, [1, 2, 3]} = PhaseCollector.extract_json("[1, 2, 3]")
    end

    test "extracts JSON from markdown fence" do
      text = """
      Some preamble text.

      ```json
      {"architecture": "MVC", "key_files": ["lib/app.ex"]}
      ```

      Some trailing text.
      """

      assert {:ok, %{"architecture" => "MVC"}} = PhaseCollector.extract_json(text)
    end

    test "extracts embedded JSON object from surrounding text" do
      text = """
      Here is my analysis:
      {"approved": true, "coverage": []}
      That's my review.
      """

      assert {:ok, %{"approved" => true}} = PhaseCollector.extract_json(text)
    end

    test "returns error for non-JSON text" do
      assert {:error, _} = PhaseCollector.extract_json("just plain text")
    end

    test "returns error for non-binary input" do
      assert {:error, :not_binary} = PhaseCollector.extract_json(nil)
    end
  end

  describe "validate_artifact/2" do
    test "validates research phase artifact" do
      artifact = %{
        "architecture" => "OTP",
        "key_files" => ["lib/app.ex"],
        "patterns" => ["GenServer"],
        "tech_stack" => ["Elixir"]
      }

      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("research", artifact)
    end

    test "accepts partial research artifact with warning" do
      artifact = %{"architecture" => "OTP"}
      # Missing keys, but still returns ok (partial is better than none)
      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("research", artifact)
    end

    test "validates requirements phase artifact" do
      artifact = %{"functional_requirements" => [%{"id" => "FR-1"}]}
      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("requirements", artifact)
    end

    test "validates design phase artifact" do
      artifact = %{"components" => [], "requirement_mapping" => []}
      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("design", artifact)
    end

    test "validates review phase artifact" do
      artifact = %{"approved" => true, "coverage" => []}
      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("review", artifact)
    end

    test "planning phase accepts any data (expects list)" do
      artifact = [%{"title" => "Job 1"}]
      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("planning", artifact)
    end

    test "validates validation phase artifact" do
      artifact = %{"requirements_met" => [], "overall_verdict" => "pass"}
      assert {:ok, ^artifact} = PhaseCollector.validate_artifact("validation", artifact)
    end
  end

  describe "extract_assistant_text/2" do
    test "extracts text from assistant events" do
      events = [
        %{"type" => "assistant", "content" => "First response"},
        %{"type" => "assistant", "content" => "Final response"}
      ]

      assert PhaseCollector.extract_assistant_text(events, "raw fallback") == "Final response"
    end

    test "falls back to raw output when no assistant events" do
      events = [%{"type" => "system", "model" => "test"}]
      assert PhaseCollector.extract_assistant_text(events, "raw output") == "raw output"
    end

    test "uses raw output for API mode result events" do
      events = [%{"type" => "result", "status" => "completed"}]
      assert PhaseCollector.extract_assistant_text(events, "api result text") == "api result text"
    end
  end

  describe "collect/3" do
    test "parses phase output with JSON in events" do
      json =
        Jason.encode!(%{
          "architecture" => "OTP",
          "key_files" => [],
          "patterns" => [],
          "tech_stack" => []
        })

      events = [%{"type" => "assistant", "content" => "```json\n#{json}\n```"}]

      assert {:ok, %{"architecture" => "OTP"}} = PhaseCollector.collect("research", "", events)
    end

    test "falls back to raw output" do
      json = Jason.encode!(%{"approved" => true, "coverage" => []})
      assert {:ok, %{"approved" => true}} = PhaseCollector.collect("review", json, [])
    end

    test "returns error for unparseable output" do
      assert {:error, :parse_failed} = PhaseCollector.collect("research", "no json here", [])
    end
  end
end
