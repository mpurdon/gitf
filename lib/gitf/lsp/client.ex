defmodule GiTF.LSP.Client do
  @moduledoc """
  Long-lived Language Server Protocol client.

  Spawns a language server (default: ElixirLS) as a port and speaks
  JSON-RPC 2.0 over stdio.

    * **M1**: `textDocument/definition`
    * **M2**: `textDocument/references`, `textDocument/hover`
    * **M3**: `textDocument/publishDiagnostics` (server-pushed),
      `textDocument/documentSymbol`, `workspace/symbol`,
      `textDocument/codeAction`, plus `did_open/2` / `did_close/2`
      lifecycle for diagnostics.

  ## Lifecycle

  Each client owns one server process scoped to a single workspace
  (`root_path`). `start_link/1` launches the port and runs the LSP
  initialize handshake. Request calls (`definition/4`, `references/5`,
  `hover/4`, `document_symbol/2`, `workspace_symbol/2`,
  `code_action/4`) block until the server replies or
  `:request_timeout_ms` (default 5s) elapses.

  Diagnostics are different: the server pushes
  `textDocument/publishDiagnostics` notifications whenever it
  re-analyzes a file, with no preceding client request. The client
  caches the latest set per URI; `diagnostics/2` returns the cache
  immediately. Callers wanting fresh diagnostics should
  `did_open/2` first and poll briefly for the first publish (ElixirLS
  can take several seconds to analyze on cold start).

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

  @doc """
  Returns the locations that reference the symbol at the given
  position. `include_declaration` (default false) controls whether the
  declaration itself appears in the result list.
  """
  @spec references(t(), String.t(), non_neg_integer(), non_neg_integer(), boolean()) ::
          {:ok, [map()]} | {:error, term()}
  def references(server, file_path, line, character, include_declaration \\ false)
      when is_binary(file_path) and is_integer(line) and is_integer(character) do
    GenServer.call(
      server,
      {:request, "textDocument/references",
       %{
         textDocument: %{uri: file_uri(file_path)},
         position: %{line: line, character: character},
         context: %{includeDeclaration: include_declaration}
       }},
      @request_timeout_ms + 1_000
    )
  end

  @doc """
  Returns the hover information for the symbol at the given position
  (typically a type signature + docstring). Returns
  `{:ok, %{contents: ..., range: ...}}` or `{:ok, nil}` if no hover.
  """
  @spec hover(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def hover(server, file_path, line, character)
      when is_binary(file_path) and is_integer(line) and is_integer(character) do
    case GenServer.call(
           server,
           {:request, "textDocument/hover",
            %{
              textDocument: %{uri: file_uri(file_path)},
              position: %{line: line, character: character}
            }},
           @request_timeout_ms + 1_000
         ) do
      {:ok, [single]} -> {:ok, single}
      {:ok, []} -> {:ok, nil}
      {:ok, list} when is_list(list) -> {:ok, List.first(list)}
      other -> other
    end
  end

  @doc """
  Returns the symbol outline of a file (`textDocument/documentSymbol`).
  Output is the server's response — typically a list of either
  `DocumentSymbol` (hierarchical with `children`) or `SymbolInformation`
  (flat with `location`) maps. ElixirLS returns the hierarchical shape.
  """
  @spec document_symbol(t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def document_symbol(server, file_path) when is_binary(file_path) do
    GenServer.call(
      server,
      {:request, "textDocument/documentSymbol",
       %{textDocument: %{uri: file_uri(file_path)}}},
      @request_timeout_ms + 1_000
    )
  end

  @doc """
  Workspace-wide symbol search by name (`workspace/symbol`). `query` is
  matched server-side using whatever heuristic the server prefers
  (ElixirLS does substring + camel-hump). Returns a list of
  `SymbolInformation` maps with `name`, `kind`, `location`.
  """
  @spec workspace_symbol(t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def workspace_symbol(server, query) when is_binary(query) do
    GenServer.call(
      server,
      {:request, "workspace/symbol", %{query: query}},
      @request_timeout_ms + 1_000
    )
  end

  @doc """
  Returns available code actions for `range` in `file_path`. `context`
  is the standard LSP `CodeActionContext` (`diagnostics`, `only`,
  `triggerKind`); pass `%{}` to let the server default it.

  Result is a list of `Command` or `CodeAction` maps. To apply one,
  use `apply_workspace_edit/2` with the `edit` field, or
  `execute_command/2` with the `command` field — neither side effect
  happens automatically.
  """
  @spec code_action(t(), String.t(), map(), map()) :: {:ok, [map()]} | {:error, term()}
  def code_action(server, file_path, range, context \\ %{})
      when is_binary(file_path) and is_map(range) do
    GenServer.call(
      server,
      {:request, "textDocument/codeAction",
       %{
         textDocument: %{uri: file_uri(file_path)},
         range: range,
         context: context
       }},
      @request_timeout_ms + 1_000
    )
  end

  @doc """
  Server-side execution of a command (`workspace/executeCommand`). Used
  to invoke commands attached to a `CodeAction` that the server wants
  to run itself (e.g., import organization that requires a workspace
  walk).
  """
  @spec execute_command(t(), String.t(), [term()]) :: {:ok, term()} | {:error, term()}
  def execute_command(server, command, arguments \\ []) when is_binary(command) do
    GenServer.call(
      server,
      {:request, "workspace/executeCommand",
       %{command: command, arguments: arguments}},
      @request_timeout_ms + 1_000
    )
  end

  @doc """
  Returns the cached diagnostics for `file_path`. Caller should
  `did_open/2` the file first if it hasn't been opened — diagnostics
  only flow once the server knows the file is "open".

  Returns `{:ok, [diagnostic]}` where each diagnostic is the raw
  server map (`%{range, severity, source, message, code, ...}`). On
  cache miss returns `{:ok, []}` — there's no way to know if that
  means "no errors" or "not yet analyzed" without a wait, so
  callers that need certainty should `did_open/2` and poll.
  """
  @spec diagnostics(t(), String.t()) :: {:ok, [map()]}
  def diagnostics(server, file_path) when is_binary(file_path) do
    GenServer.call(server, {:get_diagnostics, file_uri(file_path)})
  end

  @doc """
  Tells the server we're now editing `file_path`
  (`textDocument/didOpen`). One-way; no response. The server starts
  pushing diagnostics for the file shortly after.

  `language_id` defaults to `"elixir"` since that's the primary target.
  Set explicitly for other languages.
  """
  @spec did_open(t(), String.t(), keyword()) :: :ok
  def did_open(server, file_path, opts \\ []) when is_binary(file_path) do
    GenServer.cast(server, {:did_open, file_path, opts})
  end

  @doc """
  Tells the server we're done editing `file_path` (`textDocument/didClose`).
  Drops the cached diagnostics for that URI.
  """
  @spec did_close(t(), String.t()) :: :ok
  def did_close(server, file_path) when is_binary(file_path) do
    GenServer.cast(server, {:did_close, file_path})
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
      root_path: root_path,
      status: :initializing,
      queued: [],
      diagnostics: %{},
      open_uris: MapSet.new()
    }

    # Return immediately so DynamicSupervisor.start_child unblocks the
    # MCP caller. Initialize handshake runs in handle_continue, requests
    # arriving meanwhile queue up in the GenServer mailbox.
    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    case do_initialize(state) do
      {:ok, ready_state} ->
        ready_state = %{ready_state | status: :ready}
        Enum.each(Enum.reverse(ready_state.queued), fn {from, method, params} ->
          send(self(), {:flush_queued, from, method, params})
        end)

        {:noreply, %{ready_state | queued: []}}

      {:error, reason} ->
        Enum.each(state.queued, fn {from, _, _} ->
          GenServer.reply(from, {:error, {:initialize_failed, reason}})
        end)

        {:stop, {:initialize_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, %{status: :initializing} = state) do
    {:noreply, %{state | queued: [{from, method, params} | state.queued]}}
  end

  def handle_call({:request, method, params}, from, state) do
    {id, state} = next_id(state)
    payload = %{jsonrpc: "2.0", id: id, method: method, params: params}
    Port.command(state.port, Framing.encode(payload))
    state = %{state | pending: Map.put(state.pending, id, from)}

    Process.send_after(self(), {:request_timeout, id}, @request_timeout_ms)

    {:noreply, state}
  end

  def handle_call({:get_diagnostics, uri}, _from, state) do
    {:reply, {:ok, Map.get(state.diagnostics, uri, [])}, state}
  end

  @impl true
  def handle_cast({:did_open, file_path, opts}, state) do
    uri = file_uri(file_path)

    if MapSet.member?(state.open_uris, uri) do
      # Already open — re-sending didOpen makes ElixirLS re-analyze and
      # restart the diagnostic publish loop. Drop the cast.
      {:noreply, state}
    else
      send_did_open(state, file_path, uri, opts)
    end
  end

  def handle_cast({:did_close, file_path}, state) do
    uri = file_uri(file_path)

    payload = %{
      jsonrpc: "2.0",
      method: "textDocument/didClose",
      params: %{textDocument: %{uri: uri}}
    }

    if state.status == :ready do
      Port.command(state.port, Framing.encode(payload))
    end

    {:noreply,
     %{
       state
       | diagnostics: Map.delete(state.diagnostics, uri),
         open_uris: MapSet.delete(state.open_uris, uri)
     }}
  end

  # Read the file on the caller thread via Task so the GenServer
  # mailbox isn't blocked on disk I/O when many files are opened in a
  # row. The Task's result is sent back to self() as a :did_open_ready
  # message that performs the actual Port.command.
  defp send_did_open(state, file_path, uri, opts) do
    language_id = Keyword.get(opts, :language_id, "elixir")
    server = self()

    Task.start(fn ->
      text =
        case File.read(file_path) do
          {:ok, content} -> content
          _ -> ""
        end

      send(server, {:did_open_ready, uri, language_id, text})
    end)

    # Track the URI immediately so a follow-up did_open cast for the
    # same path coalesces even before the Task finishes.
    {:noreply,
     %{
       state
       | open_uris: MapSet.put(state.open_uris, uri),
         diagnostics: Map.put_new(state.diagnostics, uri, [])
     }}
  end

  @impl true
  def handle_info({:flush_queued, from, method, params}, state) do
    {id, state} = next_id(state)
    payload = %{jsonrpc: "2.0", id: id, method: method, params: params}
    Port.command(state.port, Framing.encode(payload))
    state = %{state | pending: Map.put(state.pending, id, from)}

    Process.send_after(self(), {:request_timeout, id}, @request_timeout_ms)

    {:noreply, state}
  end

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

  def handle_info({:did_open_ready, uri, language_id, text}, state) do
    payload = %{
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: %{
        textDocument: %{
          uri: uri,
          languageId: language_id,
          version: 1,
          text: text
        }
      }
    }

    if state.status == :ready do
      Port.command(state.port, Framing.encode(payload))
    end

    {:noreply, state}
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
            definition: %{linkSupport: false},
            references: %{},
            hover: %{},
            documentSymbol: %{hierarchicalDocumentSymbolSupport: true},
            codeAction: %{
              codeActionLiteralSupport: %{
                codeActionKind: %{valueSet: ["quickfix", "refactor", "source"]}
              }
            },
            publishDiagnostics: %{}
          },
          workspace: %{
            symbol: %{},
            executeCommand: %{}
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

        case Enum.split_with(messages, &(Map.get(&1, "id") == id)) do
          {[matched | _], others} ->
            # Drain notifications (e.g. publishDiagnostics) that the
            # server may have pushed before the initialize response —
            # the mainloop hasn't started yet so they'd otherwise be
            # silently dropped from the cache.
            state = Enum.reduce(others, state, &handle_message/2)

            case matched do
              %{"result" => result} -> {:ok, result, state}
              %{"error" => err} -> {:error, err}
            end

          {[], notifications} ->
            state = Enum.reduce(notifications, state, &handle_message/2)
            wait_for_response(state, id, timeout_ms)
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

  # Server notification: `textDocument/publishDiagnostics`. Cache the
  # latest set per URI; readers fetch via `get_diagnostics`.
  defp handle_message(
         %{"method" => "textDocument/publishDiagnostics", "params" => params},
         state
       ) do
    uri = Map.get(params, "uri")
    diags = Map.get(params, "diagnostics", [])

    if is_binary(uri) do
      %{state | diagnostics: Map.put(state.diagnostics, uri, diags)}
    else
      state
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
