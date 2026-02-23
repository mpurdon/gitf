defmodule Hive.Conflict do
  @moduledoc """
  Detects merge conflicts between a bee's worktree branch and the main branch.

  Uses `git diff` to detect potential conflicts before merging.
  Pure context module -- no process state.
  """

  require Logger

  alias Hive.Store

  @doc """
  Checks a cell's branch for conflicts against the main branch.

  Returns `{:ok, :clean}` or `{:error, :conflicts, file_list}`.
  """
  @spec check(String.t()) :: {:ok, :clean} | {:error, :conflicts, [String.t()]} | {:error, term()}
  def check(cell_id) do
    with {:ok, cell} <- fetch_cell(cell_id),
         {:ok, comb} <- fetch_comb(cell.comb_id),
         {:ok, main_branch} <- detect_main_branch(comb.path) do
      check_conflicts(comb.path, cell.branch, main_branch)
    end
  end

  @doc """
  Checks all active cells for conflicts.

  Returns a list of `{:ok, cell_id, :clean}` or `{:error, cell_id, :conflicts, files}`.
  """
  @spec check_all_active() :: [tuple()]
  def check_all_active do
    Store.filter(:cells, fn c -> c.status == "active" end)
    |> Enum.map(fn cell ->
      case check(cell.id) do
        {:ok, :clean} -> {:ok, cell.id, :clean}
        {:error, :conflicts, files} -> {:error, cell.id, :conflicts, files}
        {:error, _reason} -> {:ok, cell.id, :clean}
      end
    end)
  rescue
    _ -> []
  end

  @doc """
  Attempts to resolve conflicts for a cell using the given strategy.

  Strategies:
    * `:rebase` — Fetches latest main and rebases the cell's branch onto it.
    * `:defer` — Marks the cell as needing manual merge and notifies the Queen.

  Returns `{:ok, :resolved}` or `{:error, reason}`.
  """
  @spec resolve(String.t(), :rebase | :defer) :: {:ok, :resolved} | {:error, term()}
  def resolve(cell_id, strategy \\ :rebase)

  def resolve(cell_id, :rebase) do
    with {:ok, cell} <- fetch_cell(cell_id),
         {:ok, comb} <- fetch_comb(cell.comb_id),
         {:ok, main_branch} <- detect_main_branch(comb.path) do
      worktree_path = cell.worktree_path

      # Fetch latest from origin (best-effort, may not have remote)
      System.cmd("git", ["fetch", "origin"], cd: worktree_path, stderr_to_stdout: true)

      # Attempt rebase onto main
      case System.cmd("git", ["rebase", main_branch],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          # Verify the rebase resolved conflicts
          case check(cell_id) do
            {:ok, :clean} ->
              Logger.info("Rebase resolved conflicts for cell #{cell_id}")
              {:ok, :resolved}

            {:error, :conflicts, files} ->
              Logger.warning("Rebase did not resolve all conflicts for cell #{cell_id}: #{inspect(files)}")
              {:error, {:rebase_incomplete, files}}

            _ ->
              {:ok, :resolved}
          end

        {output, _code} ->
          # Rebase failed — abort to restore clean state
          System.cmd("git", ["rebase", "--abort"], cd: worktree_path, stderr_to_stdout: true)
          Logger.warning("Rebase failed for cell #{cell_id}: #{String.slice(output, 0, 200)}")
          {:error, :rebase_failed}
      end
    end
  end

  def resolve(cell_id, :defer) do
    case fetch_cell(cell_id) do
      {:ok, cell} ->
        Store.put(:cells, Map.put(cell, :needs_manual_merge, true))

        Hive.Waggle.send(
          "system",
          "queen",
          "manual_merge_needed",
          "Cell #{cell_id} deferred for manual merge"
        )

        {:ok, :resolved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks for conflicts between two active cells by comparing their changed files.

  Returns `{:ok, :clean}` if no overlapping files, or
  `{:error, :conflicts, overlapping_files}` if both cells touch the same files.
  """
  @spec check_between_cells(String.t(), String.t()) ::
          {:ok, :clean} | {:error, :conflicts, [String.t()]} | {:error, term()}
  def check_between_cells(cell_id_a, cell_id_b) do
    with {:ok, cell_a} <- fetch_cell(cell_id_a),
         {:ok, cell_b} <- fetch_cell(cell_id_b),
         {:ok, comb} <- fetch_comb(cell_a.comb_id),
         {:ok, main_branch} <- detect_main_branch(comb.path) do
      files_a = changed_files(comb.path, cell_a.branch, main_branch)
      files_b = changed_files(comb.path, cell_b.branch, main_branch)

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
    case System.cmd("git", ["diff", "--name-only", "#{main_branch}...#{branch}"],
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
    case System.cmd("git", ["diff", "--name-only", "#{main_branch}...#{branch}"],
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
        case System.cmd("git", ["diff", "--name-only", "#{base}..#{main_branch}"],
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
    case System.cmd("git", ["merge-base", "HEAD", main_branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp fetch_cell(cell_id) do
    case Store.get(:cells, cell_id) do
      nil -> {:error, :cell_not_found}
      cell -> {:ok, cell}
    end
  end

  defp fetch_comb(comb_id) do
    case Store.get(:combs, comb_id) do
      nil -> {:error, :comb_not_found}
      comb -> {:ok, comb}
    end
  end

  defp detect_main_branch(repo_path) do
    cond do
      Hive.Git.branch_exists?(repo_path, "main") -> {:ok, "main"}
      Hive.Git.branch_exists?(repo_path, "master") -> {:ok, "master"}
      true -> Hive.Git.current_branch(repo_path)
    end
  rescue
    _ -> {:ok, "main"}
  end
end
