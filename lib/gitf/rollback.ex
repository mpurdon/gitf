defmodule GiTF.Rollback do
  @moduledoc """
  Post-merge rollback for missions whose sync introduced a regression.

  Uses `git revert -m 1 <merge_sha>` to create a new commit that undoes
  the bad merge — never `git reset --hard`. This keeps history intact and
  pushes cleanly to shared remotes.
  """

  require Logger
  alias GiTF.{Archive, Drift, Git, Missions, Shell, Sync, Telemetry}

  @default_revert_window_seconds 86_400

  @type reason ::
          :not_found
          | :no_sync
          | :no_merge_commit
          | :wrong_strategy
          | :stale_window
          | :already_reverted
          | :not_merged
          | :sector_not_found
          | :revert_failed

  # -- Public API --------------------------------------------------------------

  @doc """
  Returns `{:ok, info}` if the mission's merge can be reverted, else
  `{:error, reason}`.
  """
  @spec can_revert?(String.t()) :: {:ok, map()} | {:error, reason()}
  def can_revert?(mission_id), do: preflight(mission_id, false)

  @doc """
  Reverts a mission's merge. Returns `{:ok, info}` or `{:error, reason}`.

  Options:
    * `:force` - bypass the revert window check
  """
  @spec revert_merge(String.t(), keyword()) ::
          {:ok, %{revert_sha: String.t(), pushed: boolean()}} | {:error, reason()}
  def revert_merge(mission_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    case preflight(mission_id, force) do
      {:ok, info} ->
        result = Sync.with_sector_lock(info.sector_id, fn -> execute_revert(mission_id, info) end)

        case result do
          {:ok, _} = ok ->
            # Run downstream drift checks AFTER releasing the sector lock so
            # other sync work can proceed in parallel.
            invalidate_downstream_shells(info.sector_id, info.merge_commit_sha)
            ok

          err ->
            err
        end

      {:error, reason} = err ->
        Telemetry.emit([:gitf, :rollback, :revert_skipped], %{}, %{
          mission_id: mission_id,
          reason: reason
        })

        err
    end
  end

  @doc "Returns `:reverted | :not_reverted | :unknown` for a mission."
  @spec revert_status(String.t()) :: :reverted | :not_reverted | :unknown
  def revert_status(mission_id) do
    case Archive.get(:missions, mission_id) do
      %{} = mission ->
        case Missions.get_artifact(mission.id, "sync") do
          %{"reverted_at" => _} -> :reverted
          %{"status" => "success"} -> :not_reverted
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  # -- Private: Preflight ------------------------------------------------------

  defp preflight(mission_id, force) do
    with %{} = mission <- Archive.get(:missions, mission_id) || {:error, :not_found},
         {:ok, sync} <- fetch_sync_artifact(mission),
         :ok <- guard_status(sync),
         :ok <- guard_strategy(sync),
         :ok <- guard_has_merge_commit(sync),
         :ok <- guard_not_reverted(sync),
         :ok <- (if force, do: :ok, else: guard_within_window(sync)) do
      {:ok, build_info(mission_id, mission, sync)}
    else
      {:error, _} = err -> err
    end
  end

  defp build_info(mission_id, mission, sync) do
    %{
      mission_id: mission_id,
      sector_id: mission.sector_id,
      sync: sync,
      merge_commit_sha: sync["merge_commit_sha"],
      main_branch: sync["main_branch"] || "main",
      merged_at: sync["merged_at"]
    }
  end

  defp fetch_sync_artifact(mission) do
    case Missions.get_artifact(mission.id, "sync") do
      nil -> {:error, :no_sync}
      %{} = sync -> {:ok, sync}
    end
  end

  defp guard_status(%{"status" => "success"}), do: :ok
  defp guard_status(_), do: {:error, :not_merged}

  defp guard_strategy(%{"revertible" => true}), do: :ok
  defp guard_strategy(_), do: {:error, :wrong_strategy}

  defp guard_has_merge_commit(%{"merge_commit_sha" => sha}) when is_binary(sha) and sha != "",
    do: :ok

  defp guard_has_merge_commit(_), do: {:error, :no_merge_commit}

  defp guard_not_reverted(%{"reverted_at" => _}), do: {:error, :already_reverted}
  defp guard_not_reverted(_), do: :ok

  defp guard_within_window(%{"merged_at" => merged_at}) when not is_nil(merged_at) do
    case to_datetime(merged_at) do
      {:ok, dt} ->
        age = DateTime.diff(DateTime.utc_now(), dt, :second)
        if age <= revert_window_seconds(), do: :ok, else: {:error, :stale_window}

      _ ->
        :ok
    end
  end

  defp guard_within_window(_), do: :ok

  # -- Private: Revert Execution -----------------------------------------------

  defp execute_revert(mission_id, info) do
    case Archive.get(:sectors, info.sector_id) do
      nil ->
        {:error, :sector_not_found}

      sector ->
        do_git_revert(mission_id, info, sector)
    end
  end

  defp do_git_revert(mission_id, info, sector) do
    repo_path = sector.path
    main_branch = info.main_branch

    with :ok <- Git.checkout(repo_path, main_branch),
         :ok <- run_revert(repo_path, info.merge_commit_sha),
         {:ok, revert_sha} <- Git.head_sha(repo_path) do
      pushed = push_revert(repo_path, main_branch)
      update_artifact_after_revert(mission_id, info.sync, revert_sha, pushed)

      Telemetry.emit([:gitf, :rollback, :reverted], %{}, %{
        mission_id: mission_id,
        merge_commit_sha: info.merge_commit_sha,
        revert_sha: revert_sha,
        pushed: pushed
      })

      {:ok, %{revert_sha: revert_sha, pushed: pushed}}
    else
      {:error, reason} ->
        Telemetry.emit([:gitf, :rollback, :revert_failed], %{}, %{
          mission_id: mission_id,
          reason: inspect(reason)
        })

        {:error, :revert_failed}
    end
  end

  defp run_revert(repo_path, merge_sha) do
    case Git.safe_cmd(["revert", "-m", "1", "--no-edit", merge_sha],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, _} ->
        Git.safe_cmd(["revert", "--abort"], cd: repo_path, stderr_to_stdout: true)
        Logger.warning("git revert failed: #{String.slice(output, 0, 200)}")
        {:error, :revert_failed}
    end
  end

  defp push_revert(repo_path, main_branch) do
    case Git.safe_cmd(["push", "origin", main_branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Telemetry.emit([:gitf, :rollback, :revert_pushed], %{}, %{repo_path: repo_path})
        true

      {output, _} ->
        Logger.debug("Revert push failed (non-fatal): #{String.slice(output, 0, 200)}")
        false
    end
  end

  defp update_artifact_after_revert(mission_id, sync, revert_sha, pushed) do
    updated =
      sync
      |> Map.put("reverted_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("revert_commit_sha", revert_sha)
      |> Map.put("revert_pushed", pushed)

    Missions.store_artifact(mission_id, "sync", updated)
  end

  # Triggers a fresh drift check on shells whose base could be affected by
  # the revert. Pre-filters to shells whose base SHA matches the merge commit;
  # other shells are unaffected and skipped.
  defp invalidate_downstream_shells(sector_id, merge_commit_sha) do
    Shell.list(sector_id: sector_id, status: "active")
    |> Enum.filter(&(&1[:base_commit_sha] == merge_commit_sha))
    |> Enum.each(fn shell ->
      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        try do
          Drift.check_shell(shell.id)
          Drift.maybe_auto_rebase(shell.id)
        rescue
          e ->
            Logger.debug(
              "Downstream shell drift check failed for #{shell.id}: #{Exception.message(e)}"
            )
        end
      end)
    end)

    :ok
  end

  # -- Private: Helpers --------------------------------------------------------

  defp revert_window_seconds do
    GiTF.Config.Provider.get([:debrief, :revert_window_seconds]) ||
      @default_revert_window_seconds
  end

  defp to_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp to_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp to_datetime(_), do: :error
end
