defmodule Hive.Plugin.Builtin.ToolProviders.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Hive.Plugin.Builtin.ToolProviders.Workspace
  alias Hive.Store

  setup do
    store_dir = Path.join(System.tmp_dir!(), "hive-ws-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    Hive.Test.StoreHelper.stop_store()
    start_supervised!({Store, data_dir: store_dir})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "tools/0" do
    test "returns three tools" do
      tools = Workspace.tools()
      assert length(tools) == 3

      names = Enum.map(tools, & &1.name)
      assert "list_combs" in names
      assert "comb_info" in names
      assert "list_cells" in names
    end

    test "all tools are ReqLLM.Tool structs" do
      for tool <- Workspace.tools() do
        assert %ReqLLM.Tool{} = tool
        assert is_function(tool.callback)
      end
    end
  end

  describe "list_combs tool" do
    test "returns message when no combs" do
      tool = find_tool("list_combs")
      {:ok, result} = tool.callback.(%{})

      assert result =~ "No combs"
    end

    test "lists registered combs" do
      Store.insert(:combs, %{id: "comb-ws-1", name: "test-comb", path: "/tmp/test"})

      tool = find_tool("list_combs")
      {:ok, result} = tool.callback.(%{})

      assert result =~ "test-comb"
      assert result =~ "comb-ws-1"
    end
  end

  describe "list_cells tool" do
    test "returns message when no cells" do
      tool = find_tool("list_cells")
      {:ok, result} = tool.callback.(%{})

      assert result =~ "No active cells"
    end

    test "lists cells with bee assignments" do
      Store.insert(:cells, %{id: "cell-1", bee_id: "bee-abc", path: "/tmp/cell1"})

      tool = find_tool("list_cells")
      {:ok, result} = tool.callback.(%{})

      assert result =~ "cell-1"
      assert result =~ "bee-abc"
    end
  end

  describe "metadata" do
    test "name is workspace" do
      assert Workspace.name() == "workspace"
    end

    test "plugin type is tool_provider" do
      assert Workspace.__plugin_type__() == :tool_provider
    end
  end

  defp find_tool(name) do
    Enum.find(Workspace.tools(), &(&1.name == name))
  end
end
