defmodule GiTF.Plugin.Builtin.Models.CopilotTest do
  use ExUnit.Case, async: true

  alias GiTF.Plugin.Builtin.Models.Copilot

  describe "name/0" do
    test "returns 'copilot'" do
      assert Copilot.name() == "copilot"
    end
  end

  describe "description/0" do
    test "returns a description string" do
      assert is_binary(Copilot.description())
      assert Copilot.description() =~ "Copilot"
    end
  end

  describe "parse_output/1" do
    test "wraps plain text lines as text events" do
      data = "Hello world\nDone.\n"
      events = Copilot.parse_output(data)

      assert [
               %{"type" => "text", "content" => "Hello world"},
               %{"type" => "text", "content" => "Done."}
             ] = events
    end

    test "handles single line without trailing newline" do
      events = Copilot.parse_output("Just one line")
      assert [%{"type" => "text", "content" => "Just one line"}] = events
    end

    test "handles empty data" do
      assert [] = Copilot.parse_output("")
    end
  end

  describe "capabilities/0" do
    test "returns expected capabilities" do
      caps = Copilot.capabilities()
      assert :tool_calling in caps
      assert :interactive in caps
      assert :headless in caps
      refute :streaming in caps
    end
  end

  describe "pricing/0" do
    test "returns empty map (subscription-based)" do
      assert Copilot.pricing() == %{}
    end
  end

  describe "workspace_setup/2" do
    test "returns nil" do
      assert Copilot.workspace_setup("ghost-123", "/tmp/hive") == nil
      assert Copilot.workspace_setup("major", "/tmp/hive") == nil
    end
  end

  describe "extract_costs/1" do
    test "always returns empty list" do
      events = [%{"type" => "text", "content" => "Done"}]
      assert Copilot.extract_costs(events) == []
    end
  end

  describe "extract_session_id/1" do
    test "always returns nil" do
      events = [%{"type" => "text", "content" => "Hello"}]
      assert Copilot.extract_session_id(events) == nil
    end
  end

  describe "progress_from_events/1" do
    test "extracts text content as progress messages" do
      events = [
        %{"type" => "text", "content" => "Working on feature X"},
        %{"type" => "text", "content" => "Done!"}
      ]

      progress = Copilot.progress_from_events(events)
      assert length(progress) == 2
      assert Enum.at(progress, 0).message == "Working on feature X"
      assert Enum.at(progress, 1).message == "Done!"
    end

    test "truncates long messages" do
      long = String.duplicate("a", 200)
      events = [%{"type" => "text", "content" => long}]
      [progress] = Copilot.progress_from_events(events)
      assert String.length(progress.message) == 120
    end
  end

  describe "find_executable/0" do
    test "returns {:ok, path} or {:error, :not_found}" do
      result = Copilot.find_executable()
      assert match?({:ok, _}, result) or match?({:error, :not_found}, result)
    end
  end
end
