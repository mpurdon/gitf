defmodule GiTF.Web.CabinetBoundaryTest do
  @moduledoc """
  The Cabinet is a hard boundary (GiTF Control Surface plan, Phase 0):
  in cabinet mode no factory route resolves and no factory MCP tool runs.
  If someone plugs a factory surface back into the Cabinet, THIS is the
  test that fails.
  """

  use ExUnit.Case, async: false

  alias GiTF.MCPServer.Tools
  alias GiTF.Web.CabinetRouter

  defp routes?(path, method \\ "GET") do
    Phoenix.Router.route_info(CabinetRouter, method, path, "cabinet.test") != :error
  end

  describe "routes" do
    test "factory surfaces do not exist on the Cabinet router" do
      for path <- [
            "/dashboard/missions",
            "/dashboard/ghosts",
            "/dashboard/approvals",
            "/dashboard/sectors",
            "/dashboard/questions",
            "/floor",
            "/api/v1/missions"
          ] do
        refute routes?(path), "#{path} must not route in cabinet mode"
      end
    end

    test "the Cabinet's own surfaces do exist" do
      assert routes?("/")
      assert routes?("/hooks/some-ministry", "POST")
      assert routes?("/api/v1/health")
      assert routes?("/api/v1/mcp", "POST")
      assert routes?("/metrics")
    end
  end

  describe "tools" do
    setup do
      prior = Application.get_env(:gitf, :cabinet_mode, false)
      Application.put_env(:gitf, :cabinet_mode, true)
      on_exit(fn -> Application.put_env(:gitf, :cabinet_mode, prior) end)
      :ok
    end

    test "tools/list exposes only the cabinet set" do
      %{result: %{tools: tools}} =
        GiTF.MCPServer.handle_rpc(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list"
        })

      names = Enum.map(tools, & &1.name)
      assert Enum.sort(names) == Enum.sort(Tools.cabinet_tool_names())
      refute "create_mission" in names
      refute "list_ghosts" in names
    end

    test "calling a factory tool is refused with a pointer to ministry_call" do
      %{result: %{isError: true, content: [%{text: text}]}} =
        GiTF.MCPServer.handle_rpc(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "create_mission", "arguments" => %{}}
        })

      assert text =~ "factory tool"
      assert text =~ "ministry_call"
    end

    test "the cabinet set itself stays callable" do
      %{result: %{content: [%{text: text}]}} =
        GiTF.MCPServer.handle_rpc(%{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{"name" => "cabinet_status", "arguments" => %{}}
        })

      assert text =~ "cabinet_mode"
    end
  end
end
