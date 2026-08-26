defmodule GiTF.LSP do
  @moduledoc """
  Facade over the per-sector LSP client pool.

  Callers (MCP handlers, phase ghosts) ask for symbol-aware queries by
  `sector_id`. This module:

    1. Looks up the sector's repo path from `:sectors`.
    2. Resolves (or lazily starts) the `GiTF.LSP.Client` for it.
    3. Forwards the call.

  Returns `{:error, :disabled}` when `:lsp_enabled` is off,
  `{:error, :driver_unavailable}` when no language server is on PATH,
  `{:error, :sector_not_found}` for unknown sectors. All other errors
  bubble up from `Client`.
  """

  alias GiTF.LSP.{Client, Supervisor}

  @type position_result :: {:ok, [map()] | map() | nil} | {:error, term()}

  @doc "Symbol definition lookup at file/line/character."
  @spec definition(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          position_result()
  def definition(sector_id, file_path, line, character) do
    with_client(sector_id, &Client.definition(&1, file_path, line, character))
  end

  @doc "Symbol references at file/line/character."
  @spec references(String.t(), String.t(), non_neg_integer(), non_neg_integer(), boolean()) ::
          position_result()
  def references(sector_id, file_path, line, character, include_declaration \\ false) do
    with_client(
      sector_id,
      &Client.references(&1, file_path, line, character, include_declaration)
    )
  end

  @doc "Hover info at file/line/character."
  @spec hover(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: position_result()
  def hover(sector_id, file_path, line, character) do
    with_client(sector_id, &Client.hover(&1, file_path, line, character))
  end

  @doc """
  Returns the symbol outline of a file. See `Client.document_symbol/2`.
  """
  @spec document_symbol(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def document_symbol(sector_id, file_path) do
    with_client(sector_id, &Client.document_symbol(&1, file_path))
  end

  @doc """
  Workspace-wide symbol search by name. See `Client.workspace_symbol/2`.
  """
  @spec workspace_symbol(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def workspace_symbol(sector_id, query) do
    with_client(sector_id, &Client.workspace_symbol(&1, query))
  end

  @doc """
  Returns available code actions for `range` in `file_path`.
  """
  @spec code_action(String.t(), String.t(), map(), map()) ::
          {:ok, [map()]} | {:error, term()}
  def code_action(sector_id, file_path, range, context \\ %{}) do
    with_client(sector_id, &Client.code_action(&1, file_path, range, context))
  end

  @doc """
  Cached diagnostics for `file_path`. Auto-calls `did_open/2` on the
  client (idempotent — the client tracks open URIs and drops repeat
  casts) so the server starts pushing diagnostics if it hasn't
  already. Caller may need to poll (see `Client.diagnostics/2`).
  """
  @spec diagnostics(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def diagnostics(sector_id, file_path) do
    with_client(sector_id, fn pid ->
      :ok = Client.did_open(pid, file_path)
      Client.diagnostics(pid, file_path)
    end)
  end

  @doc """
  Applies a `WorkspaceEdit` (returned by a `CodeAction.edit`) to the
  workspace's files. Side-effect: writes files on disk. Caller is
  responsible for committing.
  """
  @spec apply_workspace_edit(map()) :: {:ok, [String.t()]} | {:error, term()}
  def apply_workspace_edit(edit), do: GiTF.LSP.Edits.apply_workspace_edit(edit)

  @doc """
  Best-effort: returns `{file_path, [diagnostic]}` pairs for each path
  in `relative_paths`, resolved against the sector's repo root. Paths
  with no diagnostics (or where the LSP isn't available) yield `[]`.

  Non-blocking — uses whatever the diagnostic cache holds at call
  time. The first call for a file triggers an async `did_open`, so
  subsequent calls (e.g. on the next advance tick) will see real
  results once the server has analyzed.

  Returns `{:error, reason}` only when the LSP itself is
  disabled/unavailable/sector-unknown — never when individual files
  have no analysis yet.
  """
  @spec collect_diagnostics(String.t(), [String.t()]) ::
          {:ok, [{String.t(), [map()]}]} | {:error, term()}
  def collect_diagnostics(sector_id, relative_paths) when is_list(relative_paths) do
    with {:ok, %{path: repo_path}} <- fetch_sector(sector_id) do
      pairs =
        relative_paths
        |> Enum.map(fn rel ->
          abs_path = Path.expand(rel, repo_path)

          case diagnostics(sector_id, abs_path) do
            {:ok, diags} -> {rel, diags}
            {:error, _} -> {rel, []}
          end
        end)

      {:ok, pairs}
    end
  end

  @doc """
  Returns only the *error*-severity diagnostics (LSP severity 1) from
  `collect_diagnostics/2`. Warnings/info/hints are filtered out —
  validators care about hard errors, not style nudges.
  """
  @spec collect_errors(String.t(), [String.t()]) ::
          {:ok, [{String.t(), [map()]}]} | {:error, term()}
  def collect_errors(sector_id, relative_paths) do
    with {:ok, pairs} <- collect_diagnostics(sector_id, relative_paths) do
      errors =
        pairs
        |> Enum.map(fn {file, diags} ->
          {file, Enum.filter(diags, &(Map.get(&1, "severity") == 1))}
        end)
        |> Enum.reject(fn {_, diags} -> diags == [] end)

      {:ok, errors}
    end
  end

  defp fetch_sector(sector_id) do
    case GiTF.Archive.get(:sectors, sector_id) do
      %{path: path} = sector when is_binary(path) -> {:ok, sector}
      _ -> {:error, :sector_not_found}
    end
  end

  @doc """
  Looks up the live `GiTF.LSP.Client` PID for `sector_id`, starting
  one if none exists. Returns `{:ok, pid}` or a clear error.
  """
  @spec lookup_or_start(String.t()) ::
          {:ok, pid()}
          | {:error, :disabled | :driver_unavailable | :sector_not_found | term()}
  def lookup_or_start(sector_id) when is_binary(sector_id) do
    cond do
      not Client.enabled?() -> {:error, :disabled}
      not Client.available?() -> {:error, :driver_unavailable}
      true -> ensure_client(sector_id)
    end
  end

  # -- Internal --------------------------------------------------------------

  defp with_client(sector_id, fun) do
    case lookup_or_start(sector_id) do
      {:ok, pid} -> fun.(pid)
      {:error, _} = err -> err
    end
  end

  # Steady-state fast path: when the client is already registered, skip
  # the Archive lookup of the sector record entirely. The path resolve
  # only runs on first start.
  defp ensure_client(sector_id) do
    case Registry.lookup(GiTF.Registry, {:lsp_client, sector_id}) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      [] -> resolve_and_start(sector_id)
    end
  end

  defp resolve_and_start(sector_id) do
    case GiTF.Archive.get(:sectors, sector_id) do
      %{path: path} when is_binary(path) ->
        case Supervisor.start_client(sector_id, path) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = err -> err
        end

      _ ->
        {:error, :sector_not_found}
    end
  end
end
