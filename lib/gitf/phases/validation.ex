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
  @impl true
  def verdict(_mission, nil), do: :wait

  def verdict(mission, %{"overall_verdict" => "pass"} = artifact) do
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

  def verdict(mission, artifact) when is_map(artifact) do
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

  def verdict(_mission, _artifact), do: :wait

  defp validate_pass(mission, artifact) do
    Validation.emit_confidence(mission)

    case Validation.validate_pass_against_diff(mission) do
      :ok ->
        Validation.maybe_spawn_skill_refinement(mission, artifact)

        requires_approval = GiTF.Override.requires_approval?(mission)

        Missions.store_artifact(
          mission.id,
          "validation",
          Map.put(artifact, "requires_approval", requires_approval)
        )

        :pass

      {:error, reason} ->
        Logger.warning(
          "Quest #{mission.id}: validator said PASS but cross-check failed (#{reason}); " <>
            "treating as fail and re-routing to fix loop"
        )

        GiTF.Telemetry.emit([:gitf, :validation, :pass_overridden], %{}, %{
          mission_id: mission.id,
          reason: reason
        })

        overridden =
          artifact
          |> Map.put("overall_verdict", "fail")
          |> Map.put("gaps", ["Validator returned pass but no impl commits found: #{reason}"])
          |> Map.put("cross_check_override", reason)

        Missions.store_artifact(mission.id, "validation", overridden)
        verdict(mission, overridden)
    end
  end

  defp handle_validation_fail(mission, artifact) do
    fix_ctx = Validation.load_fix_context(mission)

    if FixContext.exhausted?(fix_ctx) do
      Logger.warning(
        "Quest #{mission.id} validation failed after #{fix_ctx.attempt} fix attempts — ghost lost in the net"
      )

      :terminal_fail
    else
      Logger.info(
        "Quest #{mission.id} validation failed (attempt #{fix_ctx.attempt + 1}/#{fix_ctx.max_attempts})"
      )

      Validation.maybe_spawn_skill_refinement(mission, artifact)
      Validation.attempt_fixes(mission, artifact, fix_ctx)
      :wait
    end
  end

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
