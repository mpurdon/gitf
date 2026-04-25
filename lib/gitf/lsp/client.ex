defmodule GiTF.LSP.Client do
  @moduledoc """
  Long-lived Language Server Protocol client.

  Spawns a language server (default: ElixirLS) as a port and speaks
  JSON-RPC 2.0 over stdio. M1 ships only `textDocument/definition`;
  references + hover land in M2.

  ## Lifecycle

  Each client owns one server process scoped to a single workspace
  (`root_path`). `start_link/1` launches the port and runs the LSP
  initialize handshake. `definition/4` blocks until the server replies
  or `:request_timeout_ms` (default 5s) elapses.

  ## Configuration

  Driver lookup order:
    1. `:lsp_executable` Application env (absolute path)
    2. `LSP_EXECUTABLE` env var
    3. `language_server.sh` on `PATH`

  Feature-gated by `:lsp_enabled`; when off, public callers should
  short-circuit before hitting this module.
  """

  use GenServer
  require Logger

  alias GiTF.LSP.Framing

  @request_timeout_ms 5_000
  @init_timeout_ms 30_000

  @type t :: pid() | atom()

  # -- Client API ------------------------------------------------------------

  @doc """
  Starts an LSP client for the given workspace path. Blocks until the
  initialize handshake completes (or fails). Returns
  `{:error, :driver_unavailable}` when no executable is on PATH.
  """
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :driver_unavailable}
  def start_link(opts) do
    case driver_path() do
      nil -> {:error, :driver_unavailable}
      _ -> GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end
  end

  @doc """
  Returns the location(s) of the symbol at the given position. Position
  is `{line, character}` 0-indexed. Returns `{:ok, [%{uri, range}]}` on
  success, `{:ok, []}` if no definition, or `{:error, reason}`.
  """
  @spec definition(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def definition(server, file_path, line, character)
      when is_binary(file_path) and is_integer(line) and is_integer(character) do
    GenServer.call(
      server,
      {:request, "textDocument/definition",
       %{
         textDocument: %{uri: file_uri(file_path)},
         position: %{line: line, character: character}
       }},
      @request_timeout_ms + 1_000
    )
  end

  @doc "Stops the client, sending the LSP shutdown + exit handshake."
  @spec stop(t()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal, 5_000)

  @doc "True when an LSP driver is on PATH."
  @spec available?() :: boolean()
  def available?, do: not is_nil(driver_path())

  @doc "True when `:lsp_enabled` is set."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:gitf, :lsp_enabled, false) == true

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    root_path = Keyword.fetch!(opts, :root_path)
    driver = driver_path() || raise "LSP driver not found on PATH"

    port =
      Port.open(
        {:spawn_executable, driver},
        [:binary, :exit_status, :use_stdio, :hide, args: []]
      )

    state = %{
      port: port,
      buffer: <<>>,
      pending: %{},
      next_id: 1,
      root_path: root_path
    }

    case do_initialize(state) do
      {:ok, new_state} -> {:ok, new_state}
      {:error, reason} -> {:stop, {:initialize_failed, reason}}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    {id, state} = next_id(state)
    payload = %{jsonrpc: "2.0", id: id, method: method, params: params}
    Port.command(state.port, Framing.encode(payload))
    state = %{state | pending: Map.put(state.pending, id, from)}

    Process.send_after(self(), {:request_timeout, id}, @request_timeout_ms)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {messages, buffer} = Framing.parse(state.buffer <> chunk)
    state = %{state | buffer: buffer}
    state = Enum.reduce(messages, state, &handle_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("LSP server exited with status #{code}")
    fail_pending(state, {:lsp_exited, code})
    {:stop, :normal, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = state) do
    fail_pending(state, :stopped)

    try do
      Port.command(port, Framing.encode(%{jsonrpc: "2.0", id: 0, method: "shutdown", params: nil}))
      Port.command(port, Framing.encode(%{jsonrpc: "2.0", method: "exit", params: nil}))
    rescue
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    :ok
  end

  # -- Internal --------------------------------------------------------------

  defp do_initialize(state) do
    {id, state} = next_id(state)

    payload = %{
      jsonrpc: "2.0",
      id: id,
      method: "initialize",
      params: %{
        processId: :os.getpid() |> List.to_integer(),
        rootUri: file_uri(state.root_path),
        capabilities: %{
          textDocument: %{
            definition: %{linkSupport: false}
          }
        }
      }
    }

    Port.command(state.port, Framing.encode(payload))

    case wait_for_response(state, id, @init_timeout_ms) do
      {:ok, _result, state} ->
        Port.command(
          state.port,
          Framing.encode(%{jsonrpc: "2.0", method: "initialized", params: %{}})
        )

        {:ok, state}

      {:error, _} = err ->
        err
    end
  end

  # Synchronous read loop used only during initialize, before the
  # GenServer mainloop takes over message dispatch.
  defp wait_for_response(state, id, timeout_ms) do
    receive do
      {port, {:data, chunk}} when port == state.port ->
        {messages, buffer} = Framing.parse(state.buffer <> chunk)
        state = %{state | buffer: buffer}

        case Enum.find(messages, &(Map.get(&1, "id") == id)) do
          nil ->
            wait_for_response(state, id, timeout_ms)

          %{"result" => result} ->
            {:ok, result, state}

          %{"error" => err} ->
            {:error, err}
        end

      {port, {:exit_status, code}} when port == state.port ->
        {:error, {:exited, code}}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp handle_message(%{"id" => id} = msg, state) when is_integer(id) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {from, pending} ->
        reply =
          case msg do
            %{"result" => result} -> {:ok, normalize_result(result)}
            %{"error" => err} -> {:error, err}
            _ -> {:error, :malformed_response}
          end

        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp handle_message(_notification, state), do: state

  # textDocument/definition can return null, a single Location, or a list.
  # Normalize to a list of plain maps.
  defp normalize_result(nil), do: []
  defp normalize_result(list) when is_list(list), do: list
  defp normalize_result(%{} = single), do: [single]

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp fail_pending(%{pending: pending}, reason) do
    for {_, from} <- pending, do: GenServer.reply(from, {:error, reason})
  end

  defp file_uri("file://" <> _ = uri), do: uri
  defp file_uri(path), do: "file://" <> Path.expand(path)

  defp driver_path do
    Application.get_env(:gitf, :lsp_executable) ||
      System.get_env("LSP_EXECUTABLE") ||
      System.find_executable("language_server.sh") ||
      System.find_executable("elixir-ls")
  end
end
