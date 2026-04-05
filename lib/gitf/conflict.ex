defmodule GiTF.Conflict do
  @moduledoc """
  Detects merge conflicts between a ghost's worktree branch and the main branch.

  Uses `git diff` to detect potential conflicts before merging.
  Pure context module -- no process state.
  """

  require Logger

  alias GiTF.Archive

  @doc """
  Checks a shell's branch for conflicts against the main branch.

  Returns `{:ok, :clean}` or `{:error, :conflicts, file_list}`.
  """
  @spec check(String.t()) :: {:ok, :clean} | {:error, :conflicts, [String.t()]} | {:error, term()}
  def check(shell_id) do
    with {:ok, shell} <- fetch_cell(shell_id),
         {:ok, sector} <- fetch_sector(shell.sector_id),
         {:ok, main_branch} <- detect_main_branch(sector.path) do
      check_conflicts(sector.path, shell.branch, main_branch)
    end
  end

  @doc """
  Checks all active shells for conflicts.

  Returns a list of `{:ok, shell_id, :clean}` or `{:error, shell_id, :conflicts, files}`.
  """
  @spec check_all_active() :: [tuple()]
  def check_all_active do
    Archive.filter(:shells, fn c -> c.status == "active" end)
    |> Enum.map(fn shell ->
      case check(shell.id) do
        {:ok, :clean} -> {:ok, shell.id, :clean}
        {:error, :conflicts, files} -> {:error, shell.id, :conflicts, files}
        {:error, _reason} -> {:ok, shell.id, :clean}
      end
    end)
  rescue
    _ -> []
  end

  @doc """
  Attempts to resolve conflicts for a shell using the given strategy.

  Strategies:
    * `:rebase` — Fetches latest main and rebases the shell's branch onto it.
    * `:defer` — Marks the shell as needing manual sync and notifies the Major.

  Returns `{:ok, :resolved}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), :rebase | :defer) :: {:ok, :resolved} | {:error, term()}
  def resolve(shell_id, strategy \\ :rebase)

  def resolve(shell_id, :rebase) do
    with {:ok, shell} <- fetch_cell(shell_id),
         {:ok, sector} <- fetch_sector(shell.sector_id),
         {:ok, main_branch} <- detect_main_branch(sector.path) do
      worktree_path = shell.worktree_path

      # Fetch latest from origin (best-effort, may not have remote)
      GiTF.Git.safe_cmd(["fetch", "origin"], cd: worktree_path, stderr_to_stdout: true)

      # Attempt rebase onto main
      case GiTF.Git.safe_cmd(["rebase", main_branch],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          # Verify the rebase resolved conflicts
          case check(shell_id) do
            {:ok, :clean} ->
              Logger.info("Rebase resolved conflicts for shell #{shell_id}")
              {:ok, :resolved}

            {:error, :conflicts, files} ->
              Logger.warning(
                "Rebase did not resolve all conflicts for shell #{shell_id}: #{inspect(files)}"
              )

              {:error, {:rebase_incomplete, files}}

            _ ->
              {:ok, :resolved}
          end

        {output, _code} ->
          # Rebase failed — abort to restore clean state
          GiTF.Git.safe_cmd(["rebase", "--abort"], cd: worktree_path, stderr_to_stdout: true)
          Logger.warning("Rebase failed for shell #{shell_id}: #{String.slice(output, 0, 200)}")
          {:error, :rebase_failed}
      end
    end
  end

  def resolve(shell_id, :defer) do
    case fetch_cell(shell_id) do
      {:ok, shell} ->
        Archive.put(:shells, Map.put(shell, :needs_manual_merge, true))

        GiTF.Link.send(
          "system",
          "major",
          "manual_merge_needed",
          "Cell #{shell_id} deferred for manual sync"
        )

        {:ok, :resolved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks for conflicts between two active shells by comparing their changed files.

  Returns `{:ok, :clean}` if no overlapping files, or
  `{:error, :conflicts, overlapping_files}` if both shells touch the same files.
  """
  @spec check_between_cells(String.t(), String.t()) ::
          {:ok, :clean} | {:error, :conflicts, [String.t()]} | {:error, term()}
  def check_between_cells(cell_id_a, cell_id_b) do
    with {:ok, cell_a} <- fetch_cell(cell_id_a),
         {:ok, cell_b} <- fetch_cell(cell_id_b),
         {:ok, sector} <- fetch_sector(cell_a.sector_id),
         {:ok, main_branch} <- detect_main_branch(sector.path) do
      files_a = changed_files(sector.path, cell_a.branch, main_branch)
      files_b = changed_files(sector.path, cell_b.branch, main_branch)

      overlap = MapSet.intersection(MapSet.new(files_a), MapSet.new(files_b)) |> MapSet.to_list()

      if overlap == [] do
        {:ok, :clean}
      else
        {:error, :conflicts, overlap}
      end
    end
  end

  # -- Private -----------------------------------------------------------------

  defp changed_files(repo_path, branch, main_branch) do
    case GiTF.Git.safe_cmd(["diff", "--name-only", "#{main_branch}...#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp check_conflicts(repo_path, branch, main_branch) do
    # Use git diff to find files that differ and may conflict
    case GiTF.Git.safe_cmd(["diff", "--name-only", "#{main_branch}...#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        changed_files = output |> String.split("\n", trim: true)

        if changed_files == [] do
          {:ok, :clean}
        else
          # Check if main has also modified these files (potential conflict)
          check_overlapping_changes(repo_path, branch, main_branch, changed_files)
        end

      {_output, _code} ->
        # Can't determine, assume clean
        {:ok, :clean}
    end
  rescue
    _ -> {:ok, :clean}
  end

  defp check_overlapping_changes(repo_path, _branch, main_branch, branch_files) do
    # Find files changed on main since the branch point
    merge_base = get_merge_base(repo_path, main_branch)

    case merge_base do
      {:ok, base} ->
        case GiTF.Git.safe_cmd(["diff", "--name-only", "#{base}..#{main_branch}"],
               cd: repo_path,
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            main_files = output |> String.split("\n", trim: true) |> MapSet.new()
            branch_set = MapSet.new(branch_files)
            conflicts = MapSet.intersection(main_files, branch_set) |> MapSet.to_list()

            if conflicts == [] do
              {:ok, :clean}
            else
              {:error, :conflicts, conflicts}
            end

          _ ->
            {:ok, :clean}
        end

      {:error, _} ->
        {:ok, :clean}
    end
  end

  defp get_merge_base(repo_path, main_branch) do
    case GiTF.Git.safe_cmd(["sync-base", "HEAD", main_branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp fetch_cell(shell_id) do
    case Archive.get(:shells, shell_id) do
      nil -> {:error, :cell_not_found}
      shell -> {:ok, shell}
    end
  end

  defp fetch_sector(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> {:error, :comb_not_found}
      sector -> {:ok, sector}
    end
  end

  defp detect_main_branch(repo_path) do
    cond do
      GiTF.Git.branch_exists?(repo_path, "main") -> {:ok, "main"}
      GiTF.Git.branch_exists?(repo_path, "master") -> {:ok, "master"}
      true -> GiTF.Git.current_branch(repo_path)
    end
  rescue
    _ -> {:ok, "main"}
  end
end
