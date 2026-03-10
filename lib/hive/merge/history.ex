defmodule Hive.Merge.History do
  @moduledoc """
  Tracks merge attempt outcomes to inform future merge strategy decisions.

  Records are stored in the `:merge_history` Store collection. Each record
  captures which tier was attempted, whether it succeeded, and which files
  were involved. This data drives the tier-skipping heuristic: if a tier
  has failed 2+ times for a set of files with 0 successes, skip it.
  """

  alias Hive.Store

  # -- Public API --------------------------------------------------------------

  @doc """
  Records a merge attempt outcome.

  ## Attrs

    * `:job_id` — the job being merged
    * `:cell_id` — the cell/worktree
    * `:tier` — which resolution tier was attempted (0-3)
    * `:status` — `:success` or `:failure`
    * `:files` — list of file paths involved
    * `:error` — error description (nil on success)
  """
  @spec record(map()) :: {:ok, map()}
  def record(attrs) do
    record = Map.merge(attrs, %{merged_at: DateTime.utc_now()})
    Store.insert(:merge_history, record)
  end

  @doc """
  Returns true if a tier should be skipped for the given file paths.

  A tier is skipped when it has failed 2+ times for any of the given files
  with 0 successes across all recorded history for those files.
  """
  @spec should_skip_tier?(non_neg_integer(), [String.t()]) :: boolean()
  def should_skip_tier?(tier, file_paths) when is_list(file_paths) do
    file_set = MapSet.new(file_paths)

    relevant =
      Store.filter(:merge_history, fn h ->
        h.tier == tier and files_overlap?(h.files, file_set)
      end)

    failures = Enum.count(relevant, &(&1.status == :failure))
    successes = Enum.count(relevant, &(&1.status == :success))

    failures >= 2 and successes == 0
  rescue
    _ -> false
  end

  @doc """
  Returns merge history records whose files overlap with the given paths.
  Sorted by merged_at descending.
  """
  @spec get_history([String.t()]) :: [map()]
  def get_history(file_paths) do
    file_set = MapSet.new(file_paths)

    Store.filter(:merge_history, fn h ->
      files_overlap?(h.files, file_set)
    end)
    |> Enum.sort_by(& &1.merged_at, {:desc, DateTime})
  rescue
    _ -> []
  end

  @doc """
  Returns file paths sorted by failure count (most conflict-prone first).
  """
  @spec conflict_prone_files() :: [{String.t(), non_neg_integer()}]
  def conflict_prone_files do
    Store.all(:merge_history)
    |> Enum.filter(&(&1.status == :failure))
    |> Enum.flat_map(fn h -> h.files || [] end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_file, count} -> count end, :desc)
  rescue
    _ -> []
  end

  # -- Private -----------------------------------------------------------------

  defp files_overlap?(nil, _set), do: false
  defp files_overlap?(files, set) when is_list(files) do
    Enum.any?(files, &MapSet.member?(set, &1))
  end
  defp files_overlap?(_, _), do: false
end
