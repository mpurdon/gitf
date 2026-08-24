defmodule GiTF.MCPServer.SectorToolsTest do
  use ExUnit.Case, async: false

  alias GiTF.MCPServer.{Handlers, Tools}

  setup do
    tmp = Path.join(System.tmp_dir!(), "gitf_mcp_sector_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    GiTF.Test.StoreHelper.stop_store()
    {:ok, _} = GiTF.Archive.start_link(data_dir: tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, sector} =
      GiTF.Archive.insert(:sectors, %{
        name: "repo",
        path: tmp,
        validation_command: "npm test",
        validation_timeout_ms: 900_000
      })

    %{sector: sector}
  end

  describe "sector serialization" do
    # The validation contract used to be invisible over MCP: cora carried a
    # hand-set 900s budget that Validator honoured while Audit hardcoded
    # 120s, and no tool an operator could call showed the field existed.
    test "list_sectors exposes the validation contract", %{sector: sector} do
      {:ok, text} = Handlers.call("list_sectors", %{})
      [serialized] = Jason.decode!(text)

      assert serialized["id"] == sector.id
      assert serialized["validation_command"] == "npm test"
      assert serialized["validation_timeout_ms"] == 900_000
    end
  end

  describe "set_validation_timeout" do
    test "sets an override", %{sector: sector} do
      assert {:ok, _} =
               Handlers.call("set_validation_timeout", %{
                 "sector_id" => sector.id,
                 "timeout_ms" => 600_000,
                 "confirm" => true
               })

      assert GiTF.Archive.get(:sectors, sector.id)[:validation_timeout_ms] == 600_000
    end

    test "clear: true hands the sector back to the default", %{sector: sector} do
      assert {:ok, _} =
               Handlers.call("set_validation_timeout", %{
                 "sector_id" => sector.id,
                 "clear" => true,
                 "confirm" => true
               })

      assert GiTF.Archive.get(:sectors, sector.id)[:validation_timeout_ms] == nil
      # Which the resolution function turns into the 120s default.
      assert GiTF.Validator.validation_timeout_ms(GiTF.Archive.get(:sectors, sector.id)) ==
               120_000
    end

    test "rejects a nonsense value without touching the sector", %{sector: sector} do
      for bad <- [0, -5, 999, 3_600_000, "fast", nil] do
        assert {:error, _} =
                 Handlers.call("set_validation_timeout", %{
                   "sector_id" => sector.id,
                   "timeout_ms" => bad,
                   "confirm" => true
                 })
      end

      assert GiTF.Archive.get(:sectors, sector.id)[:validation_timeout_ms] == 900_000
    end

    test "requires confirm", %{sector: sector} do
      assert {:error, msg} =
               Handlers.call("set_validation_timeout", %{
                 "sector_id" => sector.id,
                 "timeout_ms" => 600_000
               })

      assert msg =~ "confirm"
    end
  end

  describe "tool registry" do
    test "set_validation_timeout is registered and start_mission declares full" do
      tools = Tools.all() |> Enum.into(%{}, fn t -> {t.name, t} end)

      assert Map.has_key?(tools, "set_validation_timeout")
      assert "confirm" in (tools["set_validation_timeout"].inputSchema[:required] || [])

      # The handler honoured `full` long before the schema admitted it
      # existed — an MCP client reading the schema could never discover the
      # option this session's routing fixes were built around.
      start_props = tools["start_mission"].inputSchema[:properties]
      assert Map.has_key?(start_props, :full)
      assert Map.has_key?(start_props, :fast)
    end
  end
end
