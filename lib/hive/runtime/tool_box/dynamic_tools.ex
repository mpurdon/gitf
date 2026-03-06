defmodule Hive.Runtime.ToolBox.DynamicTools do
  @moduledoc """
  Discovers tools from running MCP servers, LSP plugins, and registered
  tool providers. Returns `[ReqLLM.Tool.t()]` that get appended to
  the static tool set.
  """

  require Logger

  @doc """
  Discovers dynamic tools from all sources.

  Returns a flat list of `ReqLLM.Tool` structs. Never raises — failures
  in any source are logged and skipped.
  """
  @spec discover(keyword()) :: [ReqLLM.Tool.t()]
  def discover(_opts \\ []) do
    mcp_tools() ++ lsp_tools() ++ provider_tools()
  rescue
    e ->
      Logger.debug("Dynamic tool discovery failed: #{Exception.message(e)}")
      []
  end

  # -- MCP tools ---------------------------------------------------------------

  defp mcp_tools do
    children = DynamicSupervisor.which_children(Hive.Plugin.MCPSupervisor)

    Enum.flat_map(children, fn
      {_, pid, _, _} when is_pid(pid) ->
        convert_mcp_tools(pid)

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp convert_mcp_tools(pid) do
    tools = Hive.Plugin.MCPClient.list_tools(pid)

    Enum.map(tools, fn tool ->
      name = "mcp_#{tool["name"]}"
      description = tool["description"] || ""
      schema = build_mcp_schema(tool["inputSchema"])

      callback = fn args ->
        case Hive.Plugin.MCPClient.call_tool(pid, tool["name"], args) do
          {:ok, result} -> {:ok, format_mcp_result(result)}
          {:error, reason} -> {:ok, "MCP tool error: #{inspect(reason)}"}
        end
      end

      opts = [name: name, description: description, callback: callback]
      opts = if schema, do: Keyword.put(opts, :parameter_schema, schema), else: opts
      ReqLLM.Tool.new!(opts)
    end)
  rescue
    e ->
      Logger.debug("Failed to convert MCP tools from #{inspect(pid)}: #{Exception.message(e)}")
      []
  end

  defp build_mcp_schema(nil), do: nil

  defp build_mcp_schema(%{"properties" => props}) when is_map(props) do
    Enum.map(props, fn {key, spec} ->
      type =
        case spec["type"] do
          "string" -> :string
          "integer" -> :integer
          "number" -> :number
          "boolean" -> :boolean
          _ -> :string
        end

      {String.to_atom(key),
       [type: type, doc: spec["description"] || ""]}
    end)
  end

  defp build_mcp_schema(_), do: nil

  defp format_mcp_result(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp format_mcp_result(result) when is_binary(result), do: result
  defp format_mcp_result(result), do: inspect(result)

  # -- LSP tools ---------------------------------------------------------------

  defp lsp_tools do
    lsp_plugins = Hive.Plugin.Registry.list(:lsp)

    if lsp_plugins == [] do
      []
    else
      [
        ReqLLM.Tool.new!(
          name: "get_diagnostics",
          description: "Get language server diagnostics for a file. Returns compiler errors, warnings, and hints.",
          parameter_schema: [
            file_uri: [type: :string, required: true, doc: "File URI (e.g. file:///path/to/file.ex)"]
          ],
          callback: fn args ->
            uri = args["file_uri"] || args[:file_uri]
            diagnostics = collect_lsp_diagnostics(lsp_plugins, uri)
            {:ok, diagnostics}
          end
        )
      ]
    end
  rescue
    _ -> []
  end

  defp collect_lsp_diagnostics(plugins, uri) do
    plugins
    |> Enum.flat_map(fn {_name, module} ->
      try do
        module.diagnostics(uri)
      rescue
        _ -> []
      end
    end)
    |> Enum.map(fn d ->
      severity = Map.get(d, :severity, Map.get(d, "severity", "unknown"))
      line = Map.get(d, :line, Map.get(d, "line", "?"))
      message = Map.get(d, :message, Map.get(d, "message", ""))
      "#{severity}:#{line}: #{message}"
    end)
    |> Enum.join("\n")
    |> case do
      "" -> "No diagnostics found."
      text -> text
    end
  end

  # -- Tool provider tools -----------------------------------------------------

  defp provider_tools do
    Hive.Plugin.Registry.list(:tool_provider)
    |> Enum.flat_map(fn {_name, module} ->
      try do
        module.tools()
      rescue
        e ->
          Logger.debug("Tool provider #{inspect(module)} failed: #{Exception.message(e)}")
          []
      end
    end)
  rescue
    _ -> []
  end
end
