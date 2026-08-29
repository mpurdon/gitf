defmodule GiTF.Major.Endgame do
  @moduledoc """
  THE ENDGAME — the post-consolidation convergence stage: everything
  between "all implementation branches merged" and "validation's verdict
  accepted". The full-tree marker scan, focused per-merge resolution ops,
  worktree-target sweeps, and the scan-vs-ghost adjudication that defers
  disagreements to ground-truth validation.

  Named because it kept killing missions while anonymous: runs 1-4 of the
  six-level-priority saga each died (or nearly died) here, in plumbing
  that lived unnamed inside the Orchestrator. The merge LOOP stays with
  the Orchestrator (`consolidate_impl_branches`); this module owns what
  happens when a merge does not come back clean.
  """

  require Logger

  alias GiTF.Archive

  # One focused ghost per conflicted merge, spawned into the canonical
  # worktree where the marker-laden merge commit sits. Deliberately
  # DISTINCT from the validation fix loop: resolution has its own small
  # per-target budget, consumes no validation attempts, and its prompt is
  # scoped to the marked regions of one merge — not "fix everything".
  # msn-7683ac's fix ghosts were handed 15 marker-laden files in two
  # languages plus the real validation gaps, four times, and diverged.
  @max_resolutions_per_target 2
  # Absolute per-target ceiling regardless of productivity — the
  # unattended-operation backstop against a converging-but-endless series.
  @max_total_resolutions_per_target 5

  def start_conflict_resolution(mission, branch, files) do
    target = branch || "worktree"

    # Fetched ONCE; the attempt count and the futile-prior check downstream
    # both derive from this list.
    resolution_ops =
      Archive.by_index(:ops, :mission_id, mission.id)
      |> Enum.filter(&(&1[:conflict_resolution] == target))

    # The cap counts FUTILE attempts only (failed/rejected, or done with
    # zero changes — which the completion gate now fails anyway). Run 4
    # spent the per-mission worktree budget on two early productive
    # episodes and had nothing left for the endgame. An absolute ceiling
    # stays as the unattended-operation backstop.
    futile = Enum.count(resolution_ops, &futile_resolution?/1)
    total = length(resolution_ops)

    cond do
      # Two DISTINCT policies, each with an honest record: futility (the
      # attempts change nothing) and the absolute ceiling (converging but
      # unbounded — the unattended-operation backstop). The first version
      # forged the futility counter to trip the cap, so a ceiling'd
      # mission's failure reason claimed "2 focused attempts" after 5
      # productive ones — a falsified post-mortem record.
      total >= @max_total_resolutions_per_target and is_nil(branch) ->
        Logger.warning(
          "Quest #{mission.id}: worktree resolution ceiling (#{total} attempts, " <>
            "#{futile} futile) — deferring to ground-truth validation"
        )

        {:cap_exhausted, files}

      total >= @max_total_resolutions_per_target ->
        snapshot_marker_artifact(mission, files)

        GiTF.Missions.fail_quest(
          mission.id,
          "Merge conflict resolution for #{target} hit the absolute ceiling: " <>
            "#{total} attempts (#{futile} futile) without a clean tree " <>
            "(files: #{Enum.join(Enum.take(files, 8), ", ")})"
        )

        {:error, :conflict_resolution_exhausted}

      futile >= @max_resolutions_per_target and is_nil(branch) ->
        # The scan and the resolution ghosts DISAGREE twice over: the regex
        # says markers, ghosts sent with exact line excerpts say clean and
        # change nothing. Run 2 died here — failing a multi-hour mission on
        # a lexical disagreement is the wrong direction. Ground truth
        # adjudicates: proceed to validation carrying the file list; if the
        # markers are real, typecheck/build names them and the fix loop has
        # them; if not, the mission lives.
        Logger.warning(
          "Quest #{mission.id}: worktree marker scan and #{futile} futile resolution ghosts " <>
            "disagree (#{Enum.join(files, ", ")}) — deferring to ground-truth validation"
        )

        {:cap_exhausted, files}

      futile >= @max_resolutions_per_target ->
        # A conflicted BRANCH merge is not ambiguous — those markers were
        # just committed by the merge itself. Two failed focused attempts
        # is genuine non-convergence. Snapshot the evidence first: the
        # worktrees (and their markers) are pruned when the mission seals.
        snapshot_marker_artifact(mission, files)

        GiTF.Missions.fail_quest(
          mission.id,
          "Merge conflict resolution for #{target} did not converge after " <>
            "#{futile} futile attempts (#{total} total) (files: #{Enum.join(Enum.take(files, 8), ", ")})"
        )

        # fail_quest returns {:ok, mission_map} — which the phase-advance
        # caller pattern-matches as a successful advance and keeps spawning
        # on a dead mission. Normalize the failure explicitly.
        {:error, :conflict_resolution_exhausted}

      GiTF.Ops.worktree_writer_in_flight?(mission.id) ->
        # Same single-lineage rule as the fix loop: one writer per
        # worktree. The in-flight writer's completion re-enters validation
        # and consolidation re-derives whatever is still pending.
        Logger.info(
          "Quest #{mission.id}: conflict resolution deferred — worktree writer in flight"
        )

        {:ok, "implementation"}

      true ->
        create_conflict_resolution_op(mission, branch, files, target, resolution_ops)
    end
  end

  defp marker_excerpt(mission, files) do
    case GiTF.Validation.canonical_impl_shell(mission) do
      %{worktree_path: wt} -> GiTF.Git.conflict_marker_excerpt(wt, files)
      _ -> []
    end
  end

  defp snapshot_marker_artifact(mission, files) do
    GiTF.Missions.store_artifact(mission.id, "conflict_markers", %{
      "files" => files,
      "excerpt" => marker_excerpt(mission, files)
    })
  rescue
    e -> Logger.warning("Quest #{mission.id}: marker snapshot failed: #{Exception.message(e)}")
  end

  defp futile_resolution?(op) do
    op.status in ["failed", "rejected"] or
      (op.status == "done" and (op[:files_changed] || 0) == 0)
  end

  defp create_conflict_resolution_op(mission, branch, files, target, resolution_ops) do
    total = length(resolution_ops)
    excerpt = marker_excerpt(mission, files)

    # Run 3: resolution ops completed "done" having changed NOTHING while
    # the markers stayed put. If that happened here, say so — the next
    # ghost must not repeat the same shallow look and conclude clean.
    futile_note =
      if Enum.any?(
           resolution_ops,
           &futile_resolution?/1
         ) do
        "\nWARNING: a previous resolution op for this target completed WITHOUT " <>
          "changing any files, yet the markers above are still present at the " <>
          "exact lines listed. They are REAL. Open each location and reconcile it; " <>
          "do not conclude the tree is clean without editing.\n"
      else
        ""
      end

    case GiTF.Ops.create(%{
           title: "Resolve merge conflicts: #{target}",
           description: resolution_description(branch, files, excerpt) <> futile_note,
           mission_id: mission.id,
           sector_id: mission.sector_id,
           phase_job: false,
           # Mission-level validation gates the final tree; running the full
           # sector validation per resolution op would double-charge it.
           skip_verification: true,
           conflict_resolution: target,
           target_files: files
         }) do
      {:ok, op} ->
        GiTF.Missions.transition_phase(
          mission.id,
          "implementation",
          "Merge conflict resolution: #{target} (attempt #{total + 1})"
        )

        Logger.info(
          "Quest #{mission.id}: spawned resolution op #{op.id} for #{target} " <>
            "(#{length(files)} conflicted files)"
        )

        spawn_resolution_in_worktree(mission, op)
        {:ok, "implementation"}

      {:error, reason} ->
        Logger.error(
          "Quest #{mission.id}: could not create conflict-resolution op: #{inspect(reason)}"
        )

        GiTF.Missions.fail_quest(mission.id, "Could not create conflict-resolution op")
    end
  end

  # The resolution must run where the markers are: the canonical worktree.
  # Falling back to standard dispatch would hand the op a FRESH worktree
  # branched before the conflicted merge — resolving nothing.
  defp spawn_resolution_in_worktree(mission, op) do
    with %{id: shell_id} <- GiTF.Validation.canonical_impl_shell(mission),
         {:ok, gitf_root} <- GiTF.gitf_dir(),
         {:ok, _ghost} <-
           GiTF.Ghosts.spawn_in_worktree(op.id, shell_id, mission.sector_id, gitf_root) do
      :ok
    else
      other ->
        Logger.error(
          "Quest #{mission.id}: could not spawn resolution ghost into the canonical " <>
            "worktree (#{inspect(other)}) — op #{op.id} stays pending for the recovery sweep"
        )

        :error
    end
  end

  defp resolution_description(branch, files, excerpt) do
    source =
      if branch,
        do: "a union merge of branch `#{branch}`",
        else: "earlier commits in this worktree"

    excerpt_section =
      case excerpt do
        [] ->
          ""

        lines ->
          """

          Exact marker locations at the time this op was created
          (`file:line:content`):

          #{Enum.map_join(lines, "\n", &("    " <> &1))}
          """
      end

    """
    This worktree contains COMMITTED merge-conflict markers left by #{source}.
    Your only job is to reconcile those markers. Files with markers:

    #{Enum.map_join(files, "\n", &("- " <> &1))}
    #{excerpt_section}

    Rules:
    - Both sides of every conflict carry wanted work. Produce the correct
      combined code; do not discard either side's functionality.
    - Remove every `<<<<<<<`, `|||||||`, `=======`, `>>>>>>>` marker line.
    - Do not add features, do not refactor, do not touch files that have no
      markers.
    - If a conflicted file is a GENERATED artifact (e.g. src/bindings/*.ts
      from ts-rs), reconcile its source instead and regenerate it with the
      project's generator (e.g. `npm run bindings`) rather than hand-editing
      machine output.
    - If a marker-like line is intentional file content (a test fixture or a
      documentation example), leave it exactly as-is and say so.
    - After reconciling, the files you touched must be syntactically valid —
      run the cheapest applicable check (typecheck/build) if the toolchain
      allows.
    - Commit the resolution.
    """
  end

  # The branch a mission is amending, when it is amending one. Callers use it
  # as the base for worktrees so ghosts see the code under review.
end
