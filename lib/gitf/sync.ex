defmodule GiTF.Sync do
  @moduledoc """
  Handles merging ghost worktree branches back into the main codebase.

  After a ghost completes its op, the sync module applies the sector's
  configured sync strategy to integrate the ghost's changes.

  ## Strategies

    * `"manual"` -- No auto-sync. Sends a link_msg with instructions.
    * `"auto_merge"` -- Checks out the main branch and merges the ghost branch.
    * `"pr_branch"` -- Keeps the branch intact for a PR workflow.
  """

  require Logger

  alias GiTF.Archive

  @lock_timeout 60_000
  @lock_retry_interval 500

  @doc """
  Syncs a ghost's worktree branch back according to the sector's sync strategy.

  Looks up the shell, finds the sector, reads the sync_strategy, and dispatches.
  Returns `{:ok, strategy_applied}` or `{:error, reason}`.
  """
  @spec sync_back(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sync_back(shell_id, _opts \\ []) do
    with {:ok, shell} <- fetch_cell(shell_id),
         {:ok, sector} <- fetch_sector(shell.sector_id) do
      strategy = sector.sync_strategy || "manual"

      if strategy == "auto_merge" do
        with_sector_lock(sector.id, fn -> apply_strategy(strategy, shell, sector) end)
      else
        apply_strategy(strategy, shell, sector)
      end
    end
  end

  @doc """
  Syncs all completed ghost branches for a mission into a single mission branch.

  Creates `mission/<mission-name>` off the main branch, then merges each ghost's
  branch into it sequentially. Returns `{:ok, quest_branch}` with the branch
  name, or `{:error, reason}` if any sync fails.
  """
  @spec merge_quest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def merge_quest(mission_id) do
    with {:ok, mission} <- GiTF.Missions.get(mission_id),
         shells <- cells_for_quest(mission),
         true <- shells != [] || {:error, :no_cells},
         {:ok, sector} <- fetch_sector_for_cells(shells) do
      with_sector_lock(sector.id, fn ->
        with {:ok, main_branch} <- detect_main_branch(sector.path),
             quest_branch = "mission/#{mission.name}",
             :ok <- create_quest_branch(sector.path, quest_branch, main_branch) do
          merge_cells_into_quest_branch(sector.path, quest_branch, shells)
        end
      end)
    end
  end

  @doc """
  Creates a PR for a ghost branch, either via `gh` CLI or the GitHub API.

  Pushes the branch to origin first, then creates the PR. Falls back to
  `GiTF.GitHub.create_pr/3` when the sector has `github_owner`/`github_repo`.

  Returns `{:ok, pr_url}` or `{:error, reason}`.
  """
  @spec create_local_pr(map(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_local_pr(shell, sector, op_id) do
    repo_path = sector.path

    op =
      case GiTF.Ops.get(op_id) do
        {:ok, j} -> j
        _ -> nil
      end

    title = if op, do: op.title, else: "gitf: #{shell.branch}"
    body = if op, do: op.description || "", else: ""

    # If sector has GitHub API config, prefer that
    if Map.get(sector, :github_owner) && Map.get(sector, :github_repo) && op do
      case GiTF.GitHub.create_pr(sector, shell, op) do
        {:ok, url} ->
          Logger.info("PR created via GitHub API: #{url}")
          {:ok, url}

        {:error, api_reason} ->
          Logger.warning("GitHub API PR failed: #{inspect(api_reason)}, trying gh CLI")
          create_pr_via_gh(repo_path, shell.branch, title, body)
      end
    else
      create_pr_via_gh(repo_path, shell.branch, title, body)
    end
  rescue
    e ->
      Logger.warning("create_local_pr failed: #{Exception.message(e)}")
      {:error, {:pr_creation_failed, Exception.message(e)}}
  end

  defp create_pr_via_gh(repo_path, branch, title, body) do
    # Push the branch to origin
    case GiTF.Git.safe_cmd(["push", "-u", "origin", branch],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {push_output, _} ->
        # Check if it's just "already up to date" or similar non-error
        if String.contains?(push_output, "Everything up-to-date") do
          :ok
        else
          Logger.warning("Git push output: #{String.slice(push_output, 0, 200)}")
          # Continue anyway — branch might already be pushed
          :ok
        end
    end

    # Detect base branch
    {:ok, base} = detect_main_branch(repo_path)

    # Create PR via gh CLI — wrapped in Task to prevent sector lock hangs
    gh_task =
      Task.Supervisor.async_nolink(GiTF.TaskSupervisor, fn ->
        System.cmd(
          "gh",
          [
            "pr",
            "create",
            "--head",
            branch,
            "--base",
            base,
            "--title",
            title,
            "--body",
            String.slice(body, 0, 4000)
          ],
          cd: repo_path,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(gh_task, 30_000) || Task.shutdown(gh_task, :brutal_kill) do
      {:ok, {output, 0}} ->
        url = output |> String.trim()
        Logger.info("PR created via gh CLI: #{url}")
        {:ok, url}

      {:ok, {output, _code}} ->
        Logger.warning("gh pr create failed: #{String.slice(output, 0, 200)}")
        {:error, {:gh_pr_failed, String.slice(output, 0, 200)}}

      nil ->
        Logger.warning("gh pr create timed out after 30s")
        {:error, {:gh_pr_timeout, "timed out after 30s"}}
    end
  rescue
    e ->
      Logger.warning("gh CLI PR creation failed: #{Exception.message(e)}")
      {:error, {:gh_not_available, Exception.message(e)}}
  end

  # -- Private: per-sector sync lock --------------------------------------------

  @doc false
  def with_sector_lock(sector_id, fun) do
    lock_key = {:sync_lock, sector_id}
    acquire_lock(lock_key, @lock_timeout, fun)
  end

  defp acquire_lock(lock_key, remaining, _fun) when remaining <= 0 do
    Logger.warning("Sync lock timeout for #{inspect(lock_key)}")
    {:error, :sync_lock_timeout}
  end

  defp acquire_lock(lock_key, remaining, fun) do
    case Registry.register(GiTF.Registry, lock_key, :lock) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(GiTF.Registry, lock_key)
        end

      {:error, {:already_registered, _}} ->
        Process.sleep(@lock_retry_interval)
        acquire_lock(lock_key, remaining - @lock_retry_interval, fun)
    end
  end

  # -- Private: strategy dispatch ----------------------------------------------

  defp apply_strategy("manual", shell, _sector) do
    Logger.info("Sync strategy: manual. Branch #{shell.branch} ready for manual sync.")
    {:ok, "manual"}
  end

  defp apply_strategy("auto_merge", shell, sector) do
    repo_path = sector.path

    # Clean up any stale sync state from interrupted previous sync
    cleanup_stale_merge_state(repo_path)

    # Fetch remote before merging to catch commits pushed since shell creation.
    # Non-fatal: local repos without remotes still work.
    _ = GiTF.Git.fetch(repo_path, "origin")

    # Refresh drift state so post-sync telemetry reflects reality at sync time.
    _ = GiTF.Drift.check_shell(shell.id)

    # Save HEAD before any checkout/sync so we can always roll back
    original_head =
      case get_head(repo_path) do
        {:ok, head} -> head
        _ -> nil
      end

    with {:ok, main_branch} <- detect_main_branch(repo_path),
         :ok <- GiTF.Git.checkout(repo_path, main_branch),
         :ok <- GiTF.Git.sync(repo_path, shell.branch, no_ff: true) do
      Logger.info("Auto-merged #{shell.branch} into #{main_branch}")
      {:ok, "auto_merge"}
    else
      {:error, reason} ->
        Logger.warning("Auto-sync failed for #{shell.branch}: #{inspect(reason)}, rolling back")
        rollback_merge(repo_path, original_head)
        {:error, {:merge_conflict, reason}}
    end
  end

  defp apply_strategy("pr_branch", shell, sector) do
    Logger.info("Branch #{shell.branch} ready for PR.")
    maybe_create_github_pr(sector, shell)
    {:ok, "pr_branch"}
  end

  defp apply_strategy(unknown, _cell, _sector) do
    {:error, {:unknown_strategy, unknown}}
  end

  @doc """
  Syncs a ghost branch using rebase-then-sync strategy.

  Rebases the ghost branch onto main first, then does a fast-forward sync.
  Returns `{:ok, "rebase_merge"}` or `{:error, reason}`.
  """
  @spec sync_back_with_rebase(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def sync_back_with_rebase(shell_id, _opts \\ []) do
    with {:ok, shell} <- fetch_cell(shell_id),
         {:ok, sector} <- fetch_sector(shell.sector_id) do
      with_sector_lock(sector.id, fn ->
        with {:ok, main_branch} <- detect_main_branch(sector.path),
             :ok <- rebase_branch(shell.worktree_path, main_branch),
             :ok <- GiTF.Git.checkout(sector.path, main_branch),
             :ok <- GiTF.Git.sync(sector.path, shell.branch, []) do
          Logger.info("Rebase-merged #{shell.branch} into #{main_branch}")
          {:ok, "rebase_merge"}
        else
          {:error, reason} ->
            Logger.warning("Rebase-sync failed: #{inspect(reason)}")
            {:error, reason}
        end
      end)
    end
  end

  # -- Private: data fetching --------------------------------------------------

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

  defp maybe_create_github_pr(sector, shell) do
    if Map.get(sector, :github_owner) && Map.get(sector, :github_repo) do
      # Look up the op for this shell's ghost
      case Archive.find_one(:ops, fn j -> j.ghost_id == shell.ghost_id end) do
        nil ->
          Logger.debug("No op found for ghost #{shell.ghost_id}, skipping GitHub PR")

        op ->
          case GiTF.GitHub.create_pr(sector, shell, op) do
            {:ok, url} ->
              Logger.info("GitHub PR created: #{url}")
              GiTF.Link.send("system", "major", "pr_created", "PR: #{url}")

            {:error, reason} ->
              Logger.warning("GitHub PR creation failed: #{inspect(reason)}")
          end
      end
    end
  rescue
    e -> Logger.warning("GitHub PR error: #{Exception.message(e)}")
  end

  @doc false
  def detect_main_branch(repo_path) do
    # Try common main branch names
    cond do
      GiTF.Git.branch_exists?(repo_path, "main") -> {:ok, "main"}
      GiTF.Git.branch_exists?(repo_path, "master") -> {:ok, "master"}
      true -> GiTF.Git.current_branch(repo_path)
    end
  end

  # -- Private: mission sync helpers -------------------------------------------

  defp cells_for_quest(mission) do
    ghost_ids =
      mission.ops
      |> Enum.map(& &1.ghost_id)
      |> Enum.reject(&is_nil/1)

    Archive.filter(:shells, fn c ->
      c.ghost_id in ghost_ids and c.status == "active"
    end)
  end

  defp fetch_sector_for_cells([shell | _]) do
    fetch_sector(shell.sector_id)
  end

  defp create_quest_branch(repo_path, quest_branch, main_branch) do
    if GiTF.Git.branch_exists?(repo_path, quest_branch) do
      # Branch already exists — check it out
      GiTF.Git.checkout(repo_path, quest_branch)
    else
      GiTF.Git.branch_create(repo_path, quest_branch, main_branch)
    end
  end

  defp merge_cells_into_quest_branch(repo_path, quest_branch, shells) do
    # Save starting point for rollback
    {:ok, savepoint} = get_head(repo_path)

    results =
      Enum.map(shells, fn shell ->
        case GiTF.Git.sync(repo_path, shell.branch, no_ff: true) do
          :ok ->
            Logger.info("Syncd #{shell.branch} into #{quest_branch}")
            {:ok, shell.branch}

          {:error, reason} ->
            Logger.warning("Failed to sync #{shell.branch}: #{inspect(reason)}")
            # Abort the failed sync so subsequent merges can proceed
            GiTF.Git.safe_cmd(["sync", "--abort"], cd: repo_path, stderr_to_stdout: true)
            {:error, shell.branch, reason}
        end
      end)

    failures = Enum.filter(results, &match?({:error, _, _}, &1))

    if failures == [] do
      Logger.info("All ghost branches merged into #{quest_branch}")
      {:ok, quest_branch}
    else
      # Roll back to savepoint — none of the merges should persist if any failed
      Logger.warning(
        "Rolling back mission branch #{quest_branch} to savepoint due to sync failures"
      )

      GiTF.Git.safe_cmd(["reset", "--hard", savepoint], cd: repo_path, stderr_to_stdout: true)
      failed_branches = Enum.map(failures, fn {:error, branch, _} -> branch end)
      {:error, {:merge_conflicts, quest_branch, failed_branches}}
    end
  end

  # -- Private: git helpers ----------------------------------------------------

  defp get_head(repo_path) do
    case GiTF.Git.safe_cmd(["rev-parse", "HEAD"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, {:git_error, String.trim(output)}}
    end
  end

  defp cleanup_stale_merge_state(repo_path) do
    git_dir = Path.join(repo_path, ".git")
    merge_head = Path.join(git_dir, "MERGE_HEAD")
    rebase_merge = Path.join(git_dir, "rebase-merge")
    rebase_apply = Path.join(git_dir, "rebase-apply")

    if File.exists?(merge_head) do
      Logger.warning("Stale MERGE_HEAD found in #{repo_path}, aborting interrupted merge")
      GiTF.Git.safe_cmd(["merge", "--abort"], cd: repo_path, stderr_to_stdout: true)
    end

    if File.dir?(rebase_merge) or File.dir?(rebase_apply) do
      Logger.warning("Stale rebase state found in #{repo_path}, aborting interrupted rebase")
      GiTF.Git.safe_cmd(["rebase", "--abort"], cd: repo_path, stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  defp rollback_merge(repo_path, original_head) do
    # First try to abort any in-progress sync
    GiTF.Git.safe_cmd(["sync", "--abort"], cd: repo_path, stderr_to_stdout: true)

    # Then restore the original HEAD
    if original_head do
      GiTF.Git.safe_cmd(["reset", "--hard", original_head], cd: repo_path, stderr_to_stdout: true)
    end

    # Verify the repo is in a clean state
    case GiTF.Git.safe_cmd(["status", "--porcelain"], cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "UU") or String.contains?(output, "AA") do
          # Still has unresolved conflicts — force clean
          Logger.warning("Repo still dirty after rollback, force-cleaning #{repo_path}")
          GiTF.Git.safe_cmd(["checkout", "--", "."], cd: repo_path, stderr_to_stdout: true)
          GiTF.Git.safe_cmd(["clean", "-fd"], cd: repo_path, stderr_to_stdout: true)
        end

      {_, _code} ->
        # git status itself failed — repo might be corrupted
        Logger.error("Git status failed in #{repo_path}, attempting repair")
        repair_repo(repo_path)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp repair_repo(repo_path) do
    # Try fsck first
    case GiTF.Git.safe_cmd(["fsck", "--no-dangling"],
           cd: repo_path,
           stderr_to_stdout: true,
           env: [{"GIT_DIR", ".git"}]
         ) do
      {_, 0} ->
        Logger.info("Git fsck passed for #{repo_path}")

      {output, _} ->
        Logger.warning("Git fsck found issues in #{repo_path}: #{String.slice(output, 0, 200)}")
        # Force checkout to recover
        case detect_main_branch(repo_path) do
          {:ok, main} ->
            GiTF.Git.safe_cmd(["checkout", "-f", main], cd: repo_path, stderr_to_stdout: true)

          _ ->
            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp rebase_branch(worktree_path, main_branch) do
    case GiTF.Git.safe_cmd(["rebase", main_branch],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        GiTF.Git.safe_cmd(["rebase", "--abort"], cd: worktree_path, stderr_to_stdout: true)
        {:error, {:rebase_failed, String.slice(output, 0, 200)}}
    end
  end
end
