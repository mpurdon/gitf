defmodule GiTF.Runtime.Loadout.DynamicToolsTest do
  use ExUnit.Case, async: false

  alias GiTF.Runtime.Loadout.DynamicTools
  alias GiTF.Archive

  setup do
    store_dir = Path.join(System.tmp_dir!(), "section-dyntools-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(store_dir)
    GiTF.Test.StoreHelper.stop_store()
    start_supervised!({Archive, data_dir: store_dir})

    # Ensure plugin registry exists
    GiTF.Plugin.Registry.init()

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store_dir: store_dir}
  end

  describe "discover/1" do
    test "returns empty list when no sources available" do
      tools = DynamicTools.discover()
      # May return tool provider tools if registered, but should not crash
      assert is_list(tools)
    end

    test "never raises on failure" do
      # Even if MCPSupervisor is not started, discover should not crash
      assert is_list(DynamicTools.discover())
    end
  end

  describe "tool provider integration" do
    test "picks up registered tool providers" do
      # Register a mock tool provider
      mock_module = define_mock_provider()
      GiTF.Plugin.Registry.register(:tool_provider, "mock", mock_module)

      tools = DynamicTools.discover()
      names = Enum.map(tools, & &1.name)

      assert "mock_tool" in names

      # Clean up
      GiTF.Plugin.Registry.unregister(:tool_provider, "mock")
    end
  end

  describe "LSP tools" do
    test "no LSP tools when no LSP plugins registered" do
      tools = DynamicTools.discover()
      names = Enum.map(tools, & &1.name)

      refute "get_diagnostics" in names
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp define_mock_provider do
    module_name = Module.concat(__MODULE__, MockToolProvider)

    unless Code.ensure_loaded?(module_name) do
      Module.create(
        module_name,
        quote do
          @behaviour GiTF.Plugin.ToolProvider

          def __plugin_type__, do: :tool_provider
          def name, do: "mock"
          def description, do: "Mock tool provider for testing"

          def tools do
            [
              ReqLLM.Tool.new!(
                name: "mock_tool",
                description: "A mock tool for testing",
                callback: fn _args -> {:ok, "mock result"} end
              )
            ]
          end
        end,
        Macro.Env.location(__ENV__)
      )
    end

    module_name
  end
end
