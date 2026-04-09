defmodule GiTF.Drift do
  @moduledoc """
  Proactive drift detection for ghost worktrees.

  Detects when a ghost's base commit has diverged from `origin/main` before
  sync time, classifies risk against the op's `target_files`, and emits
  telemetry. Optionally auto-rebases low-risk drift transparently.

  ## Drift Levels

    * `:clean` — ghost's base is still an ancestor of origin/main
    * `:behind` — main advanced but didn't touch ghost's target_files
    * `:risky` — main touched files the ghost is targeting (but hasn't modified yet)
    * `:conflicted` — main touched files the ghost has already modified
    * `:unknown` — can't determine (no base SHA, worktree gone, force-push)

  Detection runs against the worktree itself, not the parent repo — this
  avoids races and makes the check safe to run while other git operations
  are happening in the sector.
  """

  require Logger
  alias GiTF.{Archive, Git}

  @type drift_level :: :clean | :behind | :risky | :conflicted | :unknown

  # -- Public API --------------------------------------------------------------

  @doc """
  Checks drift for a single shell. Does not fetch from remote.

  Returns `{:ok, level, meta}` or `{:error, reason}`. Always persists the
  computed state to the shell record before returning.
  """
  @spec check_shell(String.t()) :: {:ok, drift_level(), map()} | {:error, term()}
  def check_shell(shell_id) do
    with {:ok, shell} <- Archive.fetch(:shells, shell_id) do
      {level, meta} = classify(shell)
      persist(shell, level, meta)
      emit_telemetry(shell, level, meta)
      {:ok, level, meta}
    end
  end

  @doc """
  Checks drift for all active shells in a sector. Fetches `origin` once.
  """
  @spec check_sector(String.t()) :: [{String.t(), drift_level()}]
  def check_sector(sector_id) do
    case fetch_sector(sector_id) do
      :ok -> :ok
      _ -> :ok
    end

    Archive.filter(:shells, &(&1.sector_id == sector_id and &1.status == "active"))
    |> Enum.map(fn shell ->
      case check_shell(shell.id) do
        {:ok, level, _} -> {shell.id, level}
        _ -> {shell.id, :unknown}
      end
    end)
  end

  @doc """
  Checks drift across all active shells, grouping by sector so each sector
  is fetched only once.
  """
  @spec check_all_active() :: [{String.t(), drift_level()}]
  def check_all_active do
    Archive.filter(:shells, &(&1.status == "active"))
    |> Enum.group_by(& &1.sector_id)
    |> Enum.flat_map(fn {sector_id, _shells} -> check_sector(sector_id) end)
  rescue
    e ->
      Logger.warning("Drift.check_all_active failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Fetches updates for a sector, rate-limited to once every 4 minutes.
  Returns `:ok` even if rate-limited or fetch fails.
  """
  @spec fetch_sector(String.t()) :: :ok
  def fetch_sector(sector_id) do
    if should_fetch?(sector_id) do
      case Archive.get(:sectors, sector_id) do
        %{path: path} when is_binary(path) ->
          case Git.fetch(path, "origin") do
            :ok ->
              :persistent_term.put({:drift_last_fetch, sector_id}, System.monotonic_time(:second))
              :ok

            {:error, _reason} ->
              :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Attempts to auto-rebase a shell if it's safe. Returns `{:ok, :rebased}`,
  `{:ok, :skipped, reason}`, or `{:error, reason}`.

  Safety gates (all must pass):
    1. drift_state == :behind
    2. Ghost is not currently working
    3. Worktree has no uncommitted changes
  """
  @spec maybe_auto_rebase(String.t()) ::
          {:ok, :rebased} | {:ok, :skipped, atom()} | {:error, term()}
  def maybe_auto_rebase(shell_id) do
    with {:ok, shell} <- Archive.fetch(:shells, shell_id),
         :ok <- guard_drift_level(shell),
         :ok <- guard_ghost_idle(shell),
         :ok <- guard_worktree_clean(shell),
         :ok <- do_rebase(shell) do
      updated = update_shell_after_rebase(shell)

      GiTF.Telemetry.emit([:gitf, :drift, :auto_rebased], %{}, %{
        shell_id: shell.id,
        new_base_sha: updated[:base_commit_sha]
      })

      {:ok, :rebased}
    else
      {:skip, reason} ->
        GiTF.Telemetry.emit([:gitf, :drift, :auto_rebase_skipped], %{}, %{
          shell_id: shell_id,
          reason: reason
        })

        {:ok, :skipped, reason}

      {:error, reason} = err ->
        GiTF.Telemetry.emit([:gitf, :drift, :auto_rebase_failed], %{}, %{
          shell_id: shell_id,
          reason: inspect(reason)
        })

        err
    end
  end

  # -- Private: Classification -------------------------------------------------

  defp classify(shell) do
    with :ok <- guard_has_base(shell),
         :ok <- guard_worktree_exists(shell),
         {:ok, main_sha} <- resolve_main(shell) do
      if main_sha == shell.base_commit_sha do
        {:clean, %{commits_behind: 0, main_sha: main_sha}}
      else
        classify_drifted(shell, main_sha)
      end
    else
      {:unknown, reason} -> {:unknown, %{reason: reason}}
    end
  end

  defp guard_has_base(%{base_commit_sha: nil}), do: {:unknown, "no_base"}
  defp guard_has_base(_), do: :ok

  defp guard_worktree_exists(%{worktree_path: path}) do
    if File.dir?(path), do: :ok, else: {:unknown, "no_worktree"}
  end

  defp resolve_main(shell) do
    ref = shell.base_ref || "origin/main"

    case Git.rev_parse(shell.worktree_path, ref) do
      {:ok, sha} ->
        {:ok, sha}

      {:error, _} ->
        # Fall back to local main if origin/main doesn't resolve
        case Git.rev_parse(shell.worktree_path, "main") do
          {:ok, sha} -> {:ok, sha}
          {:error, reason} -> {:unknown, "resolve_failed: #{reason}"}
        end
    end
  end

  defp classify_drifted(shell, main_sha) do
    case Git.ancestor?(shell.worktree_path, shell.base_commit_sha, main_sha) do
      false ->
        {:unknown, %{reason: "base_not_ancestor", main_sha: main_sha}}

      true ->
        compute_drift_details(shell, main_sha)
    end
  end

  defp compute_drift_details(shell, main_sha) do
    commits_behind =
      case Git.count_commits(shell.worktree_path, "#{shell.base_commit_sha}..#{main_sha}") do
        {:ok, n} -> n
        _ -> 0
      end

    main_changed =
      case Git.changed_files_between(shell.worktree_path, shell.base_commit_sha, main_sha) do
        {:ok, files} -> files
        _ -> []
      end

    ghost_modified =
      case Git.changed_files_between(shell.worktree_path, shell.base_commit_sha, "HEAD") do
        {:ok, files} -> files
        _ -> []
      end

    target_files = get_op_target_files(shell.ghost_id)

    main_set = MapSet.new(main_changed)
    target_set = MapSet.new(target_files)
    ghost_set = MapSet.new(ghost_modified)

    ghost_modified_overlap = MapSet.intersection(ghost_set, main_set) |> MapSet.to_list()
    overlapping = MapSet.intersection(target_set, main_set) |> MapSet.to_list()

    level =
      cond do
        ghost_modified_overlap != [] -> :conflicted
        overlapping != [] -> :risky
        true -> :behind
      end

    meta = %{
      commits_behind: commits_behind,
      main_sha: main_sha,
      main_changed_files: main_changed,
      overlapping_files: overlapping,
      ghost_modified_overlap: ghost_modified_overlap,
      reason: nil
    }

    {level, meta}
  end

  defp get_op_target_files(ghost_id) do
    case Archive.find_one(:ops, &(&1[:ghost_id] == ghost_id)) do
      %{target_files: files} when is_list(files) -> files
      _ -> []
    end
  rescue
    _ -> []
  end

  # -- Private: Persistence + Telemetry ----------------------------------------

  defp persist(shell, level, meta) do
    updated =
      shell
      |> Map.put(:drift_state, level)
      |> Map.put(:drift_checked_at, DateTime.utc_now())
      |> Map.put(:drift_meta, meta)

    Archive.put(:shells, updated)
  rescue
    _ -> :ok
  end

  defp emit_telemetry(shell, level, meta) do
    GiTF.Telemetry.emit(
      [:gitf, :drift, :detected],
      %{commits_behind: Map.get(meta, :commits_behind, 0)},
      %{
        shell_id: shell.id,
        ghost_id: shell.ghost_id,
        sector_id: shell.sector_id,
        level: level
      }
    )

    if shell.drift_state != level do
      GiTF.Telemetry.emit([:gitf, :drift, :state_changed], %{}, %{
        shell_id: shell.id,
        from: shell.drift_state,
        to: level
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- Private: Auto-rebase Gates ----------------------------------------------

  defp guard_drift_level(%{drift_state: :behind}), do: :ok
  defp guard_drift_level(%{drift_state: level}), do: {:skip, level_not_behind_reason(level)}
  defp guard_drift_level(_), do: {:skip, :no_drift_state}

  defp level_not_behind_reason(:clean), do: :clean
  defp level_not_behind_reason(:risky), do: :risky
  defp level_not_behind_reason(:conflicted), do: :conflicted
  defp level_not_behind_reason(:unknown), do: :unknown
  defp level_not_behind_reason(_), do: :unknown

  defp guard_ghost_idle(shell) do
    case Archive.get(:ghosts, shell.ghost_id) do
      nil ->
        :ok

      %{status: status} when status in ["working", "starting", "assigned"] ->
        {:skip, :ghost_running}

      _ ->
        :ok
    end
  end

  defp guard_worktree_clean(shell) do
    case Git.safe_cmd(["status", "--porcelain"],
           cd: shell.worktree_path,
           stderr_to_stdout: true
         ) do
      {"", 0} -> :ok
      {_, 0} -> {:skip, :worktree_dirty}
      _ -> {:skip, :status_failed}
    end
  rescue
    _ -> {:skip, :status_failed}
  end

  defp do_rebase(shell) do
    ref = shell.base_ref || "origin/main"

    case Git.safe_cmd(["rebase", ref], cd: shell.worktree_path, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        Git.safe_cmd(["rebase", "--abort"], cd: shell.worktree_path, stderr_to_stdout: true)
        Logger.warning("Auto-rebase failed for shell #{shell.id}: #{String.slice(output, 0, 200)}")
        {:error, :rebase_failed}
    end
  end

  defp update_shell_after_rebase(shell) do
    # Read the new HEAD of the worktree, which is now rebased on top of main
    new_base =
      case Git.rev_parse(shell.worktree_path, shell.base_ref || "origin/main") do
        {:ok, sha} -> sha
        _ -> shell.base_commit_sha
      end

    meta =
      (shell.drift_meta || %{})
      |> Map.put(:last_auto_rebase_at, DateTime.utc_now())
      |> Map.put(:last_auto_rebase_result, :ok)

    updated =
      shell
      |> Map.put(:base_commit_sha, new_base)
      |> Map.put(:drift_state, :clean)
      |> Map.put(:drift_checked_at, DateTime.utc_now())
      |> Map.put(:drift_meta, meta)

    Archive.put(:shells, updated)
    updated
  end

  # -- Private: Rate Limiting --------------------------------------------------

  # Minimum seconds between fetches for a given sector
  @fetch_cooldown_seconds 240

  defp should_fetch?(sector_id) do
    case :persistent_term.get({:drift_last_fetch, sector_id}, nil) do
      nil ->
        true

      last_time ->
        now = System.monotonic_time(:second)
        now - last_time >= @fetch_cooldown_seconds
    end
  rescue
    _ -> true
  end
end
