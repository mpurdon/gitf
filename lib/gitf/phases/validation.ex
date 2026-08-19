defmodule GiTF.Phases.Validation do
  @moduledoc """
  Validation phase handler — faithful mirror of
  `GiTF.Validation.handle_result/1`.

  Validation is the most state-dependent phase: pass/fail isn't a simple
  read of `artifact["overall_verdict"]` because legacy applies a
  diff-cross-check, a stale-artifact re-validation pass, a fix-budget
  retry loop (via `Togusa.FixContext`), and a requires-approval routing
  decision. `verdict/2` does all of it via side effects on the artifact
  + the legacy primitives (now exposed as `@doc false def` on
  `Orchestrator`); the YAML stays declarative.

  `verdict/1` (artifact-only) remains the simple `overall_verdict`
  → pass/fail/inconclusive reading used by the generic
  `Workflow.Verdict` path and by operator-authored workflows that only
  want a thin validation handler.

  ## verdict/2 logic, by case

    * `artifact == nil` → `:wait` (no validation ghost has completed yet).

    * `overall_verdict == "pass"`:
      * Emits `[:gitf, :validation, :passed]` telemetry
        (`emit_validation_confidence/1`).
      * Runs `validate_pass_against_diff/1`. On `:ok`, kicks
        `maybe_spawn_skill_refinement/2` and stamps
        `artifact.requires_approval` (from
        `GiTF.Override.requires_approval?/1`) so the conditional
        `on_pass:` rule routes between `awaiting_approval` and `sync`.
        Returns `:pass`.
      * On cross-check failure, overrides the artifact with
        `overall_verdict="fail"`, a `gaps` entry, and a
        `cross_check_override` reason — matching the legacy "validator
        said pass but no impl commits" override — and recursively
        re-runs the verdict on the overridden artifact (which falls
        into the fail branch). Emits
        `[:gitf, :validation, :pass_overridden]` telemetry.

    * `overall_verdict != "pass"` (fail or overridden):
      * Stale artifact (latest impl op completed after the last
        validation op) → re-spawn a fresh validation ghost via
        `start_validation/1` and return `:wait`. The new ghost's
        artifact drives the next verdict pass.
      * Fix-context exhausted → `:terminal_fail`. `terminal/3` runs
        `maybe_spawn_skill_refinement/2` and `fail_quest` with the
        "Ghost lost in the net" reason.
      * Otherwise → kick `maybe_spawn_skill_refinement/2` and
        `attempt_validation_fixes/3` (spawns a fix-implementation
        ghost), then `:wait`. The next poll cycle sees the validation
        artifact go stale, re-spawns validation, and the loop continues.

  ## Workflow YAML

      - id: validation
        handler: GiTF.Phases.Validation
        on_pass:
          - when: "artifact.requires_approval == true"
            then: awaiting_approval
          - else: sync
        on_fail: validation        # never fires — verdict/2 only returns
        max_retries: 0             # :pass / :wait / :terminal_fail
        on_exhausted: fail

  `on_fail:` is required by the schema even though `verdict/2` never
  returns the `:fail` verdict; the self-loop is unreachable in
  practice.
  """

  @behaviour GiTF.Phase

  require Logger

  alias GiTF.{Major.Orchestrator, Missions, Validation}
  alias GiTF.Togusa.FixContext

  @impl true
  def start(mission, %GiTF.Workflow.Phase{id: id}, _ctx) do
    Orchestrator.dispatch_phase(id, mission)
  end

  # 1-arg verdict — the simple `overall_verdict` reading, kept so the
  # generic `Workflow.Verdict.verdict_for("validation", _)` path and any
  # operator-authored workflow using this handler without the rich
  # legacy machinery still works.
  @impl true
  def verdict(artifact) when is_map(artifact) do
    case verdict_field(artifact) do
      v when v in ["pass", "passed"] -> :pass
      v when v in ["fail", "failed"] -> :fail
      _ -> :inconclusive
    end
  end

  def verdict(_), do: :inconclusive

  # 2-arg verdict — the full faithful port of handle_validation_result/1.
  # Tournament mode (mission.impl_variants != []) short-circuits ahead of
  # the single-variant artifact-driven path: each variant has its own
  # `validation_<id>` artifact, and the verdict is driven by
  # `GiTF.Tournament` instead of a single `validation` key.
  @impl true
  def verdict(mission, _artifact) when is_map(mission) do
    cond do
      # Tournament already resolved — winner_variant stamped; stay on the
      # single-variant path so subsequent polls don't re-run the
      # tournament.
      is_binary(Map.get(mission, :winning_variant)) ->
        verdict_single(mission, Missions.get_artifact(mission.id, "validation"))

      (Map.get(mission, :impl_variants) || []) != [] ->
        verdict_tournament(mission)

      true ->
        verdict_single(mission, Missions.get_artifact(mission.id, "validation"))
    end
  end

  defp verdict_tournament(mission) do
    case GiTF.Tournament.resolve(mission) do
      {:ok, winning_variant} ->
        promote_winning_variant(mission, winning_variant)

      {:error, :not_ready} ->
        :wait

      {:error, :all_disqualified} ->
        Logger.warning(
          "Quest #{mission.id}: all #{length(mission.impl_variants)} variants disqualified"
        )

        :terminal_fail

      # impl_variants was populated when the dispatcher checked but
      # came back empty here (race against an Archive update). Wait
      # and retry.
      {:error, :no_variants} ->
        :wait
    end
  end

  defp promote_winning_variant(mission, winning_variant) do
    winner_artifact =
      Missions.get_artifact(mission.id, GiTF.Tournament.validation_key(winning_variant)) || %{}

    # Store the artifact BEFORE stamping `winning_variant` so the
    # tournament short-circuit at verdict/2 (which keys off
    # winning_variant) never sees a stamp without a canonical artifact
    # to consume. A crash between the two writes would leave the next
    # poll re-running this path and producing the same result.
    Missions.store_artifact(mission.id, "validation", winner_artifact)

    GiTF.Archive.update(:missions, mission.id, fn record ->
      Map.put(record, :winning_variant, winning_variant)
    end)

    Logger.info(
      "Quest #{mission.id}: tournament winner = #{winning_variant} " <>
        "(score breakdown via GiTF.Tournament.rank/1)"
    )

    GiTF.Telemetry.emit([:gitf, :validation, :tournament_winner], %{}, %{
      mission_id: mission.id,
      winner: winning_variant,
      variant_count: length(mission.impl_variants)
    })

    # Fall through to the single-variant verdict path on the now-canonical
    # validation artifact. Update the in-memory mission with the stamp;
    # reloading via Missions.get would clobber `mission.ops` for tests
    # that hand-build them on the record.
    verdict_single(Map.put(mission, :winning_variant, winning_variant), winner_artifact)
  end

  defp verdict_single(_mission, nil), do: :wait

  defp verdict_single(mission, %{"overall_verdict" => "pass"} = artifact) do
    # Idempotent fast-path: this branch fires on every poll while
    # current_phase = "validation" and the artifact says pass; if we've
    # already done the side effects (artifact already carries
    # `requires_approval`), short-circuit so we don't re-emit telemetry,
    # re-run the cross-check, or re-write the artifact every tick.
    if Map.has_key?(artifact, "requires_approval") do
      :pass
    else
      validate_pass(mission, artifact)
    end
  end

  defp verdict_single(mission, artifact) when is_map(artifact) do
    # Cheap staleness check first — if the latest impl op finished after
    # the validation we're looking at, the artifact is moot regardless of
    # the fix budget. Skip the (heavier) fix-context load in that case.
    latest_impl = Validation.latest_completed_impl_op(mission)

    if Validation.artifact_stale?(latest_impl, artifact, mission) do
      Logger.info(
        "Quest #{mission.id}: validation artifact is stale (fix completed after), re-validating"
      )

      Orchestrator.dispatch_phase("validation", mission)
      :wait
    else
      handle_validation_fail(mission, artifact)
    end
  end

  defp verdict_single(_mission, _artifact), do: :wait

  defp validate_pass(mission, artifact) do
    Validation.emit_confidence(mission)

    # Two gates, both fail-safe overrides of a "pass" verdict: (1) the diff
    # cross-check (real commits exist), then (2) behavioral verification
    # (holdout scenarios driven through the artifact's real interface). Either
    # failing routes back into the fix loop rather than merging.
    with :ok <- Validation.validate_pass_against_diff(mission),
         :ok <- Validation.verify_behavior(mission) do
      Validation.maybe_spawn_skill_refinement(mission, artifact)

      requires_approval = GiTF.Override.requires_approval?(mission)

      Missions.store_artifact(
        mission.id,
        "validation",
        Map.put(artifact, "requires_approval", requires_approval)
      )

      :pass
    else
      {:error, reason} ->
        Logger.warning(
          "Quest #{mission.id}: validator said PASS but a gate overrode it (#{reason}); " <>
            "treating as fail and re-routing to fix loop"
        )

        GiTF.Telemetry.emit([:gitf, :validation, :pass_overridden], %{}, %{
          mission_id: mission.id,
          reason: reason
        })

        overridden =
          artifact
          |> Map.put("overall_verdict", "fail")
          |> Map.put("gaps", ["Validator returned pass but a gate overrode it: #{reason}"])
          |> Map.put("cross_check_override", reason)

        Missions.store_artifact(mission.id, "validation", overridden)
        # Stay on the single-variant path; otherwise we'd re-enter
        # verdict_tournament which would re-pick the same winner and
        # loop indefinitely.
        verdict_single(mission, overridden)
    end
  end

  # Hard ceiling on TOTAL fix ops per mission (any lane, any status), as a
  # multiple of the validation fix budget. The per-context attempt counter
  # can be gamed by lane dynamics: on run 17 deferred validation attempts
  # never recorded (counter frozen at 3/4) while the quality gate minted
  # fresh attempt-1 fixes against each new fix op as origin — the mission
  # churned "attempt 4/4" every 3 minutes indefinitely. Total-op count is
  # ungameable.
  @max_total_fix_ops_factor 3

  defp handle_validation_fail(mission, artifact) do
    fix_ctx = Validation.load_fix_context(mission)

    total_fix_ops =
      Enum.count(mission.ops, fn op ->
        op[:phase_job] not in [true] and is_binary(op[:fix_of])
      end)

    hard_cap = fix_ctx.max_attempts * @max_total_fix_ops_factor

    cond do
      infrastructure_failure?(artifact) ->
        # The tree was never judged: the toolchain was missing, the disk was
        # full, a probe lock starved. Spending a fix attempt sends a ghost
        # to "fix" code that was never found wanting, and it returns empty —
        # which is how runs 27-29 ground to their ceilings with healthy
        # trees. Wait for the next validation pass instead; the attempt
        # counter stays intact for real findings.
        Logger.warning(
          "Quest #{mission.id} validation hit an INFRASTRUCTURE failure — " <>
            "re-validating without burning a fix attempt (#{fix_ctx.attempt}/#{fix_ctx.max_attempts} intact)"
        )

        :wait

      FixContext.exhausted?(fix_ctx) ->
        Logger.warning(
          "Quest #{mission.id} validation failed after #{fix_ctx.attempt} fix attempts — ghost lost in the net"
        )

        :terminal_fail

      total_fix_ops >= hard_cap ->
        Logger.warning(
          "Quest #{mission.id} validation failed with #{total_fix_ops} total fix ops " <>
            "(hard cap #{hard_cap}) — sealing regardless of attempt counter"
        )

        :terminal_fail

      true ->
        Logger.info(
          "Quest #{mission.id} validation failed (attempt #{fix_ctx.attempt + 1}/#{fix_ctx.max_attempts})"
        )

        Validation.maybe_spawn_skill_refinement(mission, artifact)
        Validation.attempt_fixes(mission, artifact, fix_ctx)
        :wait
    end
  end

  # The exec-validation layer already classifies host problems (missing
  # toolchain, exhausted disk, an unavailable probe lock) as TOOL MISSING /
  # exit 127 rather than blaming the diff. Anything carrying that marker
  # means the ghost's code was never actually evaluated.
  @doc false
  @spec infrastructure_failure?(map() | nil) :: boolean()
  def infrastructure_failure?(artifact) when is_map(artifact) do
    text =
      [
        artifact["exec_validation_output"],
        artifact["summary"],
        get_in(artifact, ["failures", "output"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, "tool missing on host") or
      String.contains?(text, "infrastructure problem, not a code problem")
  end

  def infrastructure_failure?(_), do: false

  @impl true
  def terminal(mission, :retries_exhausted, artifact) do
    if is_map(artifact),
      do: Validation.maybe_spawn_skill_refinement(mission, artifact)

    fix_ctx = Validation.load_fix_context(mission)

    Missions.fail_quest(
      mission.id,
      "Ghost lost in the net — validation failed after #{fix_ctx.attempt} attempts"
    )

    :ok
  end

  def terminal(_mission, _kind, _artifact), do: :ok

  @doc false
  @spec verdict_field(map()) :: String.t()
  def verdict_field(artifact) when is_map(artifact) do
    artifact["overall_verdict"] || artifact[:overall_verdict] ||
      artifact["verdict"] || artifact[:verdict] ||
      get_in(artifact, ["overall", "verdict"]) || ""
  end
end
