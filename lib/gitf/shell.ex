defmodule GiTF.Shell do
  @moduledoc """
  Context module for managing shells -- git worktrees assigned to ghosts.

  A shell provides an isolated working directory for a ghost by creating a git
  worktree from a sector's repository.
  """

  alias GiTF.Git
  alias GiTF.Archive
  require GiTF.Ghost.Status, as: GhostStatus

  # -- Public API ------------------------------------------------------------

  @doc """
  Creates a new shell (git worktree) for a ghost within a sector.

  Returns `{:ok, shell}` or `{:error, reason}`.
  """
  @spec create(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(sector_id, ghost_id, opts \\ []) do
    branch = Keyword.get(opts, :branch, "ghost/#{ghost_id}")
    gitf_root = Keyword.get(opts, :gitf_root)

    with {:ok, sector} <- GiTF.Sector.get(sector_id),
         :ok <- validate_sector_path(sector),
         worktree_path = build_worktree_path(sector.path, ghost_id),
         {:ok, _path} <- Git.worktree_add(sector.path, worktree_path, branch),
         :ok <- maybe_generate_settings(ghost_id, gitf_root, worktree_path),
         base_commit_sha = capture_base_sha(worktree_path),
         base_ref = detect_base_ref(sector.path),
         {:ok, shell} <-
           insert_cell(sector_id, ghost_id, worktree_path, branch, base_commit_sha, base_ref) do
      GiTF.Telemetry.emit([:gitf, :drift, :base_captured], %{}, %{
        shell_id: shell.id,
        sector_id: sector_id,
        ghost_id: ghost_id,
        base_commit_sha: base_commit_sha,
        base_ref: base_ref
      })

      {:ok, shell}
    else
      {:error, reason} = error ->
        # Clean up any orphaned worktree directory left by a partial git worktree add.
        # Without this, the next provision attempt for this ghost would fail with
        # "already exists as a worktree".
        case sector_path(sector_id) do
          nil -> :ok
          sp -> cleanup_orphaned_worktree(sector_id, build_worktree_path(sp, ghost_id))
        end

        require Logger
        Logger.warning("Shell.create failed for ghost #{ghost_id}: #{inspect(reason)}")
        error
    end
  end

  # Captures the base SHA from the worktree itself (race-free — the worktree
  # is pinned to its own HEAD regardless of what the parent repo is doing).
  defp capture_base_sha(worktree_path) do
    case Git.head_sha(worktree_path) do
      {:ok, sha} ->
        sha

      {:error, reason} ->
        require Logger
        Logger.warning("Shell.create: failed to capture base SHA for #{worktree_path}: #{reason}")
        nil
    end
  end

  # Detects the appropriate base ref in priority order: origin/main, main, master.
  defp detect_base_ref(sector_path) do
    cond do
      match?({:ok, _}, Git.rev_parse(sector_path, "origin/main")) -> "origin/main"
      Git.branch_exists?(sector_path, "main") -> "main"
      Git.branch_exists?(sector_path, "master") -> "master"
      true -> "main"
    end
  end

  @doc """
  Removes a shell's worktree and marks the record as removed.

  Returns `{:ok, shell}` or `{:error, reason}`.
  """
  @spec remove(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove(shell_id, opts \\ []) do
    with {:ok, shell} <- get(shell_id),
         {:ok, sector} <- GiTF.Sector.get(shell.sector_id),
         :ok <- remove_worktree(sector.path, shell.worktree_path, opts),
         :ok <- delete_branch(sector.path, shell.branch),
         {:ok, updated} <- mark_removed(shell) do
      {:ok, updated}
    end
  end

  @doc """
  Lists shells with optional filters.

  ## Options

    * `:sector_id` - filter by sector
    * `:status` - filter by status (e.g., "active", "removed")
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    shells = Archive.all(:shells)

    shells =
      case Keyword.get(opts, :sector_id) do
        nil -> shells
        v -> Enum.filter(shells, &(&1.sector_id == v))
      end

    shells =
      case Keyword.get(opts, :status) do
        nil -> shells
        v -> Enum.filter(shells, &(&1.status == v))
      end

    Enum.sort_by(shells, & &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Gets a shell by ID.

  Returns `{:ok, shell}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(shell_id) do
    Archive.fetch(:shells, shell_id)
  end

  @doc """
  Reassigns a shell to a new ghost without touching the worktree or branch on disk.

  Returns `{:ok, shell}` or `{:error, :not_found}`.
  """
  @spec adopt(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def adopt(shell_id, new_ghost_id) do
    with {:ok, shell} <- get(shell_id) do
      updated = %{shell | ghost_id: new_ghost_id}
      Archive.put(:shells, updated)
    end
  end

  @doc """
  Finds shells whose associated ghost no longer exists or has stopped.

  Returns orphaned shells that are still marked "active" but have no
  corresponding active ghost record.
  """
  @spec cleanup_orphans() :: {:ok, non_neg_integer()}
  def cleanup_orphans do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    active_cells = Archive.filter(:shells, fn c -> c.status == "active" end)

    orphan_count =
      Enum.count(active_cells, fn shell ->
        orphan? =
          case Archive.get(:ghosts, shell.ghost_id) do
            nil -> true
            ghost -> GhostStatus.terminal?(ghost.status)
          end

        if orphan? do
          Archive.put(:shells, Map.merge(shell, %{status: "removed", removed_at: now}))

          # Best-effort: remove worktree and branch from disk
          try do
            case GiTF.Sector.get(shell.sector_id) do
              {:ok, sector} when not is_nil(sector.path) ->
                Git.worktree_remove(sector.path, shell.worktree_path, force: true)
                Git.branch_delete(sector.path, shell.branch)

              _ ->
                :ok
            end
          rescue
            _ -> :ok
          end

          true
        else
          false
        end
      end)

    {:ok, orphan_count}
  end

  # -- Private helpers -------------------------------------------------------

  defp validate_sector_path(%{path: nil}), do: {:error, :sector_has_no_path}
  defp validate_sector_path(%{path: path}) when is_binary(path), do: :ok
  defp validate_sector_path(_sector), do: {:error, :sector_has_no_path}

  defp build_worktree_path(sector_path, ghost_id) do
    Path.join([sector_path, "ghosts", ghost_id])
  end

  defp insert_cell(sector_id, ghost_id, worktree_path, branch, base_commit_sha, base_ref) do
    record = %{
      sector_id: sector_id,
      ghost_id: ghost_id,
      worktree_path: worktree_path,
      branch: branch,
      status: "active",
      removed_at: nil,
      base_commit_sha: base_commit_sha,
      base_ref: base_ref,
      drift_state: :unknown,
      drift_checked_at: nil,
      drift_meta: nil
    }

    Archive.insert(:shells, record)
  end

  defp remove_worktree(sector_path, worktree_path, opts) do
    case Git.worktree_remove(sector_path, worktree_path, opts) do
      :ok -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp delete_branch(sector_path, branch) do
    case Git.branch_delete(sector_path, branch) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp mark_removed(shell) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    updated = %{shell | status: "removed", removed_at: now}
    Archive.put(:shells, updated)
  end

  defp maybe_generate_settings(_ghost_id, nil, _worktree_path), do: :ok

  defp maybe_generate_settings(ghost_id, gitf_root, worktree_path) do
    GiTF.Runtime.Settings.generate(ghost_id, gitf_root, worktree_path)
  end

  defp sector_path(sector_id) do
    case GiTF.Sector.get(sector_id) do
      {:ok, sector} -> sector.path
      _ -> nil
    end
  end

  defp cleanup_orphaned_worktree(_sector_id, nil), do: :ok

  defp cleanup_orphaned_worktree(sector_id, worktree_path) do
    if File.dir?(worktree_path) do
      # Remove from git's worktree tracking first, then delete the directory
      case sector_path(sector_id) do
        nil ->
          :ok

        repo_path ->
          Git.safe_cmd(["worktree", "remove", "--force", worktree_path],
            cd: repo_path,
            stderr_to_stdout: true
          )
      end

      # If git worktree remove didn't clean it, force-delete the directory
      if File.dir?(worktree_path), do: File.rm_rf(worktree_path)
    end
  rescue
    _ -> :ok
  end
end
