defmodule GiTF.MCPServer.LspToolsTest do
  use ExUnit.Case, async: true

  alias GiTF.MCPServer.{Handlers, Tools}

  describe "tool registry" do
    test "all M3 LSP tools are exposed" do
      names = Tools.all() |> Enum.map(& &1.name)

      for tool <-
            ~w(lsp_diagnostics lsp_document_symbol lsp_workspace_symbol
               lsp_code_action lsp_apply_code_action) do
        assert tool in names, "expected MCP tool #{inspect(tool)} to be registered"
      end
    end

    test "each new tool declares required parameters" do
      tools = Tools.all() |> Enum.into(%{}, fn t -> {t.name, t} end)

      assert ["sector_id", "file_path"] == Map.get(tools["lsp_diagnostics"].inputSchema, :required)
      assert ["sector_id", "file_path"] == Map.get(tools["lsp_document_symbol"].inputSchema, :required)
      assert ["sector_id", "query"] == Map.get(tools["lsp_workspace_symbol"].inputSchema, :required)
      assert ["edit"] == Map.get(tools["lsp_apply_code_action"].inputSchema, :required)
    end
  end

  describe "handler — missing-parameter errors" do
    test "lsp_diagnostics without required args" do
      assert {:error, msg} = Handlers.call("lsp_diagnostics", %{})
      assert msg =~ "Missing"
    end

    test "lsp_document_symbol without required args" do
      assert {:error, msg} = Handlers.call("lsp_document_symbol", %{})
      assert msg =~ "Missing"
    end

    test "lsp_workspace_symbol without required args" do
      assert {:error, msg} = Handlers.call("lsp_workspace_symbol", %{})
      assert msg =~ "Missing"
    end

    test "lsp_code_action without required args" do
      assert {:error, msg} = Handlers.call("lsp_code_action", %{})
      assert msg =~ "Missing"
    end

    test "lsp_apply_code_action without required args" do
      assert {:error, msg} = Handlers.call("lsp_apply_code_action", %{})
      assert msg =~ "Missing"
    end
  end
end
