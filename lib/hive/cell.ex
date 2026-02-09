defmodule Hive.Cell do
  @moduledoc """
  Context module for managing cells -- git worktrees assigned to bees.

  A cell provides an isolated working directory for a bee by creating a git
  worktree from a comb's repository.
  """

  alias Hive.Git
  alias Hive.Store

  # -- Public API ------------------------------------------------------------

  @doc """
  Creates a new cell (git worktree) for a bee within a comb.

  Returns `{:ok, cell}` or `{:error, reason}`.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(comb_id, bee_id, opts \\ []) do
    branch = Keyword.get(opts, :branch, "bee/#{bee_id}")
    hive_root = Keyword.get(opts, :hive_root)

    with {:ok, comb} <- Hive.Comb.get(comb_id),
         :ok <- validate_comb_path(comb),
         worktree_path = build_worktree_path(comb.path, bee_id),
         {:ok, _path} <- Git.worktree_add(comb.path, worktree_path, branch),
         :ok <- maybe_generate_settings(bee_id, hive_root, worktree_path),
         {:ok, cell} <- insert_cell(comb_id, bee_id, worktree_path, branch) do
      {:ok, cell}
    end
  end

  @doc """
  Removes a cell's worktree and marks the record as removed.

  Returns `{:ok, cell}` or `{:error, reason}`.
  """
  @spec remove(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove(cell_id, opts \\ []) do
    with {:ok, cell} <- get(cell_id),
         {:ok, comb} <- Hive.Comb.get(cell.comb_id),
         :ok <- remove_worktree(comb.path, cell.worktree_path, opts),
         :ok <- delete_branch(comb.path, cell.branch),
         {:ok, updated} <- mark_removed(cell) do
      {:ok, updated}
    end
  end

  @doc """
  Lists cells with optional filters.

  ## Options

    * `:comb_id` - filter by comb
    * `:status` - filter by status (e.g., "active", "removed")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    cells = Store.all(:cells)

    cells =
      case Keyword.get(opts, :comb_id) do
        nil -> cells
        v -> Enum.filter(cells, &(&1.comb_id == v))
      end

    cells =
      case Keyword.get(opts, :status) do
        nil -> cells
        v -> Enum.filter(cells, &(&1.status == v))
      end

    Enum.sort_by(cells, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Gets a cell by ID.

  Returns `{:ok, cell}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(cell_id) do
    Store.fetch(:cells, cell_id)
  end

  @doc """
  Reassigns a cell to a new bee without touching the worktree or branch on disk.

  Returns `{:ok, cell}` or `{:error, :not_found}`.
  """
  @spec adopt(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def adopt(cell_id, new_bee_id) do
    with {:ok, cell} <- get(cell_id) do
      updated = %{cell | bee_id: new_bee_id}
      Store.put(:cells, updated)
    end
  end

  @doc """
  Finds cells whose associated bee no longer exists or has stopped.

  Returns orphaned cells that are still marked "active" but have no
  corresponding active bee record.
  """
  @spec cleanup_orphans() :: {:ok, non_neg_integer()}
  def cleanup_orphans do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    active_cells = Store.filter(:cells, fn c -> c.status == "active" end)

    orphan_count =
      Enum.count(active_cells, fn cell ->
        case Store.get(:bees, cell.bee_id) do
          nil ->
            Store.put(:cells, Map.merge(cell, %{status: "removed", removed_at: now}))
            true

          bee ->
            if bee.status in ["stopped", "crashed"] do
              Store.put(:cells, Map.merge(cell, %{status: "removed", removed_at: now}))
              true
            else
              false
            end
        end
      end)

    {:ok, orphan_count}
  end

  # -- Private helpers -------------------------------------------------------

  defp validate_comb_path(%{path: nil}), do: {:error, :comb_has_no_path}
  defp validate_comb_path(%{path: path}) when is_binary(path), do: :ok
  defp validate_comb_path(_comb), do: {:error, :comb_has_no_path}

  defp build_worktree_path(comb_path, bee_id) do
    Path.join([comb_path, "bees", bee_id])
  end

  defp insert_cell(comb_id, bee_id, worktree_path, branch) do
    record = %{
      comb_id: comb_id,
      bee_id: bee_id,
      worktree_path: worktree_path,
      branch: branch,
      status: "active",
      removed_at: nil
    }

    Store.insert(:cells, record)
  end

  defp remove_worktree(comb_path, worktree_path, opts) do
    case Git.worktree_remove(comb_path, worktree_path, opts) do
      :ok -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp delete_branch(comb_path, branch) do
    case Git.branch_delete(comb_path, branch) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp mark_removed(cell) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    updated = %{cell | status: "removed", removed_at: now}
    Store.put(:cells, updated)
  end

  defp maybe_generate_settings(_bee_id, nil, _worktree_path), do: :ok

  defp maybe_generate_settings(bee_id, hive_root, worktree_path) do
    Hive.Runtime.Settings.generate(bee_id, hive_root, worktree_path)
  end
end
