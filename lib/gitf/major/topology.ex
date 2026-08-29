defmodule GiTF.Major.Topology do
  @moduledoc """
  THE TOPOLOGY — the terrain a mission's work is laid out on: which
  branch a new worktree forks from, which worktree is the canonical one,
  and how the per-ghost branches are folded back into a single tree that
  validation and publish can judge.

  Every ghost commits to its own `ghost/<id>` branch, so the mission's
  work is scattered across N branches until consolidation unions them
  into the canonical worktree. This module owns that union — the merge
  LOOP itself, the generated-file shortcut, and the base-branch
  resolution every spawn path shares.

  Named because the scars here are all navigational — the factory kept
  looking at the wrong tree:

    * msn-807187 (finding #17): parallel impl ops committed to sibling
      branches and the validator diffed only one, reporting finished,
      type-checked work as "completely missing". Three runs died at the
      validation wall staring at origin/main.
    * Run 13: a conflicted merge was ABORTED, silently dropping whole
      branches. Visible markers beat invisible absence.
    * msn-7683ac: merge-everything diverges past two branches — each
      further union merge conflicts against already-committed markers,
      nesting them (61 marker lines through models.rs, five branches
      deep). One conflicted merge at a time is now the invariant.
    * Run 32: re-merging a branch already contained in the tree
      re-injected the markers the fix loop had just reconciled, and
      hand-merging `src/bindings/*.ts` fought a generator.
    * Run 17: an op-derived branch name lagged the real lineage tip, so
      validation was based on chain op 2's branch while ops 3-4 and the
      fixes lived further down the line.
    * msn-dd29a1: a mission amending an open PR was cut from main, so the
      file under review did not exist in any ghost's worktree.
    * Runs 4-6: a failed mission's tree was pruned with the mission — hours
      of merged, type-checked work destroyed by the cleanup that follows
      `fail_quest`, leaving nothing to resume from. Failure now archives the
      canonical branch first (`archive_canonical_branch/1`).
  """

  require Logger

  alias GiTF.Archive

  # -- Base-branch resolution --------------------------------------------------

  # Returns [base_branch: "ghost/<id>"] when a completed impl op exists for
  # the mission, or [] if none — in which case worktrees branch from sector
  # HEAD (the current default).
  #
  # Public (undocumented) because it is THE owner of "which branch does a
  # new worktree fork from" — Major's spawn path calls it too. A second
  # hand-rolled copy there dropped the run-17 fallbacks within a day.
  @doc false
  def impl_base_branch_opts(mission) do
    # Base validation on the canonical worktree's CURRENT branch — the
    # deepest lineage point, including post-chain fix commits. An
    # op-derived branch name can lag (run 17: validation based on chain
    # op 2's branch while ops 3-4 and fixes lived further down the line).
    case GiTF.Validation.canonical_branch(mission) do
      branch when is_binary(branch) ->
        [base_branch: branch]

      _ ->
        case GiTF.Validation.latest_completed_impl_op(mission) do
          %{ghost_id: ghost_id} when is_binary(ghost_id) ->
            [base_branch: "ghost/#{ghost_id}"]

          # No prior impl work: fall back to the branch being amended, if
          # any, rather than sector HEAD.
          _ ->
            mission_base_branch_opts(mission)
        end
    end
  end

  # The branch a mission is amending, when it is amending one. Callers use it
  # as the base for worktrees so ghosts see the code under review.
  @doc false
  def mission_base_branch_opts(mission) do
    case Map.get(mission, :target_branch) do
      branch when is_binary(branch) and branch != "" -> [base_branch: branch]
      _ -> []
    end
  end

  # Returns [base_branch: <quest-branch>] when sync recorded a branch for
  # the mission, or [] if not available. Used by simplify so its cleanup
  # commits land on the quest branch instead of orphaning from main.
  @doc false
  def quest_branch_base_opts(mission) do
    case GiTF.Missions.get_artifact(mission.id, "sync") do
      %{"branch" => branch} when is_binary(branch) and branch != "" ->
        [base_branch: branch]

      _ ->
        []
    end
  end

  # Returns the ghost-id-based branch for `variant_id`'s most recent
  # completed impl op, or `nil` if none / non-tournament mode.
  @doc false
  def variant_base_branch(_mission, nil), do: nil

  def variant_base_branch(mission, variant_id) do
    mission.ops
    |> Enum.filter(fn op ->
      op[:phase_job] in [nil, false] and op.status == "done" and op[:variant] == variant_id
    end)
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> List.first()
    |> case do
      %{ghost_id: ghost_id} when is_binary(ghost_id) -> "ghost/#{ghost_id}"
      _ -> nil
    end
  end

  # Best-guess diff base: the sector's main branch. Falls back to "main".
  @doc false
  def detect_diff_base(mission) do
    with sector_id when is_binary(sector_id) <- mission.sector_id,
         %{path: path} when is_binary(path) <- Archive.get(:sectors, sector_id),
         {:ok, branch} <- GiTF.Sync.detect_main_branch(path) do
      branch
    else
      _ -> "main"
    end
  end

  # -- Worktree selection ------------------------------------------------------

  # The exec command (typecheck + the runtime probe) MUST run in the same
  # tree the LLM validator judges and publish ships — the CANONICAL shell,
  # which is also the consolidation target. Run 31 proved why: the probe
  # passed in one worktree while the validator correctly reported
  # conflict markers in another, so a green probe said nothing about the
  # tree under judgement. Falls back to the per-variant impl shell only
  # when no canonical shell exists (tournament variants have their own).
  @doc false
  def exec_validation_shell(mission, nil) do
    case GiTF.Validation.canonical_impl_shell(mission) do
      %{worktree_path: _} = shell -> shell
      _ -> variant_shell(mission, nil)
    end
  end

  def exec_validation_shell(mission, variant_id), do: variant_shell(mission, variant_id)

  @doc false
  def variant_shell(mission, variant_id) do
    with %{ghost_id: ghost_id} when is_binary(ghost_id) <-
           impl_op_for_variant(mission, variant_id),
         %{shell_id: shell_id} when is_binary(shell_id) <- Archive.get(:ghosts, ghost_id) do
      Archive.get(:shells, shell_id)
    else
      _ -> nil
    end
  end

  defp impl_op_for_variant(mission, nil), do: GiTF.Validation.latest_completed_impl_op(mission)

  defp impl_op_for_variant(mission, variant_id) do
    mission.ops
    |> Enum.filter(fn op ->
      op[:phase_job] in [nil, false] and op.status == "done" and op[:variant] == variant_id
    end)
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> List.first()
  end

  # -- Consolidation -----------------------------------------------------------

  # Merge every completed impl op's ghost branch into the LATEST completed
  # op's worktree so validation (and publish downstream) sees the UNION of
  # the mission's work. Parallel impl ops commit to per-ghost branches;
  # without this merge the validator diffed one branch and reported the
  # sibling ops' finished, type-checked work as "completely missing" —
  # three runs died at the validation wall staring at origin/main while
  # the feature sat in two branches (msn-807187, finding #17). Idempotent:
  # re-merging an already-merged branch is "Already up to date".
  #
  # A CONTENT conflict still completes that one merge with the markers
  # committed (run 13: aborting silently dropped whole branches — visible
  # markers beat invisible absence), but consolidation now STOPS at the
  # first conflicted merge. msn-7683ac proved the old merge-everything
  # policy diverges past two branches: each further union merge conflicts
  # against already-committed markers, nesting them (61 marker lines
  # through models.rs, five branches deep) until neither the fix loop nor
  # a human can reconcile the tree. One conflicted merge at a time is the
  # invariant; the caller spawns a FOCUSED resolution op for that single
  # merge and re-enters, and merged?/2 skips the resolved branch on the
  # next pass so the loop advances.
  #
  # Returns:
  #   {:ok, notes} — every branch merged AND the tree is marker-free.
  #     `notes` carries only UNMERGED-BRANCH entries (merge failed without
  #     content conflicts, run 21) for the validation prompt.
  #   {:conflict_pending, branch, files} — `branch` was merged with
  #     committed markers in `files`; no further branches were merged.
  #   {:conflict_pending, nil, files} — merges clean, but tracked files
  #     still carry markers (committed by an impl ghost, or missed by a
  #     prior resolution). Validation must never spend an attempt on
  #     either pending shape.
  @doc false
  def consolidate_impl_branches(mission, done_impl_ops) do
    # Target the CANONICAL worktree (chain tip; fix ops excluded from
    # selection — they adopt older shells and drag the target backward,
    # run 17's re-implementation spiral). The target branch is whatever
    # the canonical worktree currently has checked out — the deepest
    # point of the lineage including post-chain fix commits.
    with %{worktree_path: wt, ghost_id: target_ghost} <-
           GiTF.Validation.canonical_impl_shell(mission),
         true <- File.dir?(wt) do
      target_branch = GiTF.Validation.canonical_branch(mission) || "ghost/#{target_ghost}"

      # Validation/quality commands run in this same worktree between
      # rounds and leave tracked residue (lockfile rewrites, cache
      # touches). Merging over a dirty tree either sweeps the residue
      # into a merge commit or aborts with a false "local changes"
      # conflict — clear it first; all real work is already committed.
      case GiTF.Git.restore_tracked_residue(wt) do
        [] ->
          :ok

        residue ->
          Logger.info(
            "Quest #{mission.id}: reverted pre-consolidation residue: #{Enum.join(residue, ", ")}"
          )
      end

      branches =
        done_impl_ops
        # Resolution ops work IN the canonical worktree — they have no
        # sibling branch worth merging, and a stale ghost/<id> ref for one
        # would only add UNMERGED-BRANCH noise.
        |> Enum.reject(&(&1[:conflict_resolution] != nil))
        |> Enum.map(&{&1.id, &1[:ghost_id]})
        |> Enum.filter(fn {_id, g} -> is_binary(g) end)
        |> Enum.map(fn {id, g} -> {id, "ghost/" <> g} end)
        |> Enum.uniq_by(&elem(&1, 1))
        |> Enum.reject(fn {_id, b} -> b == target_branch end)
        # Skip branches already contained in this tree. Consolidation runs
        # on EVERY validation round, and re-merging a branch whose commits
        # are already present re-injected the same conflict markers the fix
        # loop had just reconciled — run 32 burned its whole budget
        # resolving Settings.ts, then MainApp.tsx, then Settings.ts again.
        |> Enum.reject(fn {_id, b} -> GiTF.Git.merged?(wt, b) end)

      result =
        Enum.reduce_while(branches, {:ok, []}, fn {op_id, branch}, {:ok, notes} ->
          # Op state can change between the phase snapshot and this merge.
          # Run 3's tree was poisoned by a quality-fix branch merged in the
          # window around its audit rejection — a rejected or failed
          # lineage must never enter the tree, so re-read at the moment of
          # merge, from the authoritative record.
          if not fresh_mergeable?(op_id) do
            Logger.info(
              "Quest #{mission.id}: skipping #{branch} — op #{op_id} is no longer " <>
                "done/verified at merge time"
            )

            {:cont, {:ok, notes}}
          else
            consolidate_one_branch(mission, wt, target_branch, branch, notes)
          end
        end)

      # The marker GATE: even when every merge came back clean, the tree may
      # carry markers an impl ghost committed or a prior resolution missed.
      # Validation must never spend one of its four attempts on a tree that
      # a text scan already convicts. FULL-tree scan: run 3's leftover
      # markers hid in a rejected op's files, which a changed-files scope
      # excluded — and false positives are survivable now that cap
      # exhaustion defers to ground-truth validation instead of failing.
      with {:ok, notes} <- result do
        case GiTF.Git.conflict_marker_files(wt) do
          [] -> {:ok, Enum.uniq(notes)}
          files -> {:conflict_pending, nil, files}
        end
      end
    else
      _ -> {:ok, []}
    end
  rescue
    e ->
      Logger.warning(
        "consolidate_impl_branches crashed for #{mission.id}: #{Exception.message(e)}"
      )

      {:ok, []}
  end

  # Op status re-read at the moment of merge — the phase snapshot can be
  # minutes old, and a lineage rejected in between must stay out.
  defp fresh_mergeable?(op_id) do
    case Archive.get(:ops, op_id) do
      %{status: "done"} = op -> op[:verification_status] not in ["failed", "rejected"]
      _ -> false
    end
  end

  defp consolidate_one_branch(mission, wt, target_branch, branch, notes) do
    case GiTF.Git.merge_union(wt, branch) do
      :ok ->
        Logger.info("Quest #{mission.id}: consolidated #{branch} into #{target_branch}")
        {:cont, {:ok, notes}}

      {:conflicted, files} ->
        # Generated files are not worth reconciling: both sides are
        # machine output from the same source of truth, so the merge
        # is meaningless and the regenerator is authoritative. Run 32
        # burned rounds hand-merging src/bindings/Settings.ts, which
        # `npm run bindings` rewrites wholesale from the Rust structs.
        {generated, human} = Enum.split_with(files, &generated_file?/1)
        regenerated = if generated == [], do: [], else: regenerate(wt, generated)
        unresolved = human ++ (generated -- regenerated)

        if regenerated != [] do
          Logger.info(
            "Quest #{mission.id}: regenerated #{Enum.join(regenerated, ", ")} " <>
              "instead of merging machine output"
          )
        end

        if unresolved == [] do
          # Every conflict was machine output and the regenerator
          # already replaced it — nothing left for a resolution ghost.
          {:cont, {:ok, notes}}
        else
          Logger.warning(
            "Quest #{mission.id}: merge of #{branch} conflicted in " <>
              "#{Enum.join(unresolved, ", ")} — markers committed; consolidation " <>
              "HALTED for a focused resolution op (never merge onto markers)"
          )

          {:halt, {:conflict_pending, branch, unresolved}}
        end

      {:error, out} ->
        reason = out |> to_string() |> String.trim() |> String.slice(0, 200)

        Logger.warning(
          "Quest #{mission.id}: consolidation merge of #{branch} failed without " <>
            "content conflicts (#{reason}) — branch NOT merged; surfacing to validation"
        )

        # A dropped branch must be as visible as a conflicted file:
        # run 21's final fix branch aborted here with an empty reason
        # and validation judged a tree silently missing that work.
        # This synthetic entry rides the merge_conflicts list into the
        # validation prompt so the fix loop knows work is absent.
        {:cont,
         {:ok,
          notes ++
            [
              "UNMERGED BRANCH #{branch} (merge failed: #{reason}) — its commits are " <>
                "missing from this tree; merge it or re-apply its work"
            ]}}
    end
  end

  # Files whose content is emitted by a generator, never hand-authored.
  @generated_patterns [~r{/bindings/.*\.ts$}, ~r{\.generated\.}, ~r{/__generated__/}]

  defp generated_file?(path) do
    Enum.any?(@generated_patterns, &Regex.match?(&1, path))
  end

  # Re-run the sector's generator and stage the result. Returns the files
  # it actually rewrote; anything left is handed back to the fix loop.
  defp regenerate(worktree, files) do
    case GiTF.Sandbox.wrap_shell("npm run bindings", cd: worktree) do
      {cmd, args} ->
        case System.cmd(cmd, args, cd: worktree, stderr_to_stdout: true) do
          {_, 0} ->
            still_conflicted =
              Enum.filter(files, fn f ->
                case File.read(Path.join(worktree, f)) do
                  {:ok, body} -> String.contains?(body, "<<<<<<<")
                  _ -> true
                end
              end)

            resolved = files -- still_conflicted

            if resolved != [] do
              GiTF.Git.safe_cmd(["-C", worktree, "add" | resolved], stderr_to_stdout: true)

              GiTF.Git.safe_cmd(
                ["-C", worktree, "commit", "-m", "gitf: regenerate bindings after consolidation"],
                stderr_to_stdout: true
              )
            end

            resolved

          _ ->
            []
        end
    end
  rescue
    _ -> []
  end

  # -- Archival ----------------------------------------------------------------

  @doc """
  The branch a failed mission's final tree is preserved under.
  """
  @spec archive_branch(String.t()) :: String.t()
  def archive_branch(mission_id), do: GiTF.Git.archive_branch_prefix() <> mission_id

  @doc """
  Preserves the mission's canonical tree as `archive/<mission_id>` in the
  SECTOR CLONE, before anything prunes the worktrees it lives in.

  Worktrees share the repository's ref store, so a ghost branch created
  inside `sector/ghosts/<ghost_id>` is already visible to `git branch` run
  in `sector.path` — the archive ref needs no worktree of its own and
  survives the worktree's removal.

  Called from the failure paths (`Missions.fail_quest/2`, `Missions.kill/1`)
  and never allowed to break them: every error is logged and swallowed. A
  mission that failed must still be recorded as failed even if its repo is
  gone.

  Returns `{:ok, branch}`, or `{:error, reason}` for callers that care
  (`GiTF.Missions.resume/2` reads the branch back, so its absence is a real
  error THERE — just not here).
  """
  @spec archive_canonical_branch(String.t() | map()) :: {:ok, String.t()} | {:error, term()}
  def archive_canonical_branch(mission_id) when is_binary(mission_id) do
    case GiTF.Missions.get(mission_id) do
      {:ok, mission} -> archive_canonical_branch(mission)
      _ -> {:error, :mission_not_found}
    end
  end

  def archive_canonical_branch(%{id: mission_id} = mission) do
    with {:ok, path} <- sector_path(mission),
         {:ok, tip} <- canonical_tip_branch(mission) do
      archive = archive_branch(mission_id)

      case GiTF.Git.branch_at(path, archive, tip) do
        :ok ->
          Logger.info("Quest #{mission_id}: preserved #{tip} as #{archive} in #{path}")
          {:ok, archive}

        {:error, out} ->
          Logger.warning("Quest #{mission_id}: could not archive #{tip} as #{archive}: #{out}")
          {:error, out}
      end
    end
  rescue
    e ->
      Logger.warning(
        "Quest #{Map.get(mission, :id)}: branch archival crashed: #{Exception.message(e)}"
      )

      {:error, :archive_crashed}
  end

  def archive_canonical_branch(_), do: {:error, :mission_not_found}

  defp sector_path(mission) do
    with sector_id when is_binary(sector_id) <- Map.get(mission, :sector_id),
         %{path: path} when is_binary(path) <- Archive.get(:sectors, sector_id),
         true <- File.dir?(path) do
      {:ok, path}
    else
      _ -> {:error, :sector_unavailable}
    end
  end

  # The deepest point of the mission's lineage. Deliberately NOT
  # `impl_base_branch_opts/1`: its last fallback is the amend-mission's
  # target_branch (the PR head), and archiving THAT would file somebody
  # else's branch under this mission's failure.
  defp canonical_tip_branch(mission) do
    case GiTF.Validation.canonical_branch(mission) do
      branch when is_binary(branch) ->
        {:ok, branch}

      _ ->
        case GiTF.Validation.latest_completed_impl_op(mission) do
          %{ghost_id: ghost_id} when is_binary(ghost_id) -> {:ok, "ghost/#{ghost_id}"}
          _ -> {:error, :no_canonical_branch}
        end
    end
  end

  # -- Teardown ----------------------------------------------------------------

  # Deletes the mission branch ONLY when sync strategy is auto_merge (the
  # branch has been merged into main and has no open PR pointing at it).
  # For pr_branch strategy, the branch must stay until the PR is
  # merged/closed — deleting it would orphan or close the PR.
  @doc false
  def maybe_delete_mission_branch(mission_id, sector) do
    strategy = Map.get(sector, :sync_strategy) || "auto_merge"

    with true <- strategy == "auto_merge",
         sync_art when is_map(sync_art) <- GiTF.Missions.get_artifact(mission_id, "sync"),
         branch when is_binary(branch) <- sync_art["branch"] do
      GiTF.Git.branch_delete(sector.path, branch)

      GiTF.Git.safe_cmd(["push", "origin", "--delete", branch],
        cd: sector.path,
        stderr_to_stdout: true
      )

      Logger.info("Cleaned up mission branch #{branch} (auto_merge completed)")
    else
      _ -> :ok
    end
  end
end
