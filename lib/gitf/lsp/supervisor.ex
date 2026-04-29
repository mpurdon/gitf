defmodule GiTF.LSP.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-sector `GiTF.LSP.Client` instances.

  Each sector gets at most one LSP client, registered under
  `GiTF.Registry` with key `{:lsp_client, sector_id}`. Lazy-started on
  first lookup via `GiTF.LSP.lookup_or_start/1`.

  When `:lsp_enabled` is false the supervisor still boots (so the
  facade's lookup path returns a clear `{:error, :disabled}` instead of
  needing a supervisor-presence check), but no children are ever
  started.
  """

  use DynamicSupervisor

  @name __MODULE__

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a `GiTF.LSP.Client` for `sector_id` rooted at `root_path`.
  Returns `{:ok, pid}` on success, `{:error, {:already_started, pid}}`
  when one already exists, or `{:error, reason}` on failure.
  """
  @spec start_client(String.t(), String.t()) :: DynamicSupervisor.on_start_child()
  def start_client(sector_id, root_path) when is_binary(sector_id) and is_binary(root_path) do
    spec = %{
      id: {GiTF.LSP.Client, sector_id},
      start:
        {GiTF.LSP.Client, :start_link,
         [[root_path: root_path, name: via_name(sector_id)]]},
      restart: :transient
    }

    DynamicSupervisor.start_child(@name, spec)
  end

  defp via_name(sector_id), do: {:via, Registry, {GiTF.Registry, {:lsp_client, sector_id}}}
end
