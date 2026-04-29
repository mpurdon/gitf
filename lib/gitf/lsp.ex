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
  @spec definition(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: position_result()
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
