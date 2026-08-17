defmodule GiTF.Validation do
  @moduledoc """
  Validation lifecycle domain — the verdict cross-check, stale-artifact
  detection, fix-context retry, and skill-refinement kicks that drive
  the implementation → validation → fix-implementation loop.

  Public surface:

    * `handle_result/1` — legacy advance-loop entry. Inspects the
      current validation artifact and either:
      * marks pass and routes to `awaiting_approval` / merge,
      * overrides a hallucinated pass when no impl ops produced files,
      * re-validates a stale artifact, or
      * attempts a fix (or fails the mission when the fix budget is
        exhausted).
    * `validate_pass_against_diff/1` — cross-check the validator's
      "pass" claim against the impl ops' actual file changes.
    * `emit_confidence/1` — telemetry + warning when validation took
      many rounds.
    * `latest_completed_impl_op/1` — most recent non-phase-job op the
      mission has finished. Used to detect a stale validation artifact.
    * `artifact_stale?/3` — true when the latest impl op finished after
      the validation artifact was written.
    * `load_fix_context/1` — read (or initialise) the
      `GiTF.Togusa.FixContext` for a mission, honouring sector
      intelligence's `max_validation_fix_attempts` recommendation.
    * `maybe_spawn_skill_refinement/2` — async skill refiner kick under
      the `:skill_refinement_enabled` flag.
    * `attempt_fixes/3` — record the attempt, persist the fix context,
      spawn a fix op (reusing the impl shell when possible), transition
      back to implementation.

  Both the legacy orchestrator dispatch path (`advance_via_legacy/2`) and the workflow
  phase handler `GiTF.Phases.Validation` call into this module.
  `start_validation/1` (the ghost-spawning entry point) stays on the
  orchestrator because it shares `spawn_phase_ghost/4` with every other
  phase starter; this module reaches it via the public
  `dispatch_phase/2` API.
  """

  require Logger

  alias GiTF.{Archive, Missions, Telemetry, Togusa}
  alias GiTF.Major.Orchestrator
  alias GiTF.Togusa.FixContext

  @doc """
  Returns the deduped list of files reported as changed by the
  mission's implementation ops (`:files_changed` / `:changed_files`
  fields). Reads non-phase ops only.

  `:completed_only` (default `false`) restricts to ops with
  `status == "done"`; the validation prompt builder uses this to
  ensure the "implementation definitely committed work" ground truth
  excludes in-flight ops. Other callers (simplify worktree base,
  Validation.attempt_fixes/3 fix targeting) want the full list.
  """
  @spec mission_changed_files(map(), keyword()) :: [String.t()]
  def mission_changed_files(mission, opts \\ []) do
    completed_only? = Keyword.get(opts, :completed_only, false)

    mission.ops
    |> Enum.reject(& &1[:phase_job])
    |> maybe_filter_done(completed_only?)
    |> Enum.flat_map(fn op ->
      case Map.get(op, :files_changed) || Map.get(op, :changed_files) do
        files when is_list(files) -> files
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp maybe_filter_done(ops, false), do: ops
  defp maybe_filter_done(ops, true), do: Enum.filter(ops, &(&1.status == "done"))

  # Sector-intelligence recommendations override this default at :high
  # confidence — see `max_fix_attempts_for/1`.
  @default_max_fix_attempts 2

  @doc """
  Legacy advance-loop entry for the validation phase. Thin shim over
  `GiTF.Phases.Validation.verdict/2`: that module owns the decision
  tree (pass/wait/terminal_fail) and the side effects (cross-check
  override, refinement, attempt_fixes, dispatch_phase on stale).
  This function just maps the verdict atom to the legacy driver's
  terminal calls (`Approval.request`, `Publish.merge`, `fail_quest`)
  that the workflow path handles via `on_pass:` routing rules and
  `terminal/3`.

  Returns `{:ok, phase}` for advance-loop callers.
  """
  @spec handle_result(map()) :: {:ok, String.t()} | {:error, term()}
  def handle_result(mission) do
    artifact = Missions.get_artifact(mission.id, "validation")

    case GiTF.Phases.Validation.verdict(mission, artifact) do
      :pass ->
        # verdict_single stamped `requires_approval` into the artifact;
        # read the fresh copy to route.
        stamped = Missions.get_artifact(mission.id, "validation") || %{}

        if Map.get(stamped, "requires_approval", false) do
          GiTF.Approval.request(mission)
        else
          GiTF.Publish.merge(mission)
        end

      :terminal_fail ->
        fix_ctx = load_fix_context(mission)

        Missions.fail_quest(
          mission.id,
          "Ghost lost in the net — validation failed after #{fix_ctx.attempt} attempts"
        )

      _ ->
        # :wait | :inconclusive — keep polling.
        {:ok, "validation"}
    end
  end

  @doc """
  Spawns an async skill-refinement task under TaskSupervisor when
  `:skill_refinement_enabled` is on. Non-blocking — refinement runs
  independently of the main pipeline, so a slow refiner LLM call or
  critic rejection never delays the orchestrator's next tick.
  """
  @spec maybe_spawn_skill_refinement(map(), map()) :: :ok
  def maybe_spawn_skill_refinement(mission, validation) do
    if Application.get_env(:gitf, :skill_refinement_enabled, false) do
      applied = GiTF.Skills.Refinement.applied_skill_ids(mission)

      Task.Supervisor.start_child(GiTF.TaskSupervisor, fn ->
        GiTF.Skills.Refinement.refine_after_validation(mission, validation, applied)
      end)

      :ok
    else
      :ok
    end
  rescue
    e ->
      Logger.debug("maybe_spawn_skill_refinement failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Returns `:ok` when at least one impl op committed at least one file
  outside `.claude/` (which the auto-commit step always adds). Otherwise
  returns `{:error, reason}` so the caller can override a hallucinated
  "pass" verdict.
  """
  @spec validate_pass_against_diff(map()) :: :ok | {:error, String.t()}
  def validate_pass_against_diff(mission) do
    impl_ops =
      mission.ops
      |> Enum.filter(fn op ->
        op.status == "done" and op[:phase_job] in [nil, false]
      end)

    cond do
      impl_ops == [] ->
        {:error, "no completed impl ops"}

      true ->
        meaningful_files =
          impl_ops
          |> Enum.flat_map(fn op ->
            (op[:changed_files] || [])
            |> Enum.reject(&claude_settings_path?/1)
          end)
          |> Enum.uniq()

        cond do
          meaningful_files == [] ->
            total_changed =
              impl_ops |> Enum.map(&(&1[:files_changed] || 0)) |> Enum.sum()

            {:error,
             "impl ops total #{total_changed} files changed but all are " <>
               "`.claude/` settings — no real code changes"}

          true ->
            validate_against_lsp_errors(mission, meaningful_files)
        end
    end
  end

  @doc """
  Returns the deduped list of meaningful (non-`.claude/`) files
  reported as changed by completed impl ops. Public so prompt builders
  and the validation phase handler can render the same list the
  cross-check operates over.
  """
  @spec changed_code_files(map()) :: [String.t()]
  def changed_code_files(mission) do
    mission.ops
    |> Enum.filter(fn op ->
      op.status == "done" and op[:phase_job] in [nil, false]
    end)
    |> Enum.flat_map(fn op ->
      (op[:changed_files] || [])
      |> Enum.reject(&claude_settings_path?/1)
    end)
    |> Enum.uniq()
  end

  # Gated cross-check: when :lsp_validation_enabled is on, ask the LSP
  # server about the diff'd files. Any error-severity diagnostic
  # overrides a "pass" verdict the same way the meaningful-files
  # check does — the impl ghost shouldn't get a green light if the
  # code it just committed doesn't compile.
  defp validate_against_lsp_errors(mission, files) do
    if Application.get_env(:gitf, :lsp_validation_enabled, false) do
      case GiTF.LSP.collect_errors(mission.sector_id, files) do
        {:ok, []} ->
          :ok

        {:ok, file_errors} ->
          summary =
            file_errors
            |> Enum.map_join("; ", fn {file, errs} ->
              "#{file}: #{length(errs)} error(s)"
            end)

          {:error, "LSP diagnostics show compile errors — #{summary}"}

        {:error, _reason} ->
          # LSP unavailable / sector unknown — fall back to the
          # pre-LSP behaviour (cross-check passes on the existing
          # meaningful-files signal alone). Logged for visibility but
          # not enforced; flipping the flag on shouldn't break
          # environments without ElixirLS.
          :ok
      end
    else
      :ok
    end
  end

  defp claude_settings_path?(path) when is_binary(path) do
    String.starts_with?(path, ".claude/") or String.contains?(path, "/.claude/")
  end

  defp claude_settings_path?(_), do: false

  @doc """
  Counts the completed validation ops and emits a telemetry signal. When
  validation passed on the first run, we're confident. When it took 3+
  validation runs interspersed with fix-ops, validation was likely
  flip-flopping — log at warning so operators notice the drift.
  """
  @spec emit_confidence(map()) :: :ok
  def emit_confidence(mission) do
    validation_runs =
      Enum.count(mission.ops, fn op ->
        (op[:phase_job] && Map.get(op, :phase) == "validation") and op.status == "done"
      end)

    Telemetry.emit([:gitf, :validation, :passed], %{runs: validation_runs}, %{
      mission_id: mission.id,
      sector_id: mission.sector_id,
      first_try: validation_runs <= 1
    })

    if validation_runs >= 3 do
      Logger.warning(
        "Quest #{mission.id}: validation passed after #{validation_runs} runs — " <>
          "likely indecisive validator or fix-ops chasing its tail"
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("emit_confidence failed for #{mission.id}: #{Exception.message(e)}")

      :ok
  end

  @doc """
  Most recent non-phase-job op for a mission with status `"done"`, or
  `nil` if there isn't one yet.
  """
  @spec latest_completed_impl_op(map()) :: map() | nil
  def latest_completed_impl_op(mission) do
    mission.ops
    |> Enum.reject(& &1[:phase_job])
    |> Enum.filter(&(&1.status == "done"))
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> List.first()
  end

  @doc """
  The mission's CANONICAL worktree shell: the latest completed CHAIN op's
  (fix ops excluded) shell, with a live worktree directory.

  This — not `latest_completed_impl_op/1` — is the target every worktree
  consumer (consolidation, validation base, fix-ghost spawn) must use.
  Fix ghosts ADOPT older shells, then become the "latest completed op"
  themselves: on run 17 that dragged the consolidation target back to
  chain-op 2's worktree, the fix ghost re-implemented work that already
  existed at the true tip, and the union manufactured a fresh wall of
  conflict markers. Chain ops never adopt, so their newest shell is
  always the true tip.

  Returns the shell record or nil.
  """
  @spec canonical_impl_shell(map()) :: map() | nil
  def canonical_impl_shell(mission) do
    mission.ops
    |> Enum.reject(& &1[:phase_job])
    |> Enum.reject(&is_binary(&1[:fix_of]))
    |> Enum.filter(&(&1.status == "done" and is_binary(&1[:ghost_id])))
    |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
    |> Enum.find_value(fn op ->
      with %{shell_id: shell_id} when is_binary(shell_id) <-
             Archive.get(:ghosts, op.ghost_id),
           %{worktree_path: wt} = shell <- Archive.get(:shells, shell_id),
           true <- is_binary(wt) and File.dir?(wt) do
        shell
      else
        _ -> nil
      end
    end)
  end

  @doc """
  The canonical worktree's CURRENT branch — the deepest point of the
  mission's single lineage, including any fix commits made after the
  chain finished. Basing validation on an op-derived branch name misses
  fix work; the worktree's HEAD never does.
  """
  @spec canonical_branch(map()) :: String.t() | nil
  def canonical_branch(mission) do
    with %{worktree_path: wt} <- canonical_impl_shell(mission),
         {out, 0} <-
           GiTF.Git.safe_cmd(["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"],
             stderr_to_stdout: true
           ),
         branch when branch != "" and branch != "HEAD" <- String.trim(to_string(out)) do
      branch
    else
      _ -> nil
    end
  end

  @doc """
  Is a validation artifact older than the latest completed impl op? If
  so, a fix ghost has run since this validation, and the verdict on
  this artifact is moot — the caller should re-validate.

  The third arg accepts either a mission record (preferred — saves a
  fetch) or a mission id binary.
  """
  @spec artifact_stale?(map() | nil, map(), map() | String.t()) :: boolean()
  def artifact_stale?(nil, _validation, _mission_or_id), do: false

  def artifact_stale?(latest_impl, _validation, %{ops: ops}) do
    last_validation_op =
      ops
      |> Enum.filter(&(&1[:phase] == "validation" and &1.status == "done"))
      |> Enum.sort_by(& &1[:inserted_at], {:desc, DateTime})
      |> List.first()

    case {latest_impl[:inserted_at], last_validation_op && last_validation_op[:inserted_at]} do
      {%DateTime{} = impl_at, %DateTime{} = val_at} ->
        DateTime.compare(impl_at, val_at) == :gt

      _ ->
        false
    end
  end

  def artifact_stale?(latest_impl, validation, mission_id) when is_binary(mission_id) do
    case Missions.get(mission_id) do
      {:ok, mission} -> artifact_stale?(latest_impl, validation, mission)
      _ -> false
    end
  end

  @doc """
  Read the persisted `GiTF.Togusa.FixContext` for the mission, or
  initialise a fresh one with the sector-aware max-attempt budget.
  """
  @spec load_fix_context(map()) :: FixContext.t()
  def load_fix_context(mission) do
    case Map.get(mission, :fix_context) do
      nil ->
        FixContext.new(mission.id, max_attempts: max_fix_attempts_for(mission.sector_id))

      ctx_map ->
        FixContext.from_map(ctx_map) ||
          FixContext.new(mission.id, max_attempts: max_fix_attempts_for(mission.sector_id))
    end
  end

  @doc """
  Spawn a fix op for `mission` driven by the validation feedback in
  `validation`. Reuses an existing implementation shell's worktree when
  possible so the fix ghost inherits the prior implementation's diff.
  Otherwise spawns a fresh implementation op via the Major's job loop.

  Records the attempt in `fix_ctx`, persists it onto the mission,
  hands the failure to the agent-profile learner, and transitions the
  mission back to `"implementation"`.
  """
  @spec attempt_fixes(map(), map(), FixContext.t()) :: {:ok, String.t()} | {:error, term()}
  def attempt_fixes(mission, validation, %FixContext{} = fix_ctx) do
    if GiTF.Ops.worktree_writer_in_flight?(mission.id) do
      # Single fix lineage: never run two fix ghosts concurrently — the
      # in-flight fix's next validation round re-derives whatever remains.
      # Skipping BEFORE record_attempt keeps the budget unburned.
      Logger.info(
        "Quest #{mission.id}: fix op already in flight — deferring validation fix attempt"
      )

      {:ok, "implementation"}
    else
      do_attempt_fixes(mission, validation, fix_ctx)
    end
  end

  defp do_attempt_fixes(mission, validation, %FixContext{} = fix_ctx) do
    impl_files = mission_changed_files(mission)

    fix_description = build_fix_description(mission, validation, impl_files)

    fix_ctx =
      FixContext.record_attempt(
        fix_ctx,
        :goal_fulfillment,
        mission.id,
        validation,
        fix_description
      )

    store_fix_context(mission.id, fix_ctx)
    learn_from_failure(mission, validation)

    shell = find_implementation_shell(mission)

    history_prompt = FixContext.format_for_prompt(fix_ctx)
    full_description = fix_description <> "\n" <> history_prompt

    fix_title = "Fix validation issues (attempt #{fix_ctx.attempt})"

    case GiTF.Ops.create(%{
           title: fix_title,
           description: full_description,
           mission_id: mission.id,
           sector_id: mission.sector_id,
           phase_job: false,
           skip_verification: false,
           fix_context: FixContext.to_map(fix_ctx),
           fix_of: fix_ctx.original_op_id,
           target_files: impl_files
         }) do
      {:ok, fix_op} ->
        Missions.transition_phase(
          mission.id,
          "implementation",
          "Validation fix attempt #{fix_ctx.attempt}"
        )

        if shell do
          spawn_fix_in_worktree(fix_op, shell, mission)
        else
          {:ok, mission} = Missions.get(mission.id)
          Orchestrator.spawn_implementation_jobs(mission)
        end

        {:ok, "implementation"}

      {:error, reason} ->
        Logger.warning("Quest #{mission.id}: failed to create fix op: #{inspect(reason)}")
        Missions.fail_quest(mission.id, "Could not create fix op")
    end
  rescue
    e ->
      Logger.error(
        "Validation fix attempt failed for mission #{mission.id}: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      Missions.fail_quest(
        mission.id,
        "Validation fix attempt crashed: #{Exception.message(e)}"
      )
  end

  # -- Internals --------------------------------------------------------------

  # Build a comprehensive fix description from validation findings.
  defp build_fix_description(_mission, validation, impl_files) do
    gaps = Map.get(validation, "gaps", [])

    unmet =
      (Map.get(validation, "requirements_met", []) || [])
      |> Enum.filter(fn r -> Map.get(r, "met") == false end)

    raw = Map.get(validation, "raw_output", "")
    summary = Map.get(validation, "summary", "")

    sections = ["## Validation Feedback\n"]

    sections =
      if unmet != [] do
        req_lines =
          Enum.map(unmet, fn req ->
            id = Map.get(req, "req_id", "?")
            evidence = Map.get(req, "evidence", "No details")
            files = extract_file_paths(evidence)
            file_hint = if files != [], do: " (#{Enum.join(files, ", ")})", else: ""
            "- **#{id}**: #{evidence}#{file_hint}"
          end)

        sections ++ ["### Unmet Requirements\n"] ++ req_lines ++ [""]
      else
        sections
      end

    sections =
      if gaps != [] do
        gap_lines = Enum.map(gaps, fn gap -> "- #{gap}" end)
        sections ++ ["### Gaps\n"] ++ gap_lines ++ [""]
      else
        sections
      end

    sections =
      if summary != "" do
        sections ++ ["### Summary\n", summary, ""]
      else
        sections
      end

    sections =
      if unmet == [] and gaps == [] and raw != "" do
        sections ++ ["### Raw Validator Output\n", String.slice(raw, 0, 2000), ""]
      else
        sections
      end

    sections =
      if impl_files != [] do
        sections ++ ["### Files Changed\n", Enum.join(impl_files, ", "), ""]
      else
        sections
      end

    instructions = """
    ## Instructions

    Your previous implementation was reviewed and the issues above were found.
    You are working in the SAME worktree with your previous changes still present.

    1. Review the feedback above carefully
    2. Read the specific files mentioned to understand what needs to change
    3. RECONCILE, don't duplicate: when feedback says something is "missing",
       FIRST search the codebase for an existing implementation under a
       different name, field, or location. If one exists, RENAME or REWIRE
       it to match — never add a second definition. Duplicate struct fields
       and duplicate functions are compile errors that have killed entire
       missions. Before adding ANY field, function, or component, grep for
       its concept first.
    4. Make the minimal fixes needed to address each issue
    5. Verify your fixes are correct — if a build/test command is available,
       RUN it; a fix that does not compile is not a fix
    6. Commit your changes
    """

    Enum.join(sections, "\n") <> "\n" <> instructions
  end

  # Extract file paths from text (looks for common patterns like
  # path/to/file.ext) so the fix description can hint at the right files.
  defp extract_file_paths(text) when is_binary(text) do
    regex = ~r/(?:^|[\s`'"])([a-zA-Z][\w.\/-]*\.\w{1,6})(?:[\s`'",:\]]|$)/

    Regex.scan(regex, text)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp extract_file_paths(_), do: []

  # Find a shell with an on-disk worktree from the mission's
  # implementation ops, preferring the most recent.
  @doc """
  Runs the sector's behavioral verification suite (holdout scenarios driven
  through the artifact's real interface) against the implementation worktree.

  Returns `:ok` when there is no profile, or all scenarios pass; `{:error,
  reason}` when any scenario fails or verification cannot complete (fail-safe
  — this only runs for sectors that explicitly opted in with a profile). The
  caller treats an error like the diff cross-check: override "pass" → fail and
  route back into the fix loop.
  """
  @spec verify_behavior(map()) :: :ok | {:error, String.t()}
  def verify_behavior(mission) do
    if GiTF.Verification.profile?(mission.sector_id) do
      case find_implementation_shell(mission) do
        %{worktree_path: path} -> run_behavioral(mission.sector_id, path)
        # No worktree to exercise — the diff cross-check already gated; don't
        # hard-fail on a missing worktree.
        _ -> :ok
      end
    else
      :ok
    end
  rescue
    e -> {:error, "behavioral verification error: #{Exception.message(e)}"}
  end

  defp run_behavioral(sector_id, path) do
    case GiTF.Verification.run(sector_id, path) do
      {:ok, %{passed: true}} ->
        :ok

      {:ok, %{passed: false, failures: failures}} ->
        summary =
          failures
          |> Enum.map_join("; ", fn f -> "#{f.name}: #{f.reasoning}" end)
          |> String.slice(0, 500)

        {:error, "behavioral verification failed — #{summary}"}

      :no_profile ->
        :ok
    end
  end

  # The fix ghost must work in the CANONICAL worktree — the chain tip's
  # shell (fix ops excluded from selection: they adopt older shells and
  # would drag the target backward, run 17's re-implementation spiral).
  defp find_implementation_shell(mission) do
    canonical_impl_shell(mission) || fallback_implementation_shell(mission)
  end

  defp fallback_implementation_shell(mission) do
    ghost_ids =
      mission.ops
      |> Enum.reject(& &1[:phase_job])
      |> Enum.map(& &1[:ghost_id])
      |> Enum.reject(&is_nil/1)

    ghost_ids
    |> Enum.reverse()
    |> Enum.find_value(fn ghost_id ->
      Archive.find_one(:shells, fn s ->
        s.ghost_id == ghost_id and
          s[:worktree_path] != nil and
          File.dir?(s.worktree_path)
      end)
    end)
  end

  # Spawn a fix ghost in an existing worktree so it inherits the
  # implementation's code. Falls back to the regular job-loop spawn if
  # the worktree spawn fails for any reason.
  defp spawn_fix_in_worktree(fix_op, shell, mission) do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        case GiTF.Ghosts.spawn_in_worktree(fix_op.id, shell.id, mission.sector_id, gitf_root) do
          {:ok, _ghost} -> :ok
          {:error, _} -> Orchestrator.spawn_implementation_jobs(mission)
        end

      _ ->
        Orchestrator.spawn_implementation_jobs(mission)
    end
  rescue
    _ -> Orchestrator.spawn_implementation_jobs(mission)
  end

  defp store_fix_context(mission_id, fix_ctx) do
    Archive.update(:missions, mission_id, fn record ->
      Map.put(record, :fix_context, FixContext.to_map(fix_ctx))
    end)

    :ok
  end

  defp learn_from_failure(mission, validation) do
    impl_op =
      (mission.ops || [])
      |> Enum.reject(& &1[:phase_job])
      |> Enum.max_by(& &1[:inserted_at], fn -> nil end)

    if impl_op do
      Togusa.learn_from_failure(impl_op.id, validation)
    end
  rescue
    e ->
      Logger.warning("learn_from_failure failed for #{mission.id}: #{Exception.message(e)}")

      :ok
  end

  # Max validation fix attempts: operator config first (hot-reloadable via
  # [validation] max_fix_attempts — run 9 died one fix cycle short of a
  # compiling feature), then sector intelligence at `:high` confidence,
  # then the default.
  defp max_fix_attempts_for(sector_id) do
    configured = GiTF.Config.Provider.get([:validation, :max_fix_attempts])

    cond do
      is_integer(configured) and configured >= 1 -> configured
      is_nil(sector_id) -> @default_max_fix_attempts
      true -> profile_fix_attempts(sector_id)
    end
  rescue
    _ -> @default_max_fix_attempts
  end

  defp profile_fix_attempts(sector_id) do
    profile = GiTF.Intel.SectorProfile.get_or_compute(sector_id)

    case profile do
      %{confidence: :high, recommendations: %{max_validation_fix_attempts: n}} -> n
      _ -> @default_max_fix_attempts
    end
  rescue
    _ -> @default_max_fix_attempts
  end
end
