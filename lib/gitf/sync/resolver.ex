defmodule GiTF.Sync.Resolver do
  @moduledoc """
  Tiered conflict resolution for sync failures.

  ## Tiers

  0. Clean sync (`git merge --no-edit`)
  1. Auto-resolve: accept incoming for files only this op touched, union for additive
  2. AI-resolve: use LLM to resolve each conflicted file
  3. Re-imagine: abort sync, create a new conflict_resolution op

  Each tier escalates to the next on failure. Conflict history is consulted
  to skip tiers that historically fail for the involved files.
  """

  require Logger

  alias GiTF.Archive
  alias GiTF.Sync.History

  @additive_patterns ~w(.changelog .changes CHANGELOG CHANGES)
  @max_ai_resolve_files 5

  # -- Public API --------------------------------------------------------------

  @doc """
  Attempts to sync a op's shell branch into the target branch.
  Escalates through tiers on failure.

  Returns `{:ok, :merged, tier}` or `{:error, reason, last_tier}`.
  """
  @spec resolve(String.t(), String.t()) ::
          {:ok, :merged, non_neg_integer()} | {:error, term(), non_neg_integer()}
  def resolve(op_id, shell_id) do
    with {:ok, shell} <- fetch_cell_with_fallback(shell_id, op_id),
         {:ok, sector} <- fetch_sector(shell.sector_id),
         {:ok, target} <- determine_target_branch(op_id, sector) do
      strategy = Map.get(sector, :sync_strategy) || "auto_merge"

      case strategy do
        "manual" ->
          Logger.info("Sync strategy manual for op #{op_id}, skipping merge")
          {:ok, :manual, 0}

        "pr_branch" ->
          Logger.info("Sync strategy pr_branch for op #{op_id}, creating PR")

          case GiTF.Sync.create_local_pr(shell, sector, op_id) do
            {:ok, _url} ->
              {:ok, :pr_created, 0}

            {:error, reason} ->
              # PR creation may fail (no remote, no gh CLI, etc.) but the branch
              # still exists — advance the pipeline so work isn't stuck.
              Logger.warning(
                "PR creation failed for op #{op_id}: #{inspect(reason)}, " <>
                  "branch #{shell.branch} still available for manual PR"
              )

              {:ok, :pr_created, 0}
          end

        _ ->
          # "auto_merge" or unrecognized — use tier-based merge
          attempt_tiers(op_id, shell_id, shell, sector, target, 0)
      end
    else
      {:error, reason} -> {:error, reason, -1}
    end
  end

  # -- Private: tier escalation ------------------------------------------------

  defp attempt_tiers(op_id, _cell_id, _cell, _sector, _target, tier) when tier > 3 do
    Logger.error("All sync tiers exhausted for op #{op_id}")

    GiTF.Telemetry.emit([:gitf, :sync, :exhausted], %{}, %{
      op_id: op_id,
      tiers_attempted: 4
    })

    {:error, :all_tiers_exhausted, 3}
  end

  defp attempt_tiers(op_id, shell_id, shell, sector, target, tier) do
    # Check if we should skip this tier based on history
    changed = get_changed_files(sector.path, shell.branch, target)

    if tier in [1, 2] and History.should_skip_tier?(tier, changed) do
      Logger.info("Skipping tier #{tier} for op #{op_id} (history suggests it will fail)")
      attempt_tiers(op_id, shell_id, shell, sector, target, tier + 1)
    else
      result = run_tier(tier, op_id, shell, sector, target)

      case result do
        {:ok, :merged} ->
          History.record(%{
            op_id: op_id,
            shell_id: shell_id,
            tier: tier,
            status: :success,
            files: changed,
            error: nil
          })

          {:ok, :merged, tier}

        {:error, reason} ->
          History.record(%{
            op_id: op_id,
            shell_id: shell_id,
            tier: tier,
            status: :failure,
            files: changed,
            error: inspect(reason)
          })

          Logger.info("Tier #{tier} failed for op #{op_id}: #{inspect(reason)}, escalating")

          GiTF.Telemetry.emit([:gitf, :sync, :tier_failed], %{}, %{
            op_id: op_id,
            tier: tier,
            reason: inspect(reason)
          })

          attempt_tiers(op_id, shell_id, shell, sector, target, tier + 1)
      end
    end
  end

  # -- Private: individual tiers -----------------------------------------------

  # Tiers 0-2 share one shape: the ENTIRE merge — conflict resolution and
  # validation included — happens in a scratch worktree on a branch nothing
  # else knows about, and the shared clone's target only ever advances by a
  # fast-forward to the finished, validated commit.
  #
  # The previous shape did all of this in sector.path itself: checkout,
  # merge --no-commit, model-authored rewrites of conflicted files, a
  # validation run, then commit-or-abort — with reset --hard as the failure
  # path. That made the shared clone's dirty window as long as a validation
  # run (now up to 30 minutes for a sector like cora), left MERGE_HEAD and a
  # conflicted index behind whenever the SyncQueue's deadline killed the
  # task (Process.exit(:kill) runs no abort), and raced Debrief's regression
  # check, which builds in sector.path on its own timer. In the scratch
  # shape a kill at any point strands only a throwaway worktree, an abort is
  # "remove the directory", and nothing that reads target can ever observe a
  # half-merged or unvalidated state.
  defp run_tier(tier, op_id, shell, sector, target) when tier in 0..2 do
    Logger.info("Tier #{tier} (#{tier_name(tier)}) for op #{op_id}")

    with_sync_lock(sector.id, fn ->
      in_scratch_worktree(sector, op_id, tier, target, fn scratch ->
        case merge_branch(scratch.path, shell.branch) do
          :clean ->
            commit_and_publish(scratch, shell, sector, target)

          {:conflicted, conflicted} ->
            resolve_and_publish(tier, scratch, conflicted, shell, sector, target, op_id)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end)
  end

  @max_reimagine_iterations 3

  # Tier 3: Re-imagine — create a new op to reimplement the changes
  defp run_tier(3, op_id, shell, sector, target) do
    Logger.info("Tier 3 (re-imagine) for op #{op_id}")

    # Tiers 0-2 no longer dirty the shared clone, so there should be nothing
    # to abort — this sweeps stale state left by a pre-scratch-worktree
    # release or by anything else that merged in sector.path directly.
    abort_merge(sector.path)

    with {:ok, op} <- GiTF.Ops.get(op_id),
         :ok <- check_reimagine_limit(op) do
      # Get the diff that the original op produced
      diff = get_branch_diff(sector.path, shell.branch, target)

      description = """
      ## Conflict Resolution Job

      The original op "#{op.title}" (#{op_id}) produced changes that conflict
      with the current state of #{target}.

      **Your task:** Reimplement the intent of the original changes on top of the
      current #{target} branch. Do NOT try to replay the exact diff — understand
      what the original op was trying to accomplish and achieve the same result
      in a way that's compatible with the current codebase.

      ### Original op description
      #{op.description || "No description"}

      ### Files that conflicted
      #{diff[:conflicted_files] |> Enum.join("\n")}

      ### Original diff summary
      #{diff[:summary]}
      """

      attrs = %{
        title: "[Conflict Resolution] #{op.title}",
        description: description,
        mission_id: op.mission_id,
        sector_id: op.sector_id,
        op_type: "implementation",
        retry_of: op_id,
        retry_count: Map.get(op, :retry_count, 0) + 1,
        target_files: op[:target_files]
      }

      case GiTF.Ops.create(attrs) do
        {:ok, reimagine_job} ->
          Logger.info("Created re-imagine op #{reimagine_job.id} for #{op_id}")

          GiTF.Link.send(
            "merge_resolver",
            "major",
            "reimagine_job_created",
            "Created conflict resolution op #{reimagine_job.id} for #{op_id}"
          )

          # The re-imagine op will go through the full ghost → tachikoma → sync pipeline
          {:error, {:reimagined, reimagine_job.id}}

        {:error, reason} ->
          {:error, {:reimagine_failed, reason}}
      end
    end
  end

  defp tier_name(0), do: "clean sync"
  defp tier_name(1), do: "auto-resolve"
  defp tier_name(2), do: "AI-resolve"

  # Tier 0 resolves nothing: any conflict escalates.
  defp resolve_and_publish(0, _scratch, conflicted, _shell, _sector, _target, _op_id),
    do: {:error, {:clean_merge_failed, {:conflicts, length(conflicted)}}}

  defp resolve_and_publish(1, scratch, conflicted, shell, sector, target, _op_id) do
    resolved = auto_resolve_files(scratch.path, conflicted, shell, sector, target)

    if resolved == length(conflicted) do
      commit_and_publish(scratch, shell, sector, target)
    else
      {:error, {:partial_resolve, resolved, length(conflicted)}}
    end
  end

  defp resolve_and_publish(2, scratch, conflicted, shell, sector, target, op_id) do
    if length(conflicted) > @max_ai_resolve_files do
      {:error, {:too_many_conflicts, length(conflicted)}}
    else
      resolved = ai_resolve_files(scratch.path, conflicted, op_id)

      if resolved == length(conflicted) do
        case validate_resolution(sector, scratch.path) do
          :ok -> commit_and_publish(scratch, shell, sector, target)
          {:error, reason} -> {:error, {:validation_failed_after_ai_resolve, reason}}
        end
      else
        {:error, {:ai_resolve_incomplete, resolved, length(conflicted)}}
      end
    end
  end

  # Merge into the scratch worktree's own branch. --no-commit so a clean
  # merge and a conflicted one land in the same "inspect before committing"
  # state; nothing outside the scratch can see either.
  defp merge_branch(scratch_path, branch) do
    case GiTF.Git.safe_cmd(["merge", "--no-commit", "--no-ff", "--no-edit", branch],
           cd: scratch_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :clean

      {_output, _code} ->
        case get_conflicted_files(scratch_path) do
          [] -> {:error, :no_conflicted_files}
          conflicted -> {:conflicted, conflicted}
        end
    end
  end

  defp commit_and_publish(scratch, shell, sector, target) do
    commit_merge(scratch.path, shell.branch, target)
    publish_ff(sector.path, target, scratch.branch)
  end

  # The only write tiers 0-2 ever make to the shared clone. --ff-only is the
  # invariant, not an optimisation: if it cannot fast-forward, target moved
  # while we merged, and the answer is to fail the tier and re-merge from
  # the new tip — never to force anything.
  defp publish_ff(repo, target, scratch_branch) do
    with :ok <- GiTF.Git.checkout(repo, target),
         {_out, 0} <-
           GiTF.Git.safe_cmd(["merge", "--ff-only", scratch_branch],
             cd: repo,
             stderr_to_stdout: true
           ) do
      {:ok, :merged}
    else
      {out, _code} when is_binary(out) -> {:error, {:publish_failed, String.trim(out)}}
      {:error, reason} -> {:error, {:publish_failed, reason}}
    end
  end

  # Creates the scratch worktree at target's tip, runs `fun`, and always
  # tears it down — worktree, directory, and branch. Creation is idempotent:
  # a killed predecessor's leftovers are removed first, and worktree_add's
  # -B resets the branch rather than dying on it.
  defp in_scratch_worktree(sector, op_id, tier, target, fun) do
    suffix = "sync-#{op_id}-t#{tier}"
    path = Path.join([sector.path, "ghosts", suffix])
    branch = "gitf/#{suffix}"

    if File.dir?(path) do
      GiTF.Git.worktree_remove(sector.path, path, force: true)
      File.rm_rf(path)
    end

    case GiTF.Git.worktree_add(sector.path, path, branch, target) do
      {:ok, _} ->
        try do
          fun.(%{path: path, branch: branch})
        after
          GiTF.Git.worktree_remove(sector.path, path, force: true)
          File.rm_rf(path)
          # After a publish the branch tip equals target; after a failure it
          # is abandoned by design. -D covers both.
          GiTF.Git.safe_cmd(["branch", "-D", branch], cd: sector.path, stderr_to_stdout: true)
        end

      {:error, reason} ->
        {:error, {:scratch_worktree_failed, reason}}

      other ->
        {:error, {:scratch_worktree_failed, other}}
    end
  end

  # -- Private: auto-resolve helpers -------------------------------------------

  defp auto_resolve_files(repo, conflicted, shell, _sector, target) do
    Enum.count(conflicted, fn file ->
      cond do
        additive_file?(file) ->
          # Union sync for additive files
          case GiTF.Git.safe_cmd(["checkout", "--union", "--", file],
                 cd: repo,
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              GiTF.Git.safe_cmd(["add", file], cd: repo, stderr_to_stdout: true)
              true

            _ ->
              false
          end

        file_only_touched_by_branch?(repo, file, shell.branch, target) ->
          # Accept incoming (the ghost's version) for files only this branch touched
          case GiTF.Git.safe_cmd(["checkout", "--theirs", "--", file],
                 cd: repo,
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              GiTF.Git.safe_cmd(["add", file], cd: repo, stderr_to_stdout: true)
              true

            _ ->
              false
          end

        true ->
          false
      end
    end)
  end

  defp additive_file?(file) do
    basename = Path.basename(file)
    Enum.any?(@additive_patterns, &String.contains?(basename, &1))
  end

  defp file_only_touched_by_branch?(repo, file, branch, target) do
    # Check if the file was modified on the target branch since the sync base
    case GiTF.Git.safe_cmd(["merge-base", branch, target], cd: repo, stderr_to_stdout: true) do
      {base, 0} ->
        base = String.trim(base)

        case GiTF.Git.safe_cmd(["diff", "--name-only", "#{base}..#{target}", "--", file],
               cd: repo,
               stderr_to_stdout: true
             ) do
          {output, 0} -> String.trim(output) == ""
          _ -> false
        end

      _ ->
        false
    end
  end

  # -- Private: AI-resolve helpers ---------------------------------------------

  defp ai_resolve_files(repo, conflicted, op_id) do
    Enum.count(conflicted, fn file ->
      case ai_resolve_single_file(repo, file, op_id) do
        :ok -> true
        :error -> false
      end
    end)
  end

  defp ai_resolve_single_file(repo, file, op_id) do
    file_path = Path.join(repo, file)

    case File.read(file_path) do
      {:ok, content} ->
        if String.contains?(content, "<<<<<<<") do
          prompt = build_ai_resolve_prompt(file, content, op_id)

          case GiTF.Runtime.Models.generate_text(prompt, model: "haiku", max_tokens: 8192) do
            {:ok, resolved} when is_binary(resolved) and resolved != "" ->
              # Validate it's not prose
              if looks_like_code?(resolved, file) do
                File.write!(file_path, resolved)
                GiTF.Git.safe_cmd(["add", file], cd: repo, stderr_to_stdout: true)
                :ok
              else
                Logger.warning("AI-resolve produced prose for #{file}, skipping")
                :error
              end

            _ ->
              :error
          end
        else
          # No conflict markers — already resolved or not actually conflicted
          GiTF.Git.safe_cmd(["add", file], cd: repo, stderr_to_stdout: true)
          :ok
        end

      {:error, _} ->
        :error
    end
  rescue
    e ->
      Logger.warning("AI-resolve failed for #{file}: #{Exception.message(e)}")
      :error
  end

  defp build_ai_resolve_prompt(file, content, op_id) do
    job_context =
      case GiTF.Ops.get(op_id) do
        {:ok, op} -> "Job: #{op.title}\n#{op.description || ""}"
        _ -> ""
      end

    """
    You are resolving a git merge conflict. Output ONLY the resolved file content.
    No explanations, no markdown code fences, no commentary — just the file content.

    File: #{file}
    #{job_context}

    The file below contains git conflict markers (<<<<<<< ======= >>>>>>>).
    Sync both sides intelligently, keeping the intent of both changes.
    If the changes are incompatible, prefer the incoming (theirs) version
    since it represents the newer work.

    #{content}
    """
  end

  defp looks_like_code?(text, _file) do
    # Heuristic: code files should not start with natural language patterns
    trimmed = String.trim(text)

    prose_starters = [
      ~r/^(Here|I |The |This |To |In |Let me|Sure|Certainly|Of course)/i,
      ~r/^```/,
      ~r/^\#{3,}\s/
    ]

    # Should have reasonable line count relative to file extension
    # Shouldn't be mostly empty
    not Enum.any?(prose_starters, &Regex.match?(&1, trimmed)) and
      String.contains?(trimmed, "\n") and
      String.length(trimmed) > 10
  end

  # -- Private: target branch determination ------------------------------------

  defp determine_target_branch(op_id, sector) do
    # Priority: mission.target_branch > sector config > detect main
    with {:ok, op} <- GiTF.Ops.get(op_id) do
      quest_branch =
        case op.mission_id && Archive.get(:missions, op.mission_id) do
          nil -> nil
          mission -> Map.get(mission, :target_branch)
        end

      sector_branch = Map.get(sector, :target_branch)

      case quest_branch || sector_branch do
        nil -> detect_main_branch(sector.path)
        branch -> {:ok, branch}
      end
    end
  end

  # -- Private: git helpers ----------------------------------------------------

  defp abort_merge(repo) do
    GiTF.Git.safe_cmd(["merge", "--abort"], cd: repo, stderr_to_stdout: true)
    :ok
  end

  # INVARIANT: no `-a` here, and validation must keep running AFTER the
  # resolved files are `git add`ed. The scratch worktree is dirty with the
  # validation command's install residue (npm ci rewrites lockfiles); only
  # the ordering "stage resolutions → validate → commit the index" keeps
  # that residue out of the sync commit. Adding `-a`, or staging after
  # validation, would commit it.
  defp commit_merge(repo, branch, target) do
    GiTF.Git.safe_cmd(["commit", "--no-edit", "-m", "Sync #{branch} into #{target}"],
      cd: repo,
      stderr_to_stdout: true
    )

    :ok
  end

  defp get_conflicted_files(repo) do
    case GiTF.Git.safe_cmd(["diff", "--name-only", "--diff-filter=U"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  end

  defp get_changed_files(repo, branch, target) do
    case GiTF.Git.safe_cmd(["diff", "--name-only", "#{target}...#{branch}"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp get_branch_diff(repo, branch, target) do
    conflicted =
      case GiTF.Git.safe_cmd(["diff", "--name-only", "#{target}...#{branch}"],
             cd: repo,
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.split(output, "\n", trim: true)
        _ -> []
      end

    summary =
      case GiTF.Git.safe_cmd(["diff", "--stat", "#{target}...#{branch}"],
             cd: repo,
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.slice(output, 0, 2000)
        _ -> "Could not generate diff summary"
      end

    %{conflicted_files: conflicted, summary: summary}
  rescue
    _ -> %{conflicted_files: [], summary: "Error generating diff"}
  end

  defp check_reimagine_limit(op) do
    reimagine_count = Map.get(op, :retry_count, 0)

    if reimagine_count >= @max_reimagine_iterations do
      Logger.error("Job #{op.id} hit max reimagine iterations (#{reimagine_count})")
      {:error, :max_reimagine_iterations}
    else
      :ok
    end
  end

  defp detect_main_branch(repo_path) do
    cond do
      GiTF.Git.branch_exists?(repo_path, "main") -> {:ok, "main"}
      GiTF.Git.branch_exists?(repo_path, "master") -> {:ok, "master"}
      true -> GiTF.Git.current_branch(repo_path)
    end
  end

  # Was a bare `System.cmd("sh", ["-c", command])` — the only path in the
  # factory that ran a sector's validation command unsandboxed and with no
  # OS-level deadline. The box sets GITF_SANDBOX_REQUIRED=1 so a degraded
  # sandbox refuses rather than silently running unconfined; this bypassed it.
  #
  # The word blocklist that used to guard it is gone. It matched substrings,
  # so cora's command failed on `rm` (it contains `rm -rf node_modules`), and
  # `npm run format` would fail on the same `rm`, `concurrently` on `nc`.
  # Silently: the AI tier is the only one that validates, so an affected
  # sector lost conflict resolution entirely and was told only "contains
  # blocked operation". It was also guarding the wrong thing —
  # `validation_command` is set by onboarding detection or an operator, never
  # by a model, and Validator, Audit and Debrief all run that same field with
  # no blocklist at all. Confinement is the sandbox's job, and it is now
  # doing it here too.
  # `cwd` is the scratch worktree, not sector.path — the sandbox then binds
  # only the scratch directory writable, instead of the whole sector tree
  # with every ghost worktree and the shared .git inside it.
  defp validate_resolution(sector, cwd) do
    case Map.get(sector, :validation_command) do
      command when is_binary(command) and command != "" ->
        case GiTF.Validator.run_validation(cwd, command, sector) do
          {:ok, _output} -> :ok
          {:error, _kind, message, _exit_code} -> {:error, String.slice(message, 0, 500)}
        end

      _ ->
        :ok
    end
  rescue
    # Fails CLOSED. This was `rescue _ -> :ok`, which committed a merge as
    # though validation had passed whenever anything unexpected raised — on
    # the only tier that validates at all.
    e ->
      {:error, "validation raised: #{Exception.message(e)}"}
  end

  defp with_sync_lock(sector_id, fun) do
    lock_key = {:sync_lock, sector_id}

    case Registry.register(GiTF.Registry, lock_key, :lock) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(GiTF.Registry, lock_key)
        end

      {:error, {:already_registered, _}} ->
        # Wait and retry
        Process.sleep(500)

        case Registry.register(GiTF.Registry, lock_key, :lock) do
          {:ok, _} ->
            try do
              fun.()
            after
              Registry.unregister(GiTF.Registry, lock_key)
            end

          {:error, _} ->
            {:error, :sync_lock_contention}
        end
    end
  end

  defp fetch_cell_with_fallback(shell_id, op_id) do
    case Archive.get(:shells, shell_id) do
      %{branch: branch} = shell when is_binary(branch) ->
        {:ok, shell}

      _ ->
        # Shell cleaned up — read branch info from op record (saved by save_branch_info)
        case GiTF.Ops.get(op_id) do
          {:ok, %{branch: branch, sector_id: sid}} when is_binary(branch) and is_binary(sid) ->
            {:ok, %{id: shell_id, branch: branch, sector_id: sid, ghost_id: nil}}

          _ ->
            {:error, :shell_not_found}
        end
    end
  end

  defp fetch_sector(sector_id) do
    case Archive.get(:sectors, sector_id) do
      nil -> {:error, :sector_not_found}
      sector -> {:ok, sector}
    end
  end
end
