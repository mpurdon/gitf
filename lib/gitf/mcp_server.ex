defmodule GiTF.MCPServer do
  @moduledoc """
  MCP (Model Context Protocol) server for GiTF.

  Supports two transports:
  - **stdio**: for direct process spawning (legacy `gitf mcp-serve`)
  - **Unix socket**: for daemon mode (`gitf server` with socket listener)

  Both use newline-delimited JSON-RPC 2.0.
  """

  require Logger

  @protocol_version "2024-11-05"

  # -- Public API: process a single JSON-RPC message --------------------------

  @doc """
  Handles a parsed JSON-RPC message and returns a response map (or nil for notifications).

  Used by both the stdio loop and the socket listener.
  """
  @spec handle_rpc(map()) :: map() | nil
  def handle_rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = msg) do
    params = msg["params"] || %{}

    result =
      case method do
        "initialize" -> handle_initialize()
        "tools/list" -> handle_tools_list()
        "tools/call" -> handle_tools_call(params)
        _ -> {:error, -32601, "Method not found: #{method}"}
      end

    case result do
      {:ok, body} ->
        %{jsonrpc: "2.0", id: id, result: body}

      {:error, code, message} ->
        %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
    end
  end

  # Notifications (no id) — no response
  def handle_rpc(%{"jsonrpc" => "2.0", "method" => _}), do: nil
  def handle_rpc(_), do: nil

  # -- Stdio transport --------------------------------------------------------

  @doc "Runs the MCP server loop, reading from stdin until EOF."
  def run do
    loop("")
  end

  defp loop(buffer) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data ->
        buffer = buffer <> data
        {messages, remaining} = parse_messages(buffer)

        Enum.each(messages, fn msg ->
          response = handle_rpc(msg)
          if response, do: write_stdout(Jason.encode!(response) <> "\n")
        end)

        loop(remaining)
    end
  end

  defp parse_messages(buffer) do
    lines = String.split(buffer, "\n")
    {complete, [remaining]} = Enum.split(lines, -1)

    messages =
      complete
      |> Enum.reject(&(&1 == "" or String.trim(&1) == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, parsed} -> [parsed]
          {:error, _} -> []
        end
      end)

    {messages, remaining}
  end

  # -- Internals --------------------------------------------------------------

  defp handle_initialize do
    {:ok,
     %{
       protocolVersion: @protocol_version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "gitf", version: GiTF.version()}
     }}
  end

  defp handle_tools_list do
    {:ok, %{tools: GiTF.MCPServer.Tools.all()}}
  end

  defp handle_tools_call(%{"name" => name, "arguments" => args}) do
    case GiTF.MCPServer.Handlers.call(name, args) do
      {:ok, text} ->
        {:ok, %{content: [%{type: "text", text: text}]}}

      {:error, message} ->
        {:ok, %{content: [%{type: "text", text: "Error: #{message}"}], isError: true}}
    end
  rescue
    e ->
      {:ok,
       %{
         content: [%{type: "text", text: "Internal error: #{Exception.message(e)}"}],
         isError: true
       }}
  end

  defp handle_tools_call(_) do
    {:error, -32602, "Invalid params: name and arguments required"}
  end

  # Write directly to fd 1, bypassing the Erlang IO system.
  defp write_stdout(data) do
    case Process.get(:mcp_stdout) do
      nil ->
        {:ok, fd} = :file.open(~c"/dev/fd/1", [:write, :raw, :binary])
        Process.put(:mcp_stdout, fd)
        :file.write(fd, data)

      fd ->
        :file.write(fd, data)
    end
  end
end
