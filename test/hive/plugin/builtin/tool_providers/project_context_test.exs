defmodule Hive.Plugin.Builtin.ToolProviders.ProjectContextTest do
  use ExUnit.Case, async: true

  alias Hive.Plugin.Builtin.ToolProviders.ProjectContext

  describe "tools/0" do
    test "returns three tools" do
      tools = ProjectContext.tools()
      assert length(tools) == 3

      names = Enum.map(tools, & &1.name)
      assert "project_info" in names
      assert "codebase_map" in names
      assert "dependency_info" in names
    end

    test "all tools are ReqLLM.Tool structs" do
      for tool <- ProjectContext.tools() do
        assert %ReqLLM.Tool{} = tool
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_function(tool.callback)
      end
    end
  end

  describe "project_info tool" do
    test "detects elixir project" do
      tool = find_tool("project_info")
      {:ok, result} = tool.callback.(%{"path" => File.cwd!()})

      assert result =~ "elixir"
      assert result =~ "mix"
    end
  end

  describe "codebase_map tool" do
    test "generates directory tree" do
      tool = find_tool("codebase_map")
      {:ok, result} = tool.callback.(%{"path" => File.cwd!(), "depth" => 1})

      assert result =~ "lib"
      assert result =~ "test"
      refute result =~ "node_modules"
      refute result =~ "_build"
    end
  end

  describe "dependency_info tool" do
    test "parses mix.lock when available" do
      tool = find_tool("dependency_info")
      {:ok, result} = tool.callback.(%{"path" => File.cwd!()})

      assert result =~ "mix"
    end
  end

  describe "metadata" do
    test "name is project_context" do
      assert ProjectContext.name() == "project_context"
    end

    test "plugin type is tool_provider" do
      assert ProjectContext.__plugin_type__() == :tool_provider
    end
  end

  defp find_tool(name) do
    Enum.find(ProjectContext.tools(), &(&1.name == name))
  end
end
