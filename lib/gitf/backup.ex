defmodule GiTF.Backup do
  @moduledoc """
  Structured backuping for ghost state persistence.

  Provides richer state snapshots than link_msg-based transfers by capturing
  progress summaries, files modified, pending work, tool call counts, and
  context usage. Each save appends a new record (append-only history),
  enabling both point-in-time recovery and progress trend analysis.

  This is a pure context module -- no GenServer, no state. Every function
  is a data transformation against the Archive.
  """

  alias GiTF.Archive

  @collection :backups

  @backup_keys ~w(
    progress_summary files_modified pending_work tool_calls
    iteration context_usage_pct phase error_count
  )a

  # -- Public API ------------------------------------------------------------

  @doc """
  Saves a backup for a ghost.

  Creates a new append-only record with the given data. Accepts a map with
  optional keys: `:progress_summary`, `:files_modified`, `:pending_work`,
  `:tool_calls`, `:iteration`, `:context_usage_pct`, `:phase`, `:error_count`.

  Returns `{:ok, backup}`.
  """
  @spec save(String.t(), map()) :: {:ok, map()}
  def save(ghost_id, data) when is_binary(ghost_id) and is_map(data) do
    data
    |> Map.take(@backup_keys)
    |> Map.put(:ghost_id, ghost_id)
    |> Map.put(:saved_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> then(&Archive.insert(@collection, &1))
  end

  @doc """
  Loads the most recent backup for a ghost.

  Returns `{:ok, backup}` or `{:error, :not_found}`.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, :not_found}
  def load(ghost_id) when is_binary(ghost_id) do
    case latest_checkpoint(ghost_id) do
      nil -> {:error, :not_found}
      backup -> {:ok, backup}
    end
  end

  @doc """
  Returns all backups for a ghost, sorted by timestamp ascending.
  """
  @spec history(String.t()) :: [map()]
  def history(ghost_id) when is_binary(ghost_id) do
    Archive.filter(@collection, &(&1.ghost_id == ghost_id))
    |> Enum.sort_by(& &1.saved_at, {:asc, DateTime})
  end

  @doc """
  Builds a markdown prompt for injecting into a replacement ghost's context.

  Takes a backup map and produces a structured resume briefing that
  gives the new ghost enough context to continue where the previous one
  left off.
  """
  @spec build_resume_prompt(map()) :: String.t()
  def build_resume_prompt(backup) when is_map(backup) do
    sections =
      [
        "## Resuming Previous Work",
        "",
        format_field("Progress so far", backup[:progress_summary]),
        format_files(backup[:files_modified]),
        format_field("Remaining work", backup[:pending_work]),
        format_field("Previous phase", backup[:phase]),
        format_field("Iterations completed", backup[:iteration]),
        format_field("Errors encountered", backup[:error_count]),
        format_context_usage(backup[:context_usage_pct])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n")
  end

  @doc """
  Keeps only the N most recent backups for a ghost, deleting the rest.

  Returns the count of deleted backups.
  """
  @spec cleanup(String.t(), keyword()) :: non_neg_integer()
  def cleanup(ghost_id, opts) when is_binary(ghost_id) do
    keep = Keyword.fetch!(opts, :keep)

    backups =
      Archive.filter(@collection, &(&1.ghost_id == ghost_id))
      |> Enum.sort_by(& &1.saved_at, {:desc, DateTime})

    to_delete = Enum.drop(backups, keep)

    Enum.each(to_delete, &Archive.delete(@collection, &1.id))
    length(to_delete)
  end

  # -- Private ---------------------------------------------------------------

  defp latest_checkpoint(ghost_id) do
    Archive.filter(@collection, &(&1.ghost_id == ghost_id))
    |> Enum.sort_by(& &1.saved_at, {:desc, DateTime})
    |> List.first()
  end

  defp format_field(_label, nil), do: nil
  defp format_field(label, value), do: "**#{label}:** #{value}"

  defp format_files(nil), do: nil
  defp format_files([]), do: nil

  defp format_files(files) when is_list(files) do
    file_list = Enum.map_join(files, "\n", &"  - `#{&1}`")
    "**Files modified:**\n#{file_list}"
  end

  defp format_context_usage(nil), do: nil

  defp format_context_usage(pct) when is_float(pct) do
    "**Context window used:** #{Float.round(pct * 100, 1)}%"
  end
end
